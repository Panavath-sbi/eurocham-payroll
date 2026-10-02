/* =====================================================================================
   R - SP_RESET_APPROVALS
   Internal: restarts started approvals after payroll numbers change.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  Approved steps go back to PENDING in APP.T_F_APPROVAL_STEP_STATE; each reset
               is written to T_F_CHANGE_LOG. Employee checks have no step column any more.
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   SP_SAVE_MONTHLY_INPUT-style save procedures (contract, allocations, adjustments, FX, working days).

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* No role check and no transaction: only called inside another procedure's transaction.
   P_EMPLOYEE_IDS: JSON array of employee ids whose checks go back to PENDING; NULL = all. */
USE DATABASE PAYROLL_DB;
   
CREATE OR REPLACE PROCEDURE APP.SP_RESET_APPROVALS(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT, P_EMPLOYEE_IDS TEXT, P_REASON TEXT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Internal: resets step approvals and employee checks of the open approval request'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_req   INT;
    v_reset INT DEFAULT 0;
BEGIN
    SELECT MAX(REQUEST_ID) INTO :v_req
    FROM APP.T_F_APPROVAL_REQUEST
    WHERE SCENARIO_ID = :P_SCENARIO_ID AND EQUAL_NULL(PERIOD_KEY, :P_PERIOD_KEY) AND REQUEST_STATUS = 'IN_PROGRESS';

    IF (v_req IS NOT NULL) THEN
        -- Log first (the rows still show APPROVED), then set every approved step back to PENDING
        INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
        SELECT 'APP.T_F_APPROVAL_STEP_STATE', OBJECT_CONSTRUCT('REQUEST_ID', REQUEST_ID, 'STEP_ORDER', STEP_ORDER), 'UPDATE',
               OBJECT_CONSTRUCT('STEP_STATUS', 'APPROVED'),
               OBJECT_CONSTRUCT('ACTION_TYPE', 'RESET', 'STEP_STATUS', 'PENDING', 'COMMENT', :P_REASON),
               :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
        FROM APP.T_F_APPROVAL_STEP_STATE
        WHERE REQUEST_ID = :v_req AND STEP_STATUS = 'APPROVED';

        UPDATE APP.T_F_APPROVAL_STEP_STATE
        SET STEP_STATUS = 'PENDING', LAST_ACTION = 'RESET', ACTED_BY = 'SYSTEM', ACTED_AT = CURRENT_TIMESTAMP,
            STEP_COMMENT = :P_REASON || ' (' || :P_USER_EMAIL || ')',
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE REQUEST_ID = :v_req AND STEP_STATUS = 'APPROVED';
        v_reset := SQLROWCOUNT;

        UPDATE APP.T_F_APPROVAL_EMPLOYEE_CHECK
        SET CHECK_STATUS = 'PENDING', CHECKED_BY = NULL, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE REQUEST_ID = :v_req
          AND CHECK_STATUS <> 'PENDING'
          AND (:P_EMPLOYEE_IDS IS NULL
               OR EMPLOYEE_ID IN (SELECT f.VALUE::INT FROM TABLE(FLATTEN(INPUT => PARSE_JSON(COALESCE(:P_EMPLOYEE_IDS, '[]')))) f));
    END IF;

    IF (P_PERIOD_KEY IS NOT NULL) THEN
        UPDATE APP.T_F_SCENARIO_PERIOD
        SET PERIOD_STATUS = 'OPEN', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND PERIOD_STATUS = 'IN_APPROVAL';
    END IF;

    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_reset || ' approval step(s) reset.');
END;
$$;
