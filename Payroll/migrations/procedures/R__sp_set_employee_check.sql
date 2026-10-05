/* =====================================================================================
   R - SP_SET_EMPLOYEE_CHECK
   Checks, rejects or re-opens employees of the payroll month (per-employee validation).
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  One check per employee per payroll month (no step column). Only the step
               flagged MANAGES_EMPLOYEE_CHECKS (step 2) can set checks; actual payroll only.
   2026-10-02  V1.5.0: the check is stored on the employee's T_F_PAYROLL_INPUT row
               (CHECK_STATUS, CHECK_COMMENT, CHECKED_BY); takes the payroll month instead
               of a request id; one role per user (T_D_APP_USER.ROLE_CODE).
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   Approval page: the per-employee check / reject buttons and "Approve All".

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* P_PERIOD_KEY:   the payroll month (YYYYMM) of the actual payroll.
   P_STEP_ORDER:   must be the step that manages employee checks (MANAGES_EMPLOYEE_CHECKS,
                   step 2). Other steps get an error.
   P_EMPLOYEE_IDS: JSON array of employee ids, e.g. '[7, 12]'.
                   NULL = "Approve All": every employee still PENDING becomes CHECKED
                   (rejected employees are left as they are).
   P_CHECK_STATUS: CHECKED, REJECTED (comment required) or PENDING.
   The month must be OPEN or IN_APPROVAL. Role: the step's APPROVER_ROLE. The step must not
   be approved yet. There is one check per employee for the month. */
USE DATABASE PAYROLL_DB;

CREATE OR REPLACE PROCEDURE APP.SP_SET_EMPLOYEE_CHECK(P_USER_EMAIL TEXT, P_PERIOD_KEY INT, P_STEP_ORDER INT,
                                                      P_EMPLOYEE_IDS TEXT, P_CHECK_STATUS TEXT, P_COMMENT TEXT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Sets the per-employee check of the payroll month'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_scen        INT;
    v_role        TEXT;
    v_step_status TEXT;
    v_checks      INT;
    v_in_progress INT;
    v_appr_status TEXT;
    v_allowed     INT;
    v_unknown     INT;
    v_changed     INT DEFAULT 0;
BEGIN
    IF (P_CHECK_STATUS IS NULL OR (P_CHECK_STATUS <> 'CHECKED' AND P_CHECK_STATUS <> 'REJECTED' AND P_CHECK_STATUS <> 'PENDING')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Check status must be CHECKED, REJECTED or PENDING.');
    END IF;
    IF (P_CHECK_STATUS = 'REJECTED' AND COALESCE(TRIM(P_COMMENT), '') = '') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A comment is required when rejecting an employee.');
    END IF;
    IF (P_EMPLOYEE_IDS IS NULL AND P_CHECK_STATUS <> 'CHECKED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Approve All can only set employees to CHECKED.');
    END IF;

    SELECT MAX(SCENARIO_ID) INTO :v_scen FROM APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'ACTUAL';

    SELECT MAX(APPROVER_ROLE), MAX(STEP_STATUS), MAX(IFF(MANAGES_EMPLOYEE_CHECKS, 1, 0)),
           MAX(IFF(IS_IN_PROGRESS, 1, 0)), MAX(APPROVAL_STATUS)
      INTO :v_role, :v_step_status, :v_checks, :v_in_progress, :v_appr_status
    FROM RPT.V_F_APPROVAL_PROGRESS
    WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :P_PERIOD_KEY AND STEP_ORDER = :P_STEP_ORDER;
    IF (v_role IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No approval step ' || P_STEP_ORDER || ' found for payroll ' || P_PERIOD_KEY || '.');
    END IF;
    IF (v_in_progress = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Payroll ' || P_PERIOD_KEY || ' is ' || v_appr_status || '.');
    END IF;
    IF (v_checks = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Step ' || P_STEP_ORDER || ' does not use per-employee checks.');
    END IF;

    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE AND u.ROLE_CODE = :v_role;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only a user with role ' || v_role || ' can act on step ' || P_STEP_ORDER || '.');
    END IF;

    IF (v_step_status = 'APPROVED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Step ' || P_STEP_ORDER || ' is already approved. Undo the approval first.');
    END IF;

    IF (P_EMPLOYEE_IDS IS NOT NULL) THEN
        SELECT COUNT(*) INTO :v_unknown
        FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_EMPLOYEE_IDS))) f
        WHERE f.VALUE::INT NOT IN (SELECT i.EMPLOYEE_ID FROM APP.T_F_PAYROLL_INPUT i
                                   WHERE i.SCENARIO_ID = :v_scen AND i.PERIOD_KEY = :P_PERIOD_KEY AND i.INCLUDE_IN_PAYROLL);
        IF (v_unknown > 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_unknown || ' employee(s) are not part of this payroll.');
        END IF;
    END IF;

    BEGIN TRANSACTION;

    UPDATE APP.T_F_PAYROLL_INPUT
    SET CHECK_STATUS  = :P_CHECK_STATUS,
        CHECK_COMMENT = :P_COMMENT,
        CHECKED_BY    = IFF(:P_CHECK_STATUS = 'PENDING', NULL, :P_USER_EMAIL),
        UPDATE_DATE   = CURRENT_TIMESTAMP,
        UPDATE_BY     = :P_USER_EMAIL
    WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :P_PERIOD_KEY AND INCLUDE_IN_PAYROLL
      AND (   (:P_EMPLOYEE_IDS IS NULL AND COALESCE(CHECK_STATUS, 'PENDING') = 'PENDING')
           OR (:P_EMPLOYEE_IDS IS NOT NULL
               AND EMPLOYEE_ID IN (SELECT f.VALUE::INT FROM TABLE(FLATTEN(INPUT => PARSE_JSON(COALESCE(:P_EMPLOYEE_IDS, '[]')))) f)));
    v_changed := SQLROWCOUNT;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_PAYROLL_INPUT', OBJECT_CONSTRUCT('SCENARIO_ID', :v_scen, 'PERIOD_KEY', :P_PERIOD_KEY), 'UPDATE', NULL,
           OBJECT_CONSTRUCT('EMPLOYEE_IDS', PARSE_JSON(COALESCE(:P_EMPLOYEE_IDS, '"ALL_PENDING"')),
                            'CHECK_STATUS', :P_CHECK_STATUS, 'CHECK_COMMENT', :P_COMMENT, 'STEP_ORDER', :P_STEP_ORDER),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_changed || ' employee check(s) set to ' || P_CHECK_STATUS || '.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
