/* =====================================================================================
   R - SP_UNDO_APPROVAL
   Undoes the most recent approval of a request.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   Monthly Inputs, Approval page, Budget Approval page ("Undo Approval").

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* Rules: the request is IN_PROGRESS (a finalized payroll or an approved budget cannot be
   undone); the step is APPROVED and no later step is approved; the user holds the step's
   APPROVER_ROLE. When no approved step remains, an actual month goes back to OPEN. */
USE DATABASE PAYROLL_DB;
   
CREATE OR REPLACE PROCEDURE APP.SP_UNDO_APPROVAL(P_USER_EMAIL TEXT, P_REQUEST_ID INT, P_STEP_ORDER INT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Undoes the latest approval of a request'
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
    v_later       INT;
    v_remaining   INT;
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

    IF (v_step_status <> 'APPROVED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Step ' || P_STEP_ORDER || ' is not approved.');
    END IF;

    SELECT COUNT(*) INTO :v_later
    FROM RPT.V_F_APPROVAL_PROGRESS
    WHERE REQUEST_ID = :P_REQUEST_ID AND STEP_ORDER > :P_STEP_ORDER AND STEP_STATUS = 'APPROVED';
    IF (v_later > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A later step is already approved. Undo that one first.');
    END IF;

    BEGIN TRANSACTION;

    INSERT INTO APP.T_F_APPROVAL_ACTION (REQUEST_ID, STEP_ORDER, ACTION_TYPE, ACTED_BY, ACTION_COMMENT, INSERT_BY, UPDATE_BY)
    SELECT :P_REQUEST_ID, :P_STEP_ORDER, 'UNDO', :P_USER_EMAIL, NULL, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_type = 'ACTUAL') THEN
        SELECT COUNT(*) INTO :v_remaining
        FROM RPT.V_F_APPROVAL_PROGRESS
        WHERE REQUEST_ID = :P_REQUEST_ID AND STEP_STATUS = 'APPROVED';
        IF (v_remaining = 0) THEN
            UPDATE APP.T_F_SCENARIO_PERIOD
            SET PERIOD_STATUS = 'OPEN', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
            WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :v_pk AND PERIOD_STATUS = 'IN_APPROVAL';
        END IF;
    END IF;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_APPROVAL_ACTION', OBJECT_CONSTRUCT('REQUEST_ID', :P_REQUEST_ID, 'STEP_ORDER', :P_STEP_ORDER), 'INSERT', NULL, OBJECT_CONSTRUCT('ACTION_TYPE', 'UNDO'), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Approval of step ' || P_STEP_ORDER || ' undone.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
