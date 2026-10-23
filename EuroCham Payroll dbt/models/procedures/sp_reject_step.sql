-- depends_on: {{ ref('t_d_scenario') }}, {{ ref('v_f_approval_progress') }}, {{ ref('t_d_app_user') }}, {{ ref('t_f_approval') }}, {{ ref('t_f_change_log') }}, {{ ref('t_f_scenario_period') }}
/* =====================================================================================
   SP_REJECT_STEP
   Sends an approval back one step for re-checking.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  Writes the step states to APP.T_F_APPROVAL_STEP_STATE (no more action log).
   2026-10-02  V1.5.0: identified by scenario + period instead of a request id; state in
               APP.T_F_APPROVAL; a rejected budget is simply REJECTED (no request to close);
               one role per user (T_D_APP_USER.ROLE_CODE).
   2026-10-06  V1.7.0 roles: the step's level (LEVEL_1 / LEVEL_2 / LEVEL_3) or ADMIN may act.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Monthly Inputs, Approval page, Budget Approval page ("Reject").

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   P_SCENARIO_ID / P_PERIOD_KEY: as for SP_APPROVE_STEP (0 or NULL = a whole budget).
   Rejecting takes the approval one step BACK; it does not cancel it.
   The step under review (the next step, N) is marked REJECTED with the comment, and the
   previous step (N - 1) goes back to PENDING (LAST_ACTION = SEND_BACK), so its approver
   checks again. That approver can approve again, or reject in turn to go back one more step.
   Rejecting step 1 sends the work back to the preparer:
   - payroll month: the month goes back to OPEN; step 1 approves again once the
     corrections are made;
   - budget: the scenario becomes REJECTED (editable again); it is resubmitted with
     SP_SUBMIT_SCENARIO, which restarts its approval.
   Role: the step's APPROVER_ROLE (LEVEL_1 / LEVEL_2 / LEVEL_3) or ADMIN. A comment is required.
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE {{ app() }}.SP_REJECT_STEP(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT,
                                               P_STEP_ORDER INT, P_COMMENT TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Rejects an approval step: sends the work back one step'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_type        TEXT;
    v_pk          INT;
    v_role        TEXT;
    v_step_status TEXT;
    v_is_next     INT;
    v_in_progress INT;
    v_appr_status TEXT;
    v_allowed     INT;
    v_prev_step   INT;
BEGIN
    IF (COALESCE(TRIM(P_COMMENT), '') = '') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A comment is required when rejecting.');
    END IF;

    SELECT MAX(SCENARIO_TYPE) INTO :v_type FROM {{ app() }}.T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' does not exist.');
    END IF;
    v_pk := IFF(v_type = 'ACTUAL', COALESCE(P_PERIOD_KEY, 0), 0);
    IF (v_type = 'ACTUAL' AND v_pk = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Give the payroll month to reject.');
    END IF;

    SELECT MAX(APPROVER_ROLE), MAX(STEP_STATUS), MAX(IFF(IS_NEXT_STEP, 1, 0)),
           MAX(IFF(IS_IN_PROGRESS, 1, 0)), MAX(APPROVAL_STATUS)
      INTO :v_role, :v_step_status, :v_is_next, :v_in_progress, :v_appr_status
    FROM {{ rpt() }}.V_F_APPROVAL_PROGRESS
    WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND STEP_ORDER = :P_STEP_ORDER;
    IF (v_role IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No approval step ' || P_STEP_ORDER || ' found for this ' ||
                                IFF(v_type = 'ACTUAL', 'payroll month', 'budget') || '.');
    END IF;
    IF (v_in_progress = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This approval is not in progress (status ' || v_appr_status || ').');
    END IF;

    SELECT COUNT(*) INTO :v_allowed
    FROM {{ app() }}.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE AND (u.ROLE_CODE = :v_role OR u.ROLE_CODE = 'ADMIN');
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only a user with role ' || v_role || ' (or ADMIN) can act on step ' || P_STEP_ORDER || '.');
    END IF;

    IF (v_is_next = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only the step currently under review (the next step) can be rejected.');
    END IF;

    SELECT MAX(STEP_ORDER) INTO :v_prev_step
    FROM {{ rpt() }}.V_F_APPROVAL_PROGRESS
    WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND STEP_ORDER < :P_STEP_ORDER;

    BEGIN TRANSACTION;

    MERGE INTO {{ app() }}.T_F_APPROVAL t
    USING (SELECT :P_SCENARIO_ID AS SCENARIO_ID, :v_pk AS PERIOD_KEY, :P_STEP_ORDER AS STEP_ORDER) s
       ON t.SCENARIO_ID = s.SCENARIO_ID AND t.PERIOD_KEY = s.PERIOD_KEY AND t.STEP_ORDER = s.STEP_ORDER
    WHEN MATCHED THEN UPDATE SET
        STEP_STATUS = 'REJECTED', LAST_ACTION = 'REJECT', ACTED_BY = :P_USER_EMAIL, ACTED_AT = CURRENT_TIMESTAMP,
        STEP_COMMENT = :P_COMMENT, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHEN NOT MATCHED THEN INSERT
        (SCENARIO_ID, PERIOD_KEY, STEP_ORDER, STEP_STATUS, LAST_ACTION, ACTED_BY, ACTED_AT, STEP_COMMENT, INSERT_BY, UPDATE_BY)
    VALUES
        (s.SCENARIO_ID, s.PERIOD_KEY, s.STEP_ORDER, 'REJECTED', 'REJECT', :P_USER_EMAIL, CURRENT_TIMESTAMP, :P_COMMENT,
         :P_USER_EMAIL, :P_USER_EMAIL);

    INSERT INTO {{ app() }}.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_APPROVAL',
           OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'PERIOD_KEY', :v_pk, 'STEP_ORDER', :P_STEP_ORDER), 'UPDATE',
           OBJECT_CONSTRUCT('STEP_STATUS', :v_step_status),
           OBJECT_CONSTRUCT('ACTION_TYPE', 'REJECT', 'STEP_STATUS', 'REJECTED', 'SENT_BACK_TO_STEP', :v_prev_step, 'COMMENT', :P_COMMENT),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_prev_step IS NOT NULL) THEN
        -- Back one step: the previous approval is withdrawn so that approver reviews again
        UPDATE {{ app() }}.T_F_APPROVAL
        SET STEP_STATUS = 'PENDING', LAST_ACTION = 'SEND_BACK', ACTED_BY = :P_USER_EMAIL, ACTED_AT = CURRENT_TIMESTAMP,
            STEP_COMMENT = 'Sent back by step ' || :P_STEP_ORDER || ': ' || :P_COMMENT,
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND STEP_ORDER = :v_prev_step;

        INSERT INTO {{ app() }}.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
        SELECT 'APP.T_F_APPROVAL',
               OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'PERIOD_KEY', :v_pk, 'STEP_ORDER', :v_prev_step), 'UPDATE',
               OBJECT_CONSTRUCT('STEP_STATUS', 'APPROVED'),
               OBJECT_CONSTRUCT('ACTION_TYPE', 'SEND_BACK', 'STEP_STATUS', 'PENDING',
                                'COMMENT', 'Sent back by step ' || :P_STEP_ORDER || ': ' || :P_COMMENT),
               :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;
    ELSEIF (v_type = 'ACTUAL') THEN
        -- Step 1 rejected: the month is open again for corrections
        UPDATE {{ app() }}.T_F_SCENARIO_PERIOD
        SET PERIOD_STATUS = 'OPEN', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND PERIOD_STATUS = 'IN_APPROVAL';
    ELSE
        -- Step 1 rejected: the budget is editable again and must be resubmitted
        UPDATE {{ app() }}.T_D_SCENARIO
        SET SCENARIO_STATUS = 'REJECTED', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID;
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
