-- depends_on: {{ ref('t_d_scenario') }}, {{ ref('t_d_app_user') }}, {{ ref('t_f_scenario_period') }}, {{ ref('sp_calc_period') }}
/* =====================================================================================
   SP_CALCULATE_PAYROLL
   Recalculates one or all editable periods of a scenario.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-09-29  Fix: COMMENT moved before EXECUTE AS (Snowflake clause order).
   2026-10-02  V1.5.0: role check reads T_D_APP_USER.ROLE_CODE (one role per user).
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CONVENTIONS
   -----------
   * Every public procedure takes P_USER_EMAIL (the Power Apps user, passed by Power
     Automate), checks the user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Every public procedure returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
     Power Automate returns it to the app as is.
   * Validations run before any write. Writes run in one transaction; any error rolls
     the whole call back.
   * Currency rule: earnings are calculated in USD and converted to KHR at the NBC rate
     (from the unrounded USD). NSSF and salary tax are calculated in KHR and converted
     back to USD, rounded to the cent. Net pay USD = gross USD - deductions USD.

   ===================================================================================== */
/* =====================================================================================
   SP_CALCULATE_PAYROLL (public)
   Recalculates one period (P_PERIOD_KEY) or every editable period of a scenario
   (P_PERIOD_KEY = NULL), oldest first so seniority sees the earlier months.
   Finalized and locked periods are skipped.
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE {{ app() }}.SP_CALCULATE_PAYROLL(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Recalculates one or all editable periods of a scenario'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_type    TEXT;
    v_allowed INT;
    v_pk      INT;
    v_done    INT DEFAULT 0;
BEGIN
    SELECT MAX(SCENARIO_TYPE) INTO :v_type FROM {{ app() }}.T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' does not exist.');
    END IF;

    SELECT COUNT(*) INTO :v_allowed
    FROM {{ app() }}.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    BEGIN TRANSACTION;

    LET rs RESULTSET := (
        SELECT PERIOD_KEY
        FROM {{ app() }}.T_F_SCENARIO_PERIOD
        WHERE SCENARIO_ID = :P_SCENARIO_ID
          AND (:P_PERIOD_KEY IS NULL OR PERIOD_KEY = :P_PERIOD_KEY)
          AND PERIOD_STATUS NOT IN ('FINALIZED', 'LOCKED')
        ORDER BY PERIOD_KEY);
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        v_pk := rec.PERIOD_KEY;
        CALL {{ app() }}.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :v_pk);
        v_done := v_done + 1;
    END FOR;

    COMMIT;

    IF (v_done = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Nothing calculated: the period does not exist or is finalized / locked.');
    END IF;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_done || ' period(s) calculated.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
