-- depends_on: {{ ref('t_d_scenario') }}, {{ ref('v_f_approval_progress') }}, {{ ref('t_d_app_user') }}, {{ ref('t_f_approval') }}, {{ ref('t_f_scenario_period') }}, {{ ref('t_f_change_log') }}
/* =====================================================================================
   SP_UNDO_APPROVAL
   Undoes the most recent approval of a payroll month or a budget.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  Sets the step back to PENDING in APP.T_F_APPROVAL_STEP_STATE (no more action log).
   2026-10-02  V1.5.0: identified by scenario + period instead of a request id; state in
               APP.T_F_APPROVAL; one role per user (T_D_APP_USER.ROLE_CODE).
   2026-10-06  V1.7.0 roles: the step's level (LEVEL_1 / LEVEL_2 / LEVEL_3) or ADMIN may act.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Monthly Inputs, Approval page, Budget Approval page ("Undo Approval").

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   P_SCENARIO_ID / P_PERIOD_KEY: as for SP_APPROVE_STEP (0 or NULL = a whole budget).
   Rules: the approval is in progress (a finalized payroll or an approved budget cannot be
   undone); the step is APPROVED and no later step is approved; the user's role is the
   step's APPROVER_ROLE. When no approved step remains, a payroll month goes back to OPEN.
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE {{ app() }}.SP_UNDO_APPROVAL(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT, P_STEP_ORDER INT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Undoes the approval of one step'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_type        TEXT;
    v_pk          INT;
    v_role        TEXT;
    v_step_status TEXT;
    v_in_progress INT;
    v_appr_status TEXT;
    v_allowed     INT;
    v_later       INT;
    v_remaining   INT;
BEGIN
    SELECT MAX(SCENARIO_TYPE) INTO :v_type FROM {{ app() }}.T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' does not exist.');
    END IF;
    v_pk := IFF(v_type = 'ACTUAL', COALESCE(P_PERIOD_KEY, 0), 0);
    IF (v_type = 'ACTUAL' AND v_pk = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Give the payroll month.');
    END IF;

    SELECT MAX(APPROVER_ROLE), MAX(STEP_STATUS), MAX(IFF(IS_IN_PROGRESS, 1, 0)), MAX(APPROVAL_STATUS)
      INTO :v_role, :v_step_status, :v_in_progress, :v_appr_status
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

    IF (v_step_status <> 'APPROVED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Step ' || P_STEP_ORDER || ' is not approved.');
    END IF;

    SELECT COUNT(*) INTO :v_later
    FROM {{ rpt() }}.V_F_APPROVAL_PROGRESS
    WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND STEP_ORDER > :P_STEP_ORDER AND STEP_STATUS = 'APPROVED';
    IF (v_later > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A later step is already approved. Undo that one first.');
    END IF;

    BEGIN TRANSACTION;

    UPDATE {{ app() }}.T_F_APPROVAL
    SET STEP_STATUS = 'PENDING', LAST_ACTION = 'UNDO', ACTED_BY = :P_USER_EMAIL, ACTED_AT = CURRENT_TIMESTAMP,
        STEP_COMMENT = NULL, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND STEP_ORDER = :P_STEP_ORDER;

    IF (v_type = 'ACTUAL') THEN
        SELECT COUNT(*) INTO :v_remaining
        FROM {{ app() }}.T_F_APPROVAL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND STEP_STATUS = 'APPROVED';
        IF (v_remaining = 0) THEN
            UPDATE {{ app() }}.T_F_SCENARIO_PERIOD
            SET PERIOD_STATUS = 'OPEN', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
            WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND PERIOD_STATUS = 'IN_APPROVAL';
        END IF;
    END IF;

    INSERT INTO {{ app() }}.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_APPROVAL',
           OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'PERIOD_KEY', :v_pk, 'STEP_ORDER', :P_STEP_ORDER), 'UPDATE',
           OBJECT_CONSTRUCT('STEP_STATUS', 'APPROVED'),
           OBJECT_CONSTRUCT('ACTION_TYPE', 'UNDO', 'STEP_STATUS', 'PENDING'),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Approval of step ' || P_STEP_ORDER || ' undone.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
