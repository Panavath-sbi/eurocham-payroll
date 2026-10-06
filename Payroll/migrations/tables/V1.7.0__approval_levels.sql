/* =====================================================================================
   V1.7.0 - APPROVAL LEVELS (FOUR ROLES)
   =====================================================================================

   HISTORY
   -------
   2026-10-06  Initial version. Roles are reduced to four:
                 ADMIN    every function and every approval step (developers / testing;
                          set in Snowflake only, never from the app)
                 LEVEL_1  every function; approves step 1
                 LEVEL_2  every function; approves step 2 (incl. the employee checks)
                 LEVEL_3  every function; approves step 3
               Only approvals are limited by role. Several people can hold the same level.
               PAYROLL_ADMIN, BUDGET_EDITOR, VIEWER, HR_MANAGER, TREASURER and DIRECTOR
               are removed. Step titles (e.g. "HR Manager") are labels and do not change.
   Versioned file: never edit after deployment.
   ===================================================================================== */

/* -------------------------------------------------------------------------------------
   1. Users: a user who held the role of an approval step gets that step's level;
      everyone else (PAYROLL_ADMIN, BUDGET_EDITOR, VIEWER) becomes ADMIN.
      Runs before step 2 below, which still reads the old step roles.
   ------------------------------------------------------------------------------------- */
UPDATE APP.T_D_APP_USER u
SET ROLE_CODE   = COALESCE(m.NEW_ROLE, 'ADMIN'),
    UPDATE_DATE = CURRENT_TIMESTAMP,
    UPDATE_BY   = 'V1.7.0'
FROM (SELECT x.USER_EMAIL, MAX(s.NEW_ROLE) AS NEW_ROLE
      FROM APP.T_D_APP_USER x
      LEFT JOIN (SELECT DISTINCT APPROVER_ROLE, 'LEVEL_' || STEP_ORDER AS NEW_ROLE
                 FROM APP.T_P_APPROVAL_STEP) s
             ON s.APPROVER_ROLE = x.ROLE_CODE
      GROUP BY x.USER_EMAIL) m
WHERE u.USER_EMAIL = m.USER_EMAIL;

/* -------------------------------------------------------------------------------------
   2. Approval steps: the role of step N is LEVEL_N (every version of the step)
   ------------------------------------------------------------------------------------- */
UPDATE APP.T_P_APPROVAL_STEP
SET APPROVER_ROLE = 'LEVEL_' || STEP_ORDER,
    UPDATE_DATE   = CURRENT_TIMESTAMP,
    UPDATE_BY     = 'V1.7.0';

/* -------------------------------------------------------------------------------------
   3. Column definitions. The old default ('VIEWER') no longer exists; every insert
      names the role (SP_SAVE_APPROVAL_STEPS, the dummy data), so the default is removed.
   ------------------------------------------------------------------------------------- */
ALTER TABLE APP.T_D_APP_USER ALTER COLUMN ROLE_CODE DROP DEFAULT;
ALTER TABLE APP.T_D_APP_USER ALTER COLUMN ROLE_CODE
    COMMENT 'The user''s one role: ADMIN (every approval step; set in Snowflake only), LEVEL_1, LEVEL_2 or LEVEL_3 (approves that step). Every active user may use every other function.';
ALTER TABLE APP.T_P_APPROVAL_STEP ALTER COLUMN APPROVER_ROLE
    COMMENT 'Level a user needs to act on this step (LEVEL_1 / LEVEL_2 / LEVEL_3 = step order); ADMIN may act on every step';