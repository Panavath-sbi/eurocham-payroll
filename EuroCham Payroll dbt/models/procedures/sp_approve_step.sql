-- depends_on: {{ ref('t_d_scenario') }}, {{ ref('v_f_approval_progress') }}, {{ ref('t_d_app_user') }}, {{ ref('t_f_payroll_input') }}, {{ ref('t_f_approval') }}, {{ ref('t_f_scenario_period') }}, {{ ref('t_f_change_log') }}
/* =====================================================================================
   SP_APPROVE_STEP
   Approves one step of a payroll month or of a budget.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  Writes the step's state to APP.T_F_APPROVAL_STEP_STATE (no more action log).
               Only the step flagged MANAGES_EMPLOYEE_CHECKS (step 2) needs every employee
               CHECKED; the other steps are a plain approve.
   2026-10-02  V1.5.0: identified by scenario + period instead of a request id (the request
               table is gone); state in APP.T_F_APPROVAL; checks read from
               T_F_PAYROLL_INPUT; one role per user (T_D_APP_USER.ROLE_CODE).
   2026-10-06  V1.7.0 roles: the step's level (LEVEL_1 / LEVEL_2 / LEVEL_3) or ADMIN may act.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Monthly Inputs (step 1), Approval page (steps 2-3), Budget Approval page.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   P_SCENARIO_ID: the actual payroll scenario, or a budget.
   P_PERIOD_KEY:  the payroll month (YYYYMM); for a budget pass 0 or NULL (whole budget).
   Rules: the approval is in progress (payroll month OPEN or IN_APPROVAL; budget
   IN_APPROVAL); the step is the next one in order; the user's role is the step's
   APPROVER_ROLE. Payroll: if the step manages employee checks (step 2), every employee
   must be CHECKED first.
   Final step of a BUDGET: the scenario becomes APPROVED and the official budget of its
   year (the previous official budget of that year loses the flag); its periods lock.
   Final step of a payroll month: the month is ready for SP_FINALIZE_PAYROLL.
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE SP_APPROVE_STEP(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT,
                                                P_STEP_ORDER INT, P_COMMENT TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Approves one approval step of a payroll month or a budget'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_type        TEXT;
    v_pk          INT;
    v_role        TEXT;
    v_step_status TEXT;
    v_is_next     INT;
    v_checks      INT;
    v_in_progress INT;
    v_appr_status TEXT;
    v_allowed     INT;
    v_unchecked   INT DEFAULT 0;
    v_last_step   INT;
    v_year        INT;
BEGIN
    SELECT MAX(SCENARIO_TYPE), MAX(FISCAL_YEAR) INTO :v_type, :v_year
    FROM T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' does not exist.');
    END IF;
    v_pk := IFF(v_type = 'ACTUAL', COALESCE(P_PERIOD_KEY, 0), 0);
    IF (v_type = 'ACTUAL' AND v_pk = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Give the payroll month to approve.');
    END IF;

    SELECT MAX(APPROVER_ROLE), MAX(STEP_STATUS), MAX(IFF(IS_NEXT_STEP, 1, 0)),
           MAX(IFF(MANAGES_EMPLOYEE_CHECKS, 1, 0)), MAX(IFF(IS_IN_PROGRESS, 1, 0)), MAX(APPROVAL_STATUS)
      INTO :v_role, :v_step_status, :v_is_next, :v_checks, :v_in_progress, :v_appr_status
    FROM V_F_APPROVAL_PROGRESS
    WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND STEP_ORDER = :P_STEP_ORDER;
    IF (v_role IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No approval step ' || P_STEP_ORDER || ' found for this ' ||
                                IFF(v_type = 'ACTUAL', 'payroll month', 'budget') || '.');
    END IF;
    IF (v_in_progress = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This approval is not in progress (status ' || v_appr_status || ').');
    END IF;

    SELECT COUNT(*) INTO :v_allowed
    FROM T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE AND (u.ROLE_CODE = :v_role OR u.ROLE_CODE = 'ADMIN');
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only a user with role ' || v_role || ' (or ADMIN) can act on step ' || P_STEP_ORDER || '.');
    END IF;

    IF (v_step_status = 'APPROVED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Step ' || P_STEP_ORDER || ' is already approved.');
    END IF;
    IF (v_is_next = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Step ' || P_STEP_ORDER || ' is not the next step to approve.');
    END IF;

    -- Only the step that manages employee checks needs everyone CHECKED
    IF (v_checks = 1) THEN
        SELECT COUNT(*) INTO :v_unchecked
        FROM T_F_PAYROLL_INPUT
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND INCLUDE_IN_PAYROLL
          AND COALESCE(CHECK_STATUS, 'PENDING') <> 'CHECKED';
        IF (v_unchecked > 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_unchecked || ' employee(s) are not checked yet for this step.');
        END IF;
    END IF;

    SELECT MAX(STEP_ORDER) INTO :v_last_step
    FROM V_F_APPROVAL_PROGRESS WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk;

    BEGIN TRANSACTION;

    MERGE INTO T_F_APPROVAL t
    USING (SELECT :P_SCENARIO_ID AS SCENARIO_ID, :v_pk AS PERIOD_KEY, :P_STEP_ORDER AS STEP_ORDER) s
       ON t.SCENARIO_ID = s.SCENARIO_ID AND t.PERIOD_KEY = s.PERIOD_KEY AND t.STEP_ORDER = s.STEP_ORDER
    WHEN MATCHED THEN UPDATE SET
        STEP_STATUS = 'APPROVED', LAST_ACTION = 'APPROVE', ACTED_BY = :P_USER_EMAIL, ACTED_AT = CURRENT_TIMESTAMP,
        STEP_COMMENT = :P_COMMENT, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHEN NOT MATCHED THEN INSERT
        (SCENARIO_ID, PERIOD_KEY, STEP_ORDER, STEP_STATUS, LAST_ACTION, ACTED_BY, ACTED_AT, STEP_COMMENT, INSERT_BY, UPDATE_BY)
    VALUES
        (s.SCENARIO_ID, s.PERIOD_KEY, s.STEP_ORDER, 'APPROVED', 'APPROVE', :P_USER_EMAIL, CURRENT_TIMESTAMP, :P_COMMENT,
         :P_USER_EMAIL, :P_USER_EMAIL);

    IF (v_type = 'ACTUAL') THEN
        UPDATE T_F_SCENARIO_PERIOD
        SET PERIOD_STATUS = 'IN_APPROVAL', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND PERIOD_STATUS = 'OPEN';
    END IF;

    IF (v_type = 'BUDGET' AND P_STEP_ORDER = v_last_step) THEN
        UPDATE T_D_SCENARIO
        SET IS_OFFICIAL = FALSE, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_TYPE = 'BUDGET' AND FISCAL_YEAR = :v_year AND IS_OFFICIAL AND SCENARIO_ID <> :P_SCENARIO_ID;

        UPDATE T_D_SCENARIO
        SET SCENARIO_STATUS = 'APPROVED', IS_OFFICIAL = TRUE, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID;

        UPDATE T_F_SCENARIO_PERIOD
        SET PERIOD_STATUS = 'LOCKED', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID;
    END IF;

    INSERT INTO T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_APPROVAL',
           OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'PERIOD_KEY', :v_pk, 'STEP_ORDER', :P_STEP_ORDER), 'UPDATE',
           OBJECT_CONSTRUCT('STEP_STATUS', :v_step_status),
           OBJECT_CONSTRUCT('ACTION_TYPE', 'APPROVE', 'STEP_STATUS', 'APPROVED', 'COMMENT', :P_COMMENT),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

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
