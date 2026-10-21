-- depends_on: {{ ref('t_d_app_user') }}, {{ ref('t_d_period') }}, {{ ref('t_f_scenario_period') }}, {{ ref('t_d_scenario') }}, {{ ref('t_f_change_log') }}, {{ ref('sp_reset_approvals') }}, {{ ref('sp_calc_period') }}
/* =====================================================================================
   SP_SAVE_WORKING_DAYS
   Saves working days of the actual or budget calendar.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  V1.5.0: CORE tables moved to APP; role check reads T_D_APP_USER.ROLE_CODE (one role per user).
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Settings page: Working Days per month "Save" (Actual and Budget grids).

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   P_CALENDAR: 'ACTUAL' (T_D_PERIOD.WORKING_DAYS) or 'BUDGET' (T_D_PERIOD.BUDGET_WORKING_DAYS).
   P_DAYS: JSON array, e.g. '[{"period_key": 202611, "working_days": 21}]'. 0 = not set.
   ACTUAL: finalized months are refused. The open month and draft forecast months take
   the new value (approvals reset, recalculated).
   BUDGET: draft budget scenarios take the new value and are recalculated.
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE {{ app() }}.SP_SAVE_WORKING_DAYS(P_USER_EMAIL TEXT, P_CALENDAR TEXT, P_DAYS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Saves working days of the actual or budget calendar'
EXECUTE AS OWNER
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
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM {{ app() }}.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    IF (P_CALENDAR IS NULL OR (P_CALENDAR <> 'ACTUAL' AND P_CALENDAR <> 'BUDGET')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'P_CALENDAR must be ACTUAL or BUDGET.');
    END IF;

    CREATE OR REPLACE TEMPORARY TABLE {{ app() }}.TMP_WORKING_DAYS AS
    SELECT f.VALUE:period_key::INT AS PERIOD_KEY, f.VALUE:working_days::INT AS WORKING_DAYS,
           p.PERIOD_KEY IS NOT NULL AS IN_CALENDAR, DAY(p.PERIOD_END_DATE) AS DAYS_IN_MONTH,
           IFF(:P_CALENDAR = 'ACTUAL', p.WORKING_DAYS, p.BUDGET_WORKING_DAYS) AS OLD_WORKING_DAYS
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_DAYS))) f
    LEFT JOIN {{ app() }}.T_D_PERIOD p ON p.PERIOD_KEY = f.VALUE:period_key::INT;

    SELECT COUNT(*), COUNT_IF(NOT IN_CALENDAR OR WORKING_DAYS IS NULL OR WORKING_DAYS < 0 OR WORKING_DAYS > DAYS_IN_MONTH),
           COUNT(*) - COUNT(DISTINCT PERIOD_KEY),
           COUNT_IF(NOT EQUAL_NULL(WORKING_DAYS, OLD_WORKING_DAYS))
      INTO :v_rows, :v_bad, :v_dupes, :v_changed
    FROM {{ app() }}.TMP_WORKING_DAYS;
    IF (v_rows = 0 OR v_bad > 0 OR v_dupes > 0) THEN
        DROP TABLE IF EXISTS {{ app() }}.TMP_WORKING_DAYS;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each row needs a month in the calendar and 0 to (days in month) working days, with no duplicates.');
    END IF;
    IF (v_changed = 0) THEN
        DROP TABLE IF EXISTS {{ app() }}.TMP_WORKING_DAYS;
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'No changes to save.');
    END IF;

    IF (P_CALENDAR = 'ACTUAL') THEN
        SELECT COUNT(*) INTO :v_finalized
        FROM {{ app() }}.TMP_WORKING_DAYS t
        JOIN {{ app() }}.T_F_SCENARIO_PERIOD x ON x.PERIOD_KEY = t.PERIOD_KEY AND x.PERIOD_STATUS = 'FINALIZED'
        JOIN {{ app() }}.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID AND s.SCENARIO_TYPE = 'ACTUAL'
        WHERE NOT EQUAL_NULL(t.WORKING_DAYS, t.OLD_WORKING_DAYS);
        IF (v_finalized > 0) THEN
            DROP TABLE IF EXISTS {{ app() }}.TMP_WORKING_DAYS;
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_finalized || ' of the changed months are finalized and cannot change.');
        END IF;
    END IF;

    -- Scenario periods that take the new value (open actual month, draft forecasts / budgets)
    CREATE OR REPLACE TEMPORARY TABLE {{ app() }}.TMP_WD_RECALC AS
    SELECT x.SCENARIO_ID, x.PERIOD_KEY, s.SCENARIO_TYPE, t.WORKING_DAYS
    FROM {{ app() }}.TMP_WORKING_DAYS t
    JOIN {{ app() }}.T_F_SCENARIO_PERIOD x ON x.PERIOD_KEY = t.PERIOD_KEY
    JOIN {{ app() }}.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID
    WHERE NOT EQUAL_NULL(t.WORKING_DAYS, t.OLD_WORKING_DAYS) AND t.WORKING_DAYS > 0
      AND (   (:P_CALENDAR = 'ACTUAL' AND s.SCENARIO_TYPE = 'ACTUAL' AND x.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'))
           OR (:P_CALENDAR = 'ACTUAL' AND s.SCENARIO_TYPE = 'FORECAST' AND s.SCENARIO_STATUS = 'DRAFT' AND x.PERIOD_STATUS = 'DRAFT')
           OR (:P_CALENDAR = 'BUDGET' AND s.SCENARIO_TYPE = 'BUDGET' AND s.SCENARIO_STATUS IN ('DRAFT', 'REJECTED') AND x.PERIOD_STATUS = 'DRAFT'));

    BEGIN TRANSACTION;

    INSERT INTO {{ app() }}.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_PERIOD', OBJECT_CONSTRUCT('PERIOD_KEY', PERIOD_KEY, 'CALENDAR', :P_CALENDAR), 'UPDATE',
           OBJECT_CONSTRUCT_KEEP_NULL('WORKING_DAYS', OLD_WORKING_DAYS), OBJECT_CONSTRUCT('WORKING_DAYS', WORKING_DAYS),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM {{ app() }}.TMP_WORKING_DAYS WHERE NOT EQUAL_NULL(WORKING_DAYS, OLD_WORKING_DAYS);

    UPDATE {{ app() }}.T_D_PERIOD p
    SET WORKING_DAYS        = IFF(:P_CALENDAR = 'ACTUAL', t.WORKING_DAYS, p.WORKING_DAYS),
        BUDGET_WORKING_DAYS = IFF(:P_CALENDAR = 'BUDGET', t.WORKING_DAYS, p.BUDGET_WORKING_DAYS),
        UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM {{ app() }}.TMP_WORKING_DAYS t
    WHERE p.PERIOD_KEY = t.PERIOD_KEY AND NOT EQUAL_NULL(t.WORKING_DAYS, t.OLD_WORKING_DAYS);

    UPDATE {{ app() }}.T_F_SCENARIO_PERIOD x
    SET WORKING_DAYS = r.WORKING_DAYS, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM {{ app() }}.TMP_WD_RECALC r
    WHERE x.SCENARIO_ID = r.SCENARIO_ID AND x.PERIOD_KEY = r.PERIOD_KEY;

    LET rs RESULTSET := (SELECT SCENARIO_ID, PERIOD_KEY, SCENARIO_TYPE FROM {{ app() }}.TMP_WD_RECALC ORDER BY SCENARIO_ID, PERIOD_KEY);
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        v_sid  := rec.SCENARIO_ID;
        v_pk   := rec.PERIOD_KEY;
        v_type := rec.SCENARIO_TYPE;
        IF (v_type = 'ACTUAL') THEN
            CALL {{ app() }}.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_sid, :v_pk, NULL, 'Working days changed');
        END IF;
        CALL {{ app() }}.SP_CALC_PERIOD(:P_USER_EMAIL, :v_sid, :v_pk);
    END FOR;

    COMMIT;
    DROP TABLE IF EXISTS {{ app() }}.TMP_WORKING_DAYS;
    DROP TABLE IF EXISTS {{ app() }}.TMP_WD_RECALC;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_changed || ' month(s) saved in the ' || LOWER(P_CALENDAR) || ' calendar.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        DROP TABLE IF EXISTS {{ app() }}.TMP_WORKING_DAYS;
        DROP TABLE IF EXISTS {{ app() }}.TMP_WD_RECALC;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
