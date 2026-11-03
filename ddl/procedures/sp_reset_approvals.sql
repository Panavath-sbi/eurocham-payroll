-- depends_on: T_F_SCENARIO_PERIOD, T_D_SCENARIO, T_F_CHANGE_LOG, T_F_APPROVAL, T_F_PAYROLL_INPUT
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   SP_RESET_APPROVALS
   Internal: restarts started approvals after payroll numbers change.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  Approved steps go back to PENDING in APP.T_F_APPROVAL_STEP_STATE; each reset
               is written to T_F_CHANGE_LOG. Employee checks have no step column any more.
   2026-10-02  V1.5.0: approvals in APP.T_F_APPROVAL (by scenario + period); employee checks
               on T_F_PAYROLL_INPUT (status back to PENDING, comment cleared). Only acts on
               a payroll month that is OPEN or IN_APPROVAL.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   SP_SAVE_MONTHLY_INPUT-style save procedures (contract, allocations, employees, FX, working days).

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   No role check and no transaction: only called inside another procedure's transaction.
   Acts only on an actual payroll month that is OPEN or IN_APPROVAL (budgets in approval
   cannot be edited, so they never need a reset).
   P_EMPLOYEE_IDS: JSON array of employee ids whose checks go back to PENDING; NULL = all.
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE APP.SP_RESET_APPROVALS(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT, P_EMPLOYEE_IDS TEXT, P_REASON TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Internal: resets step approvals and employee checks of an open payroll month'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_open  INT;
    v_reset INT DEFAULT 0;
BEGIN
    SELECT COUNT(*) INTO :v_open
    FROM APP.T_F_SCENARIO_PERIOD sp
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = sp.SCENARIO_ID AND s.SCENARIO_TYPE = 'ACTUAL'
    WHERE sp.SCENARIO_ID = :P_SCENARIO_ID AND sp.PERIOD_KEY = :P_PERIOD_KEY
      AND sp.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL');

    IF (v_open > 0) THEN
        -- Log first (the rows still show APPROVED), then set every approved step back to PENDING
        INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
        SELECT 'APP.T_F_APPROVAL',
               OBJECT_CONSTRUCT('SCENARIO_ID', SCENARIO_ID, 'PERIOD_KEY', PERIOD_KEY, 'STEP_ORDER', STEP_ORDER), 'UPDATE',
               OBJECT_CONSTRUCT('STEP_STATUS', 'APPROVED'),
               OBJECT_CONSTRUCT('ACTION_TYPE', 'RESET', 'STEP_STATUS', 'PENDING', 'COMMENT', :P_REASON),
               :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
        FROM APP.T_F_APPROVAL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND STEP_STATUS = 'APPROVED';

        UPDATE APP.T_F_APPROVAL
        SET STEP_STATUS = 'PENDING', LAST_ACTION = 'RESET', ACTED_BY = 'SYSTEM', ACTED_AT = CURRENT_TIMESTAMP,
            STEP_COMMENT = :P_REASON || ' (' || :P_USER_EMAIL || ')',
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND STEP_STATUS = 'APPROVED';
        v_reset := SQLROWCOUNT;

        -- The affected employees must be checked again; an old rejection reason no longer applies
        UPDATE APP.T_F_PAYROLL_INPUT
        SET CHECK_STATUS = 'PENDING', CHECK_COMMENT = NULL, CHECKED_BY = NULL,
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY
          AND COALESCE(CHECK_STATUS, 'PENDING') <> 'PENDING'
          AND (:P_EMPLOYEE_IDS IS NULL
               OR EMPLOYEE_ID IN (SELECT f.VALUE::INT FROM TABLE(FLATTEN(INPUT => PARSE_JSON(COALESCE(:P_EMPLOYEE_IDS, '[]')))) f));

        UPDATE APP.T_F_SCENARIO_PERIOD
        SET PERIOD_STATUS = 'OPEN', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND PERIOD_STATUS = 'IN_APPROVAL';
    END IF;

    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_reset || ' approval step(s) reset.');
END;
$$;
