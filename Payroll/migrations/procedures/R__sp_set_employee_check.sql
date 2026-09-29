/* =====================================================================================
   R - SP_SET_EMPLOYEE_CHECK
   Checks, rejects or re-opens employees for one approval step (per-employee validation).
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
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

/* P_EMPLOYEE_IDS: JSON array of employee ids, e.g. '[7, 12]'.
                   NULL = "Approve All": every employee still PENDING for the step becomes CHECKED
                   (rejected employees are left as they are).
   P_CHECK_STATUS: CHECKED, REJECTED (comment required) or PENDING.
   Role: the step's APPROVER_ROLE. The step must not be approved yet. */
USE DATABASE PAYROLL_DB;
   
CREATE OR REPLACE PROCEDURE APP.SP_SET_EMPLOYEE_CHECK(P_USER_EMAIL TEXT, P_REQUEST_ID INT, P_STEP_ORDER INT,
                                                      P_EMPLOYEE_IDS TEXT, P_CHECK_STATUS TEXT, P_COMMENT TEXT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Sets the per-employee check of one approval step'
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
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Step ' || P_STEP_ORDER || ' is already approved. Undo the approval first.');
    END IF;

    IF (P_EMPLOYEE_IDS IS NOT NULL) THEN
        SELECT COUNT(*) INTO :v_unknown
        FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_EMPLOYEE_IDS))) f
        WHERE f.VALUE::INT NOT IN (SELECT i.EMPLOYEE_ID FROM APP.T_F_PAYROLL_INPUT i
               WHERE :v_type = 'ACTUAL' AND i.SCENARIO_ID = :v_scen AND i.PERIOD_KEY = :v_pk AND i.INCLUDE_IN_PAYROLL
               UNION
               SELECT se.EMPLOYEE_ID FROM APP.T_D_SCENARIO_EMPLOYEE se
               WHERE :v_type <> 'ACTUAL' AND se.SCENARIO_ID = :v_scen);
        IF (v_unknown > 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_unknown || ' employee(s) are not part of this payroll.');
        END IF;
    END IF;

    BEGIN TRANSACTION;

    MERGE INTO APP.T_F_APPROVAL_EMPLOYEE_CHECK t
    USING (
        SELECT p.EMPLOYEE_ID
        FROM (SELECT i.EMPLOYEE_ID FROM APP.T_F_PAYROLL_INPUT i
               WHERE :v_type = 'ACTUAL' AND i.SCENARIO_ID = :v_scen AND i.PERIOD_KEY = :v_pk AND i.INCLUDE_IN_PAYROLL
               UNION
               SELECT se.EMPLOYEE_ID FROM APP.T_D_SCENARIO_EMPLOYEE se
               WHERE :v_type <> 'ACTUAL' AND se.SCENARIO_ID = :v_scen) p
        LEFT JOIN APP.T_F_APPROVAL_EMPLOYEE_CHECK c
               ON c.REQUEST_ID = :P_REQUEST_ID AND c.STEP_ORDER = :P_STEP_ORDER AND c.EMPLOYEE_ID = p.EMPLOYEE_ID
        WHERE (:P_EMPLOYEE_IDS IS NULL AND COALESCE(c.CHECK_STATUS, 'PENDING') = 'PENDING')
           OR (:P_EMPLOYEE_IDS IS NOT NULL
               AND p.EMPLOYEE_ID IN (SELECT f.VALUE::INT FROM TABLE(FLATTEN(INPUT => PARSE_JSON(COALESCE(:P_EMPLOYEE_IDS, '[]')))) f))
    ) s
       ON t.REQUEST_ID = :P_REQUEST_ID AND t.STEP_ORDER = :P_STEP_ORDER AND t.EMPLOYEE_ID = s.EMPLOYEE_ID
    WHEN MATCHED THEN UPDATE SET
        CHECK_STATUS  = :P_CHECK_STATUS,
        CHECK_COMMENT = :P_COMMENT,
        CHECKED_BY    = IFF(:P_CHECK_STATUS = 'PENDING', NULL, :P_USER_EMAIL),
        UPDATE_DATE   = CURRENT_TIMESTAMP,
        UPDATE_BY     = :P_USER_EMAIL
    WHEN NOT MATCHED THEN INSERT
        (REQUEST_ID, STEP_ORDER, EMPLOYEE_ID, CHECK_STATUS, CHECK_COMMENT, CHECKED_BY, INSERT_BY, UPDATE_BY)
    VALUES
        (:P_REQUEST_ID, :P_STEP_ORDER, s.EMPLOYEE_ID, :P_CHECK_STATUS, :P_COMMENT,
         IFF(:P_CHECK_STATUS = 'PENDING', NULL, :P_USER_EMAIL), :P_USER_EMAIL, :P_USER_EMAIL);
    v_changed := SQLROWCOUNT;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_APPROVAL_EMPLOYEE_CHECK', OBJECT_CONSTRUCT('REQUEST_ID', :P_REQUEST_ID, 'STEP_ORDER', :P_STEP_ORDER), 'UPDATE', NULL, OBJECT_CONSTRUCT('EMPLOYEE_IDS', PARSE_JSON(COALESCE(:P_EMPLOYEE_IDS, '"ALL_PENDING"')), 'CHECK_STATUS', :P_CHECK_STATUS, 'COMMENT', :P_COMMENT), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_changed || ' employee check(s) set to ' || P_CHECK_STATUS || '.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
