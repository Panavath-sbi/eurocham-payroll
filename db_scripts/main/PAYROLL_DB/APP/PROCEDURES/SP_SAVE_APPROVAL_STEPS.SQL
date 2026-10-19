/* =====================================================================================
   SP_SAVE_APPROVAL_STEPS
   Renames approval steps and assigns their approvers.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  A renamed step keeps its MANAGES_EMPLOYEE_CHECKS flag in the new version.
   2026-10-02  V1.5.0: one role per user (T_D_APP_USER.ROLE_CODE): the new approver gets the
               step's role, and whoever held it before becomes VIEWER. Two steps cannot
               share one approver, and the admin cannot make themselves an approver.
               CORE tables moved to APP.
   2026-10-06  V1.7.0 roles: any active app user may call this. Several people can hold the
               same level, so the previous holders keep their level (no more VIEWER);
               users may assign themselves. Still: one person cannot be put on two steps.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Settings page: Approval Settings.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   P_STEPS: JSON array, e.g.
   '[{"step_order": 1, "step_title": "HR Manager", "approver_email": "hr@example.org", "approver_name": "Jane Doe"}]'
   step_order must be a step of the current chain (steps are not added or removed here).
   A new title applies from the current calendar month: the step version in force is
   closed the month before and a new version is added (or corrected if it started this month).
   approver_email: the user is created if new and gets the step's APPROVER_ROLE
   (LEVEL_1 / LEVEL_2 / LEVEL_3) as their one role, replacing the role they had. Other
   holders of that level keep it (several people can share a level). The same person
   cannot be put on two steps. Anyone may assign themselves. ADMIN is set in Snowflake
   only, never here. Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE ${DB}.APP.SP_SAVE_APPROVAL_STEPS(P_USER_EMAIL TEXT, P_STEPS TEXT)
COPY GRANTS
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
    FROM ${DB}.APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    v_now := TO_NUMBER(TO_CHAR(CURRENT_DATE(), 'YYYYMM'));
    v_prev := TO_NUMBER(TO_CHAR(DATEADD(MONTH, -1, DATE_TRUNC('MONTH', CURRENT_DATE())), 'YYYYMM'));

    CREATE OR REPLACE TEMPORARY TABLE ${DB}.APP.TMP_STEPS AS
    SELECT f.VALUE:step_order::INT AS STEP_ORDER,
           NULLIF(TRIM(f.VALUE:step_title::TEXT), '') AS STEP_TITLE,
           LOWER(NULLIF(TRIM(f.VALUE:approver_email::TEXT), '')) AS APPROVER_EMAIL,
           NULLIF(TRIM(f.VALUE:approver_name::TEXT), '') AS APPROVER_NAME,
           s.APPROVAL_STEP_ID, s.STEP_TITLE AS OLD_TITLE, s.APPROVER_ROLE, s.APPLIES_TO, s.VALID_FROM_PERIOD_KEY,
           COALESCE(s.MANAGES_EMPLOYEE_CHECKS, FALSE) AS MANAGES_EMPLOYEE_CHECKS
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_STEPS))) f
    LEFT JOIN ${DB}.APP.T_P_APPROVAL_STEP s
           ON s.STEP_ORDER = f.VALUE:step_order::INT AND s.IS_ACTIVE
          AND :v_now BETWEEN s.VALID_FROM_PERIOD_KEY AND COALESCE(s.VALID_TO_PERIOD_KEY, 999912);

    SELECT COUNT(*), COUNT_IF(APPROVAL_STEP_ID IS NULL OR (STEP_TITLE IS NULL AND APPROVER_EMAIL IS NULL))
      INTO :v_rows, :v_bad
    FROM ${DB}.APP.TMP_STEPS;
    IF (v_rows = 0 OR v_bad > 0) THEN
        DROP TABLE IF EXISTS ${DB}.APP.TMP_STEPS;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each row needs an existing step_order and a step_title or approver_email.');
    END IF;

    -- One role per user: one person cannot be the approver of two steps
    SELECT COUNT(*) INTO :v_bad
    FROM (SELECT APPROVER_EMAIL FROM ${DB}.APP.TMP_STEPS WHERE APPROVER_EMAIL IS NOT NULL
          GROUP BY APPROVER_EMAIL HAVING COUNT(DISTINCT APPROVER_ROLE) > 1);
    IF (v_bad > 0) THEN
        DROP TABLE IF EXISTS ${DB}.APP.TMP_STEPS;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The same person cannot be the approver of two steps (one role per user).');
    END IF;

    BEGIN TRANSACTION;

    -- Titles: correct a version that started this month; otherwise close it and add a new one
    UPDATE ${DB}.APP.T_P_APPROVAL_STEP s
    SET STEP_TITLE = t.STEP_TITLE, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM ${DB}.APP.TMP_STEPS t
    WHERE s.APPROVAL_STEP_ID = t.APPROVAL_STEP_ID AND t.STEP_TITLE IS NOT NULL
      AND t.STEP_TITLE <> t.OLD_TITLE AND t.VALID_FROM_PERIOD_KEY = :v_now;

    INSERT INTO ${DB}.APP.T_P_APPROVAL_STEP (STEP_ORDER, STEP_TITLE, APPROVER_ROLE, APPLIES_TO, VALID_FROM_PERIOD_KEY, IS_ACTIVE, MANAGES_EMPLOYEE_CHECKS, INSERT_BY, UPDATE_BY)
    SELECT STEP_ORDER, STEP_TITLE, APPROVER_ROLE, APPLIES_TO, :v_now, TRUE, MANAGES_EMPLOYEE_CHECKS, :P_USER_EMAIL, :P_USER_EMAIL
    FROM ${DB}.APP.TMP_STEPS
    WHERE STEP_TITLE IS NOT NULL AND STEP_TITLE <> OLD_TITLE AND VALID_FROM_PERIOD_KEY < :v_now;

    UPDATE ${DB}.APP.T_P_APPROVAL_STEP s
    SET VALID_TO_PERIOD_KEY = :v_prev, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM ${DB}.APP.TMP_STEPS t
    WHERE s.APPROVAL_STEP_ID = t.APPROVAL_STEP_ID AND t.STEP_TITLE IS NOT NULL
      AND t.STEP_TITLE <> t.OLD_TITLE AND t.VALID_FROM_PERIOD_KEY < :v_now;

    -- Approvers: the new approver gets the step's level (created if new); other holders keep theirs
    MERGE INTO ${DB}.APP.T_D_APP_USER u
    USING (SELECT APPROVER_EMAIL, MAX(APPROVER_NAME) AS APPROVER_NAME, MAX(APPROVER_ROLE) AS APPROVER_ROLE
           FROM ${DB}.APP.TMP_STEPS WHERE APPROVER_EMAIL IS NOT NULL GROUP BY APPROVER_EMAIL) t
       ON u.USER_EMAIL = t.APPROVER_EMAIL
    WHEN MATCHED THEN UPDATE SET
        ROLE_CODE = t.APPROVER_ROLE, IS_ACTIVE = TRUE,
        DISPLAY_NAME = COALESCE(t.APPROVER_NAME, u.DISPLAY_NAME),
        UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHEN NOT MATCHED THEN INSERT (USER_EMAIL, DISPLAY_NAME, ROLE_CODE, INSERT_BY, UPDATE_BY)
        VALUES (t.APPROVER_EMAIL, COALESCE(t.APPROVER_NAME, t.APPROVER_EMAIL), t.APPROVER_ROLE, :P_USER_EMAIL, :P_USER_EMAIL);

    INSERT INTO ${DB}.APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_P_APPROVAL_STEP', OBJECT_CONSTRUCT('STEP_ORDER', STEP_ORDER), 'UPDATE',
           OBJECT_CONSTRUCT('STEP_TITLE', OLD_TITLE),
           OBJECT_CONSTRUCT('STEP_TITLE', STEP_TITLE, 'APPROVER_EMAIL', APPROVER_EMAIL),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM ${DB}.APP.TMP_STEPS;

    COMMIT;
    DROP TABLE IF EXISTS ${DB}.APP.TMP_STEPS;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_rows || ' approval step(s) saved.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        DROP TABLE IF EXISTS ${DB}.APP.TMP_STEPS;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
