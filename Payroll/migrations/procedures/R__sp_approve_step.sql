/* =====================================================================================
   R - SP_APPROVE_STEP
   Approves one step of a payroll or budget approval request.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   Monthly Inputs (step 1), Approval page (steps 2-3), Budget Approval page.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* Rules: the request is IN_PROGRESS; the step is the next one in order; the user holds the
   step's APPROVER_ROLE. Actual payroll: every employee must be CHECKED for this step.
   Final step of a BUDGET request: the scenario becomes APPROVED and the official budget of
   its year (the previous official budget of that year loses the flag); its periods lock.
   Final step of an ACTUAL request: the month is ready for SP_FINALIZE_PAYROLL. */
USE DATABASE PAYROLL_DB;

CREATE OR REPLACE PROCEDURE APP.SP_APPROVE_STEP(P_USER_EMAIL TEXT, P_REQUEST_ID INT, P_STEP_ORDER INT, P_COMMENT TEXT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Approves one approval step'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_scen        INT;
    v_pk          INT;
    v_req_status  TEXT;
    v_type        TEXT;
    v_scen_status TEXT;
    v_role        TEXT;
    v_step_status TEXT;
    v_is_next     INT;
    v_allowed     INT;
    v_period_status TEXT;
    v_unchecked   INT DEFAULT 0;
    v_last_step   INT;
    v_year        INT;
BEGIN
    SELECT MAX(r.SCENARIO_ID), MAX(r.PERIOD_KEY), MAX(r.REQUEST_STATUS), MAX(s.SCENARIO_TYPE), MAX(s.SCENARIO_STATUS)
      INTO :v_scen, :v_pk, :v_req_status, :v_type, :v_scen_status
    FROM APP.T_F_APPROVAL_REQUEST r
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = r.SCENARIO_ID
    WHERE r.REQUEST_ID = :P_REQUEST_ID;
    IF (v_scen IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Approval request ' || P_REQUEST_ID || ' does not exist.');
    END IF;
    IF (v_req_status <> 'IN_PROGRESS') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This approval request is ' || v_req_status || '.');
    END IF;

    SELECT MAX(APPROVER_ROLE), MAX(STEP_STATUS), MAX(IFF(IS_NEXT_STEP, 1, 0))
      INTO :v_role, :v_step_status, :v_is_next
    FROM RPT.V_F_APPROVAL_PROGRESS
    WHERE REQUEST_ID = :P_REQUEST_ID AND STEP_ORDER = :P_STEP_ORDER;
    IF (v_role IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Step ' || P_STEP_ORDER || ' is not part of this approval chain.');
    END IF;

    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    JOIN APP.T_D_APP_USER_ROLE r ON r.USER_EMAIL = u.USER_EMAIL
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE AND r.ROLE_CODE = :v_role;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only a user with role ' || v_role || ' can act on step ' || P_STEP_ORDER || '.');
    END IF;

    IF (v_step_status = 'APPROVED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Step ' || P_STEP_ORDER || ' is already approved.');
    END IF;
    IF (v_is_next = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Step ' || P_STEP_ORDER || ' is not the next step to approve.');
    END IF;

    SELECT MAX(STEP_ORDER) INTO :v_last_step FROM RPT.V_F_APPROVAL_PROGRESS WHERE REQUEST_ID = :P_REQUEST_ID;

    IF (v_type = 'ACTUAL') THEN
        SELECT MAX(PERIOD_STATUS) INTO :v_period_status
        FROM APP.T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :v_pk;
        IF (v_period_status <> 'OPEN' AND v_period_status <> 'IN_APPROVAL') THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || v_pk || ' is ' || v_period_status || '.');
        END IF;

        SELECT COUNT(*) INTO :v_unchecked
        FROM APP.T_F_PAYROLL_INPUT i
        LEFT JOIN APP.T_F_APPROVAL_EMPLOYEE_CHECK c
               ON c.REQUEST_ID = :P_REQUEST_ID AND c.STEP_ORDER = :P_STEP_ORDER AND c.EMPLOYEE_ID = i.EMPLOYEE_ID
        WHERE i.SCENARIO_ID = :v_scen AND i.PERIOD_KEY = :v_pk AND i.INCLUDE_IN_PAYROLL
          AND COALESCE(c.CHECK_STATUS, 'PENDING') <> 'CHECKED';
        IF (v_unchecked > 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_unchecked || ' employee(s) are not checked yet for this step.');
        END IF;
    ELSE
        IF (v_scen_status <> 'IN_APPROVAL') THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This scenario is ' || v_scen_status || ', not IN_APPROVAL.');
        END IF;
    END IF;

    BEGIN TRANSACTION;

    INSERT INTO APP.T_F_APPROVAL_ACTION (REQUEST_ID, STEP_ORDER, ACTION_TYPE, ACTED_BY, ACTION_COMMENT, INSERT_BY, UPDATE_BY)
    SELECT :P_REQUEST_ID, :P_STEP_ORDER, 'APPROVE', :P_USER_EMAIL, :P_COMMENT, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_type = 'ACTUAL') THEN
        UPDATE APP.T_F_SCENARIO_PERIOD
        SET PERIOD_STATUS = 'IN_APPROVAL', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :v_pk AND PERIOD_STATUS = 'OPEN';
    END IF;

    IF (v_type = 'BUDGET' AND P_STEP_ORDER = v_last_step) THEN
        SELECT MAX(FISCAL_YEAR) INTO :v_year FROM APP.T_D_SCENARIO WHERE SCENARIO_ID = :v_scen;

        UPDATE APP.T_D_SCENARIO
        SET IS_OFFICIAL = FALSE, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_TYPE = 'BUDGET' AND FISCAL_YEAR = :v_year AND IS_OFFICIAL AND SCENARIO_ID <> :v_scen;

        UPDATE APP.T_D_SCENARIO
        SET SCENARIO_STATUS = 'APPROVED', IS_OFFICIAL = TRUE, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :v_scen;

        UPDATE APP.T_F_SCENARIO_PERIOD
        SET PERIOD_STATUS = 'LOCKED', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :v_scen;

        UPDATE APP.T_F_APPROVAL_REQUEST
        SET REQUEST_STATUS = 'APPROVED', COMPLETED_AT = CURRENT_TIMESTAMP, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE REQUEST_ID = :P_REQUEST_ID;
    END IF;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_APPROVAL_ACTION', OBJECT_CONSTRUCT('REQUEST_ID', :P_REQUEST_ID, 'STEP_ORDER', :P_STEP_ORDER), 'INSERT', NULL, OBJECT_CONSTRUCT('ACTION_TYPE', 'APPROVE', 'COMMENT', :P_COMMENT), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    IF (v_type = 'BUDGET' AND P_STEP_ORDER = v_last_step) THEN
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Budget approved. It is now the official budget for ' || v_year || '.');
    END IF;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Step ' || P_STEP_ORDER || ' approved.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
