/* =====================================================================================
   R - SP_REJECT_STEP
   Sends an approval back one step for re-checking.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  Writes the step states to APP.T_F_APPROVAL_STEP_STATE (no more action log).
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   Monthly Inputs, Approval page, Budget Approval page ("Reject").

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* Rejecting takes the approval one step BACK; it does not cancel it.
   The step under review (the next step, N) is marked REJECTED with the comment, and the
   previous step (N - 1) goes back to PENDING (LAST_ACTION = SEND_BACK), so its approver checks
   again. That approver can approve again, or reject in turn to go back one more step.
   Rejecting step 1 sends the work back to the preparer:
   - actual payroll: the month goes back to OPEN; the request stays open, so step 1
     approves again once the corrections are made;
   - budget: the scenario becomes REJECTED (editable) and the request is closed;
     it is resubmitted with SP_SUBMIT_SCENARIO.
   Role: the step's APPROVER_ROLE. A comment is required. */
USE DATABASE PAYROLL_DB;
   
CREATE OR REPLACE PROCEDURE APP.SP_REJECT_STEP(P_USER_EMAIL TEXT, P_REQUEST_ID INT, P_STEP_ORDER INT, P_COMMENT TEXT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Sends an approval back one step'
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
    v_prev_step   INT;
BEGIN
    IF (COALESCE(TRIM(P_COMMENT), '') = '') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A comment is required when rejecting.');
    END IF;

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

    IF (v_is_next = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only the step currently under review (the next step) can be rejected.');
    END IF;

    SELECT MAX(STEP_ORDER) INTO :v_prev_step
    FROM RPT.V_F_APPROVAL_PROGRESS
    WHERE REQUEST_ID = :P_REQUEST_ID AND STEP_ORDER < :P_STEP_ORDER;

    BEGIN TRANSACTION;

    MERGE INTO APP.T_F_APPROVAL_STEP_STATE t
    USING (SELECT :P_REQUEST_ID AS REQUEST_ID, :P_STEP_ORDER AS STEP_ORDER) s
       ON t.REQUEST_ID = s.REQUEST_ID AND t.STEP_ORDER = s.STEP_ORDER
    WHEN MATCHED THEN UPDATE SET
        STEP_STATUS = 'REJECTED', LAST_ACTION = 'REJECT', ACTED_BY = :P_USER_EMAIL, ACTED_AT = CURRENT_TIMESTAMP,
        STEP_COMMENT = :P_COMMENT, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHEN NOT MATCHED THEN INSERT
        (REQUEST_ID, STEP_ORDER, STEP_STATUS, LAST_ACTION, ACTED_BY, ACTED_AT, STEP_COMMENT, INSERT_BY, UPDATE_BY)
    VALUES
        (s.REQUEST_ID, s.STEP_ORDER, 'REJECTED', 'REJECT', :P_USER_EMAIL, CURRENT_TIMESTAMP, :P_COMMENT, :P_USER_EMAIL, :P_USER_EMAIL);

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_APPROVAL_STEP_STATE', OBJECT_CONSTRUCT('REQUEST_ID', :P_REQUEST_ID, 'STEP_ORDER', :P_STEP_ORDER), 'UPDATE',
           OBJECT_CONSTRUCT('STEP_STATUS', :v_step_status),
           OBJECT_CONSTRUCT('ACTION_TYPE', 'REJECT', 'STEP_STATUS', 'REJECTED', 'SENT_BACK_TO_STEP', :v_prev_step, 'COMMENT', :P_COMMENT),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_prev_step IS NOT NULL) THEN
        -- Back one step: the previous approval is withdrawn so that approver reviews again
        UPDATE APP.T_F_APPROVAL_STEP_STATE
        SET STEP_STATUS = 'PENDING', LAST_ACTION = 'SEND_BACK', ACTED_BY = :P_USER_EMAIL, ACTED_AT = CURRENT_TIMESTAMP,
            STEP_COMMENT = 'Sent back by step ' || :P_STEP_ORDER || ': ' || :P_COMMENT,
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE REQUEST_ID = :P_REQUEST_ID AND STEP_ORDER = :v_prev_step;

        INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
        SELECT 'APP.T_F_APPROVAL_STEP_STATE', OBJECT_CONSTRUCT('REQUEST_ID', :P_REQUEST_ID, 'STEP_ORDER', :v_prev_step), 'UPDATE',
               OBJECT_CONSTRUCT('STEP_STATUS', 'APPROVED'),
               OBJECT_CONSTRUCT('ACTION_TYPE', 'SEND_BACK', 'STEP_STATUS', 'PENDING',
                                'COMMENT', 'Sent back by step ' || :P_STEP_ORDER || ': ' || :P_COMMENT),
               :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;
    ELSEIF (v_type = 'ACTUAL') THEN
        -- Back to the preparer: the month is open for corrections, the request stays open
        UPDATE APP.T_F_SCENARIO_PERIOD
        SET PERIOD_STATUS = 'OPEN', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :v_pk AND PERIOD_STATUS = 'IN_APPROVAL';
    ELSE
        -- Budget back to the preparer: editable again, resubmitted later
        UPDATE APP.T_F_APPROVAL_REQUEST
        SET REQUEST_STATUS = 'REJECTED', COMPLETED_AT = CURRENT_TIMESTAMP, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE REQUEST_ID = :P_REQUEST_ID;
        UPDATE APP.T_D_SCENARIO
        SET SCENARIO_STATUS = 'REJECTED', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :v_scen;
    END IF;

    COMMIT;
    IF (v_prev_step IS NOT NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Sent back to step ' || v_prev_step || ' for re-checking.');
    END IF;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Sent back to the preparer. The ' ||
                            IFF(v_type = 'ACTUAL', 'payroll month', 'scenario') || ' is open for corrections.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
