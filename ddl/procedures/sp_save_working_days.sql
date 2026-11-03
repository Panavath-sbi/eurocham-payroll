CREATE OR REPLACE PROCEDURE APP.SP_SAVE_WORKING_DAYS(P_USER_EMAIL TEXT, P_CALENDAR TEXT, P_DAYS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Saves working days of the actual or budget calendar'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed   INT;
    v_rows      INT;
    v_bad       INT;
    v_dupes     INT;
    v_finalized INT;
    v_changed   INT;
    v_sid       INT;
    v_pk        INT;
    v_type      TEXT;
    v_new       TEXT;   -- JSON array: changed months (PERIOD_KEY, WORKING_DAYS, OLD_WORKING_DAYS)
    v_recalc    TEXT;   -- JSON array: scenario months that take the new value
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    IF (P_CALENDAR IS NULL OR (P_CALENDAR <> 'ACTUAL' AND P_CALENDAR <> 'BUDGET')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'P_CALENDAR must be ACTUAL or BUDGET.');
    END IF;

    -- Checks on every row, and the changed months kept for the writes
    SELECT COUNT(*), COUNT_IF(NOT IN_CALENDAR OR WORKING_DAYS IS NULL OR WORKING_DAYS < 0 OR WORKING_DAYS > DAYS_IN_MONTH),
           COUNT(*) - COUNT(DISTINCT PERIOD_KEY),
           COUNT_IF(NOT EQUAL_NULL(WORKING_DAYS, OLD_WORKING_DAYS)),
           TO_JSON(ARRAY_AGG(IFF(NOT EQUAL_NULL(WORKING_DAYS, OLD_WORKING_DAYS),
               OBJECT_CONSTRUCT_KEEP_NULL('PERIOD_KEY', PERIOD_KEY, 'WORKING_DAYS', WORKING_DAYS,
                                          'OLD_WORKING_DAYS', OLD_WORKING_DAYS), NULL)))
      INTO :v_rows, :v_bad, :v_dupes, :v_changed, :v_new
    FROM (SELECT f.VALUE:period_key::INT AS PERIOD_KEY, f.VALUE:working_days::INT AS WORKING_DAYS,
                 p.PERIOD_KEY IS NOT NULL AS IN_CALENDAR, DAY(p.PERIOD_END_DATE) AS DAYS_IN_MONTH,
                 IFF(:P_CALENDAR = 'ACTUAL', p.WORKING_DAYS, p.BUDGET_WORKING_DAYS) AS OLD_WORKING_DAYS
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_DAYS))) f
          LEFT JOIN APP.T_D_PERIOD p ON p.PERIOD_KEY = f.VALUE:period_key::INT);
    IF (v_rows = 0 OR v_bad > 0 OR v_dupes > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each row needs a month in the calendar and 0 to (days in month) working days, with no duplicates.');
    END IF;
    IF (v_changed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'No changes to save.');
    END IF;

    IF (P_CALENDAR = 'ACTUAL') THEN
        SELECT COUNT(*) INTO :v_finalized
        FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new))) t
        JOIN APP.T_F_SCENARIO_PERIOD x ON x.PERIOD_KEY = t.VALUE:PERIOD_KEY::INT AND x.PERIOD_STATUS = 'FINALIZED'
        JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID AND s.SCENARIO_TYPE = 'ACTUAL';
        IF (v_finalized > 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_finalized || ' of the changed months are finalized and cannot change.');
        END IF;
    END IF;

    -- Scenario periods that take the new value (open actual month, draft forecasts / budgets)
    SELECT TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT('SCENARIO_ID', x.SCENARIO_ID, 'PERIOD_KEY', x.PERIOD_KEY,
                                              'SCENARIO_TYPE', s.SCENARIO_TYPE, 'WORKING_DAYS', t.VALUE:WORKING_DAYS::INT)))
      INTO :v_recalc
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new))) t
    JOIN APP.T_F_SCENARIO_PERIOD x ON x.PERIOD_KEY = t.VALUE:PERIOD_KEY::INT
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID
    WHERE t.VALUE:WORKING_DAYS::INT > 0
      AND (   (:P_CALENDAR = 'ACTUAL' AND s.SCENARIO_TYPE = 'ACTUAL' AND x.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'))
           OR (:P_CALENDAR = 'ACTUAL' AND s.SCENARIO_TYPE = 'FORECAST' AND s.SCENARIO_STATUS = 'DRAFT' AND x.PERIOD_STATUS = 'DRAFT')
           OR (:P_CALENDAR = 'BUDGET' AND s.SCENARIO_TYPE = 'BUDGET' AND s.SCENARIO_STATUS IN ('DRAFT', 'REJECTED') AND x.PERIOD_STATUS = 'DRAFT'));

    BEGIN TRANSACTION;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_PERIOD', OBJECT_CONSTRUCT('PERIOD_KEY', t.VALUE:PERIOD_KEY::INT, 'CALENDAR', :P_CALENDAR), 'UPDATE',
           OBJECT_CONSTRUCT_KEEP_NULL('WORKING_DAYS', t.VALUE:OLD_WORKING_DAYS::INT),
           OBJECT_CONSTRUCT('WORKING_DAYS', t.VALUE:WORKING_DAYS::INT),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new))) t;

    UPDATE APP.T_D_PERIOD p
    SET WORKING_DAYS        = IFF(:P_CALENDAR = 'ACTUAL', t.WD, p.WORKING_DAYS),
        BUDGET_WORKING_DAYS = IFF(:P_CALENDAR = 'BUDGET', t.WD, p.BUDGET_WORKING_DAYS),
        UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM (SELECT VALUE:PERIOD_KEY::INT AS PK, VALUE:WORKING_DAYS::INT AS WD
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))) t
    WHERE p.PERIOD_KEY = t.PK;

    UPDATE APP.T_F_SCENARIO_PERIOD x
    SET WORKING_DAYS = r.WD, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM (SELECT VALUE:SCENARIO_ID::INT AS SID, VALUE:PERIOD_KEY::INT AS PK, VALUE:WORKING_DAYS::INT AS WD
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_recalc)))) r
    WHERE x.SCENARIO_ID = r.SID AND x.PERIOD_KEY = r.PK;

    LET rs RESULTSET := (SELECT VALUE:SCENARIO_ID::INT AS SCENARIO_ID, VALUE:PERIOD_KEY::INT AS PERIOD_KEY,
                                VALUE:SCENARIO_TYPE::TEXT AS SCENARIO_TYPE
                         FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_recalc)))
                         ORDER BY SCENARIO_ID, PERIOD_KEY);
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        v_sid  := rec.SCENARIO_ID;
        v_pk   := rec.PERIOD_KEY;
        v_type := rec.SCENARIO_TYPE;
        IF (v_type = 'ACTUAL') THEN
            CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_sid, :v_pk, NULL, 'Working days changed');
        END IF;
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :v_sid, :v_pk);
    END FOR;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_changed || ' month(s) saved in the ' || LOWER(P_CALENDAR) || ' calendar.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
