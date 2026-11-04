CREATE OR REPLACE PROCEDURE APP.SP_SAVE_STATUTORY_PARAMETER(P_USER_EMAIL TEXT, P_PERIOD_KEY INT, P_PARAMS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Changes statutory parameters from the open payroll month onward'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed  INT;
    v_status   TEXT;
    v_prev_key INT;
    v_rows     INT;
    v_bad      INT;
    v_dupes    INT;
    v_changed  INT;
    v_recalc   INT;
    v_sid      INT;
    v_pk       INT;
    v_type     TEXT;
    v_params      TEXT;   -- JSON array: changed parameters with the row in force
    v_recalc_rows TEXT;   -- JSON array: scenario months to recalculate
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT MAX(x.PERIOD_STATUS) INTO :v_status
    FROM APP.T_F_SCENARIO_PERIOD x
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID AND s.SCENARIO_TYPE = 'ACTUAL'
    WHERE x.PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_status IS NULL OR (v_status <> 'OPEN' AND v_status <> 'IN_APPROVAL')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || COALESCE(P_PERIOD_KEY::TEXT, '?') || ' is not the open payroll month; parameters can only change from the open month.');
    END IF;

    v_prev_key := TO_NUMBER(TO_CHAR(DATEADD(MONTH, -1, TO_DATE(P_PERIOD_KEY::TEXT, 'YYYYMM')), 'YYYYMM'));

    -- Each sent value with the row in force in P_PERIOD_KEY, checked; the changed ones kept in v_params
    SELECT COUNT(*),
           COUNT_IF(NOT FOUND OR NEW_VALUE IS NULL OR NEW_VALUE < 0 OR (UNIT = 'RATE' AND NEW_VALUE > 1)),
           COUNT(*) - COUNT(DISTINCT PARAM_CODE),
           COUNT_IF(FOUND AND ABS(NEW_VALUE - OLD_VALUE) > 1e-9),
           TO_JSON(ARRAY_AGG(IFF(FOUND AND ABS(NEW_VALUE - OLD_VALUE) > 1e-9,
               OBJECT_CONSTRUCT_KEEP_NULL('PARAM_CODE', PARAM_CODE, 'NEW_VALUE', NEW_VALUE, 'OLD_FROM', OLD_FROM,
                   'OLD_TO', OLD_TO, 'OLD_VALUE', OLD_VALUE, 'UNIT', UNIT, 'DESCRIPTION', DESCRIPTION,
                   'LEGAL_REFERENCE', LEGAL_REFERENCE), NULL)))
      INTO :v_rows, :v_bad, :v_dupes, :v_changed, :v_params
    FROM (SELECT f.VALUE:param_code::TEXT    AS PARAM_CODE,
                 f.VALUE:param_value::FLOAT  AS NEW_VALUE,
                 sp.PARAM_CODE IS NOT NULL   AS FOUND,
                 sp.VALID_FROM_PERIOD_KEY    AS OLD_FROM,
                 sp.VALID_TO_PERIOD_KEY      AS OLD_TO,
                 sp.PARAM_VALUE              AS OLD_VALUE,
                 sp.UNIT, sp.DESCRIPTION, sp.LEGAL_REFERENCE
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_PARAMS))) f
          LEFT JOIN APP.T_P_STATUTORY_PARAMETER sp
                 ON sp.PARAM_CODE = f.VALUE:param_code::TEXT
                AND :P_PERIOD_KEY BETWEEN sp.VALID_FROM_PERIOD_KEY AND COALESCE(sp.VALID_TO_PERIOD_KEY, 999912));
    IF (v_rows = 0 OR v_bad > 0 OR v_dupes > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each parameter needs a known code and a value of 0 or more (rates at most 100%), with no duplicates.');
    END IF;
    IF (v_changed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'No changes to save.');
    END IF;

    -- Scenario periods from P_PERIOD_KEY on that take the new values
    SELECT COUNT(*),
           TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT('SCENARIO_ID', x.SCENARIO_ID, 'PERIOD_KEY', x.PERIOD_KEY,
                                              'SCENARIO_TYPE', s.SCENARIO_TYPE)))
      INTO :v_recalc, :v_recalc_rows
    FROM APP.T_F_SCENARIO_PERIOD x
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID
    WHERE x.PERIOD_KEY >= :P_PERIOD_KEY
      AND (   (s.SCENARIO_TYPE = 'ACTUAL' AND x.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'))
           OR (s.SCENARIO_TYPE = 'FORECAST' AND s.SCENARIO_STATUS = 'DRAFT' AND x.PERIOD_STATUS = 'DRAFT')
           OR (s.SCENARIO_TYPE = 'BUDGET' AND s.SCENARIO_STATUS IN ('DRAFT', 'REJECTED') AND x.PERIOD_STATUS = 'DRAFT'));

    BEGIN TRANSACTION;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_P_STATUTORY_PARAMETER',
           OBJECT_CONSTRUCT('PARAM_CODE', VALUE:PARAM_CODE::TEXT, 'VALID_FROM_PERIOD_KEY', :P_PERIOD_KEY),
           IFF(VALUE:OLD_FROM::INT = :P_PERIOD_KEY, 'UPDATE', 'INSERT'),
           OBJECT_CONSTRUCT('PARAM_VALUE', VALUE:OLD_VALUE::FLOAT, 'VALID_FROM_PERIOD_KEY', VALUE:OLD_FROM::INT),
           OBJECT_CONSTRUCT('PARAM_VALUE', VALUE:NEW_VALUE::FLOAT, 'VALID_FROM_PERIOD_KEY', :P_PERIOD_KEY),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_params)));

    -- Started this month: change the value in place
    UPDATE APP.T_P_STATUTORY_PARAMETER sp
    SET PARAM_VALUE = t.VALUE:NEW_VALUE::FLOAT, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM (SELECT VALUE FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_params)))) t
    WHERE sp.PARAM_CODE = t.VALUE:PARAM_CODE::TEXT AND sp.VALID_FROM_PERIOD_KEY = :P_PERIOD_KEY
      AND t.VALUE:OLD_FROM::INT = :P_PERIOD_KEY;

    -- Started earlier: end it last month, new row from this month
    UPDATE APP.T_P_STATUTORY_PARAMETER sp
    SET VALID_TO_PERIOD_KEY = :v_prev_key, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM (SELECT VALUE FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_params)))) t
    WHERE sp.PARAM_CODE = t.VALUE:PARAM_CODE::TEXT AND sp.VALID_FROM_PERIOD_KEY = t.VALUE:OLD_FROM::INT
      AND t.VALUE:OLD_FROM::INT < :P_PERIOD_KEY;

    INSERT INTO APP.T_P_STATUTORY_PARAMETER
        (PARAM_CODE, VALID_FROM_PERIOD_KEY, VALID_TO_PERIOD_KEY, PARAM_VALUE, UNIT, DESCRIPTION, LEGAL_REFERENCE, INSERT_BY, UPDATE_BY)
    SELECT VALUE:PARAM_CODE::TEXT, :P_PERIOD_KEY, VALUE:OLD_TO::INT, VALUE:NEW_VALUE::FLOAT, VALUE:UNIT::TEXT,
           VALUE:DESCRIPTION::TEXT, VALUE:LEGAL_REFERENCE::TEXT, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_params)))
    WHERE VALUE:OLD_FROM::INT < :P_PERIOD_KEY;

    LET rs RESULTSET := (SELECT VALUE:SCENARIO_ID::INT AS SCENARIO_ID, VALUE:PERIOD_KEY::INT AS PERIOD_KEY,
                                VALUE:SCENARIO_TYPE::TEXT AS SCENARIO_TYPE
                         FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_recalc_rows)))
                         ORDER BY SCENARIO_ID, PERIOD_KEY);
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        v_sid  := rec.SCENARIO_ID;
        v_pk   := rec.PERIOD_KEY;
        v_type := rec.SCENARIO_TYPE;
        IF (v_type = 'ACTUAL') THEN
            CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_sid, :v_pk, NULL, 'Statutory parameters changed');
        END IF;
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :v_sid, :v_pk);
    END FOR;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_changed || ' parameter(s) saved from ' || P_PERIOD_KEY || '; ' || v_recalc || ' month(s) recalculated.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
