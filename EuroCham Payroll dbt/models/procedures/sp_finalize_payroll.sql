-- depends_on: {{ ref('t_d_app_user') }}, {{ ref('t_d_scenario') }}, {{ ref('t_f_scenario_period') }}, {{ ref('v_f_approval_progress') }}, {{ ref('t_f_payroll_line') }}, {{ ref('t_f_change_log') }}
/* =====================================================================================
   SP_FINALIZE_PAYROLL
   Locks a fully approved actual payroll month.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-09-29  Fix: COMMENT moved before EXECUTE AS (Snowflake clause order).
   2026-10-02  V1.5.0: approvals read by scenario + period (no request to close); CORE -> APP;
               one role per user.
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
   SP_FINALIZE_PAYROLL (public) - "Process" on the Approval page
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   Requires every approval step of the month to be APPROVED. Locks the month
   exactly as approved: no recalculation happens here, because any change after an
   approval already resets that approval.
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE SP_FINALIZE_PAYROLL(P_USER_EMAIL TEXT, P_PERIOD_KEY INT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Finalizes (locks) a fully approved actual payroll month'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_allowed INT;
    v_scen    INT;
    v_status  TEXT;
    v_steps   INT;
    v_pending INT;
    v_lines   INT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT MAX(SCENARIO_ID) INTO :v_scen FROM T_D_SCENARIO WHERE SCENARIO_TYPE = 'ACTUAL';

    SELECT MAX(PERIOD_STATUS) INTO :v_status
    FROM T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_status IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' does not exist.');
    END IF;
    IF (v_status = 'FINALIZED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' is already finalized.');
    END IF;

    SELECT COUNT(*), COUNT_IF(STEP_STATUS <> 'APPROVED') INTO :v_steps, :v_pending
    FROM V_F_APPROVAL_PROGRESS WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_steps = 0 OR v_pending > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_pending || ' approval step(s) are not approved yet.');
    END IF;

    SELECT COUNT(*) INTO :v_lines
    FROM T_F_PAYROLL_LINE WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_lines = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' has no calculated payroll.');
    END IF;

    BEGIN TRANSACTION;

    UPDATE T_F_SCENARIO_PERIOD
    SET PERIOD_STATUS = 'FINALIZED', FINALIZED_AT = CURRENT_TIMESTAMP, FINALIZED_BY = :P_USER_EMAIL,
        UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :P_PERIOD_KEY;


    INSERT INTO T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_SCENARIO_PERIOD',
           OBJECT_CONSTRUCT('SCENARIO_ID', :v_scen, 'PERIOD_KEY', :P_PERIOD_KEY),
           'UPDATE',
           OBJECT_CONSTRUCT('PERIOD_STATUS', :v_status),
           OBJECT_CONSTRUCT('PERIOD_STATUS', 'FINALIZED'),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Payroll ' || P_PERIOD_KEY || ' finalized.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
