/* =====================================================================================
   R - SP_SAVE_APPROVAL_STEPS
   Renames approval steps and assigns their approvers.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   Settings page: Approval Settings.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* P_STEPS: JSON array, e.g.
   '[{"step_order": 1, "step_title": "HR Manager", "approver_email": "hr@example.org", "approver_name": "Jane Doe"}]'
   step_order must be a step of the current chain (steps are not added or removed here).
   A new title applies from the current calendar month: the step version in force is
   closed the month before and a new version is added (or corrected if it started this month).
   approver_email: the user is created if new, gets the step's APPROVER_ROLE, and every
   other user loses that role. Role: PAYROLL_ADMIN. */
USE DATABASE PAYROLL_DB;
   
CREATE OR REPLACE PROCEDURE APP.SP_SAVE_APPROVAL_STEPS(P_USER_EMAIL TEXT, P_STEPS TEXT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Renames approval steps and assigns approvers'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_allowed INT;
    v_now     INT;
    v_prev    INT;
    v_rows    INT;
    v_bad     INT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    JOIN APP.T_D_APP_USER_ROLE r ON r.USER_EMAIL = u.USER_EMAIL
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE AND r.ROLE_CODE IN ('PAYROLL_ADMIN');
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only a payroll admin can do this.');
    END IF;

    v_now := TO_NUMBER(TO_CHAR(CURRENT_DATE(), 'YYYYMM'));
    v_prev := TO_NUMBER(TO_CHAR(DATEADD(MONTH, -1, DATE_TRUNC('MONTH', CURRENT_DATE())), 'YYYYMM'));

    CREATE OR REPLACE TEMPORARY TABLE APP.TMP_STEPS AS
    SELECT f.VALUE:step_order::INT AS STEP_ORDER,
           NULLIF(TRIM(f.VALUE:step_title::TEXT), '') AS STEP_TITLE,
           LOWER(NULLIF(TRIM(f.VALUE:approver_email::TEXT), '')) AS APPROVER_EMAIL,
           NULLIF(TRIM(f.VALUE:approver_name::TEXT), '') AS APPROVER_NAME,
           s.APPROVAL_STEP_ID, s.STEP_TITLE AS OLD_TITLE, s.APPROVER_ROLE, s.APPLIES_TO, s.VALID_FROM_PERIOD_KEY
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_STEPS))) f
    LEFT JOIN CORE.T_P_APPROVAL_STEP s
           ON s.STEP_ORDER = f.VALUE:step_order::INT AND s.IS_ACTIVE
          AND :v_now BETWEEN s.VALID_FROM_PERIOD_KEY AND COALESCE(s.VALID_TO_PERIOD_KEY, 999912);

    SELECT COUNT(*), COUNT_IF(APPROVAL_STEP_ID IS NULL OR (STEP_TITLE IS NULL AND APPROVER_EMAIL IS NULL))
      INTO :v_rows, :v_bad
    FROM APP.TMP_STEPS;
    IF (v_rows = 0 OR v_bad > 0) THEN
        DROP TABLE IF EXISTS APP.TMP_STEPS;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each row needs an existing step_order and a step_title or approver_email.');
    END IF;

    BEGIN TRANSACTION;

    -- Titles: correct a version that started this month; otherwise close it and add a new one
    UPDATE CORE.T_P_APPROVAL_STEP s
    SET STEP_TITLE = t.STEP_TITLE, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM APP.TMP_STEPS t
    WHERE s.APPROVAL_STEP_ID = t.APPROVAL_STEP_ID AND t.STEP_TITLE IS NOT NULL
      AND t.STEP_TITLE <> t.OLD_TITLE AND t.VALID_FROM_PERIOD_KEY = :v_now;

    INSERT INTO CORE.T_P_APPROVAL_STEP (STEP_ORDER, STEP_TITLE, APPROVER_ROLE, APPLIES_TO, VALID_FROM_PERIOD_KEY, IS_ACTIVE, INSERT_BY, UPDATE_BY)
    SELECT STEP_ORDER, STEP_TITLE, APPROVER_ROLE, APPLIES_TO, :v_now, TRUE, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.TMP_STEPS
    WHERE STEP_TITLE IS NOT NULL AND STEP_TITLE <> OLD_TITLE AND VALID_FROM_PERIOD_KEY < :v_now;

    UPDATE CORE.T_P_APPROVAL_STEP s
    SET VALID_TO_PERIOD_KEY = :v_prev, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM APP.TMP_STEPS t
    WHERE s.APPROVAL_STEP_ID = t.APPROVAL_STEP_ID AND t.STEP_TITLE IS NOT NULL
      AND t.STEP_TITLE <> t.OLD_TITLE AND t.VALID_FROM_PERIOD_KEY < :v_now;

    -- Approvers
    INSERT INTO APP.T_D_APP_USER (USER_EMAIL, DISPLAY_NAME, INSERT_BY, UPDATE_BY)
    SELECT DISTINCT t.APPROVER_EMAIL, COALESCE(t.APPROVER_NAME, t.APPROVER_EMAIL), :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.TMP_STEPS t
    WHERE t.APPROVER_EMAIL IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM APP.T_D_APP_USER u WHERE u.USER_EMAIL = t.APPROVER_EMAIL);

    DELETE FROM APP.T_D_APP_USER_ROLE r
    USING APP.TMP_STEPS t
    WHERE t.APPROVER_EMAIL IS NOT NULL AND r.ROLE_CODE = t.APPROVER_ROLE AND r.USER_EMAIL <> t.APPROVER_EMAIL;

    INSERT INTO APP.T_D_APP_USER_ROLE (USER_EMAIL, ROLE_CODE, INSERT_BY, UPDATE_BY)
    SELECT DISTINCT t.APPROVER_EMAIL, t.APPROVER_ROLE, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.TMP_STEPS t
    WHERE t.APPROVER_EMAIL IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM APP.T_D_APP_USER_ROLE r WHERE r.USER_EMAIL = t.APPROVER_EMAIL AND r.ROLE_CODE = t.APPROVER_ROLE);

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'CORE.T_P_APPROVAL_STEP', OBJECT_CONSTRUCT('STEP_ORDER', STEP_ORDER), 'UPDATE',
           OBJECT_CONSTRUCT('STEP_TITLE', OLD_TITLE),
           OBJECT_CONSTRUCT('STEP_TITLE', STEP_TITLE, 'APPROVER_EMAIL', APPROVER_EMAIL),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.TMP_STEPS;

    COMMIT;
    DROP TABLE IF EXISTS APP.TMP_STEPS;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_rows || ' approval step(s) saved.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        DROP TABLE IF EXISTS APP.TMP_STEPS;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
