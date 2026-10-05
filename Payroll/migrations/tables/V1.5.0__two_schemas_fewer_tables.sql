/* =====================================================================================
   V1.5.0 - TWO SCHEMAS AND FEWER TABLES
   Tables and procedures live in APP, views in RPT. CORE is removed.
   27 tables become 20.
   =====================================================================================

   HISTORY
   -------
   2026-10-02  Initial version.
               1. Every CORE table moves to APP (same name). CORE views are recreated in
                  RPT by the R__views_*.sql files. Schema CORE is dropped.
               2. Exchange rates: CORE.T_P_FX_RATE becomes FX_RATE_NBC and FX_RATE_NSSF
                  on APP.T_D_PERIOD (next to the working days).
               3. Signatures: RPT.SIGNATURES becomes SIGNATURE_IMAGE on APP.T_D_APP_USER.
               4. Roles: APP.T_D_APP_USER_ROLE becomes ROLE_CODE on APP.T_D_APP_USER
                  (one role per user).
               5. Employee checks: APP.T_F_APPROVAL_EMPLOYEE_CHECK becomes CHECK_STATUS,
                  CHECK_COMMENT and CHECKED_BY on APP.T_F_PAYROLL_INPUT.
               6. Approvals: APP.T_F_APPROVAL_REQUEST and APP.T_F_APPROVAL_STEP_STATE become
                  APP.T_F_APPROVAL, keyed by scenario, period and step (period 0 = a whole
                  budget).
               7. Payroll adjustments are removed (APP.T_F_PAYROLL_ADJUSTMENT, the
                  ADJUSTMENT pay component and SP_SAVE_PAYROLL_ADJUSTMENT).
               8. CORE.T_F_COST_ALLOCATION is dropped; RPT.V_F_COST_ALLOCATION calculates
                  the same rows from the pay lines and the allocation shares.
               9. Old procedure versions whose parameters changed are dropped.
   Versioned file: never edit after deployment.

   BEFORE RUNNING on a database with real users: one role per user from now on. Users
   with several roles keep one, in this order: PAYROLL_ADMIN, HR_MANAGER, TREASURER,
   DIRECTOR, BUDGET_EDITOR, VIEWER. List them first with:
       SELECT USER_EMAIL, LISTAGG(ROLE_CODE, ', ') FROM APP.T_D_APP_USER_ROLE
       GROUP BY USER_EMAIL HAVING COUNT(*) > 1;

   AFTER RUNNING: re-run R__views_core.sql, R__views_rpt.sql, R__views_pbi.sql and every
   R__sp_*.sql file (they use the new names).
   ===================================================================================== */

/* -------------------------------------------------------------------------------------
   1. Move the CORE tables to APP (constraints and data move with them)
   ------------------------------------------------------------------------------------- */
DROP VIEW IF EXISTS CORE.V_D_EMPLOYEE;
DROP VIEW IF EXISTS CORE.V_D_SCENARIO;
DROP VIEW IF EXISTS CORE.V_F_PAYROLL_SUMMARY;
DROP VIEW IF EXISTS CORE.V_F_APPROVAL_EVENT;

ALTER TABLE CORE.T_D_PERIOD              RENAME TO APP.T_D_PERIOD;
ALTER TABLE CORE.T_D_ENTITY              RENAME TO APP.T_D_ENTITY;
ALTER TABLE CORE.T_D_FUND                RENAME TO APP.T_D_FUND;
ALTER TABLE CORE.T_D_DEPARTMENT          RENAME TO APP.T_D_DEPARTMENT;
ALTER TABLE CORE.T_D_PAY_COMPONENT       RENAME TO APP.T_D_PAY_COMPONENT;
ALTER TABLE CORE.T_P_APPROVAL_STEP       RENAME TO APP.T_P_APPROVAL_STEP;
ALTER TABLE CORE.T_P_STATUTORY_PARAMETER RENAME TO APP.T_P_STATUTORY_PARAMETER;
ALTER TABLE CORE.T_P_TAX_BRACKET         RENAME TO APP.T_P_TAX_BRACKET;
ALTER TABLE CORE.T_F_PAYROLL_LINE        RENAME TO APP.T_F_PAYROLL_LINE;

/* -------------------------------------------------------------------------------------
   2. Exchange rates on the period table
   ------------------------------------------------------------------------------------- */
ALTER TABLE APP.T_D_PERIOD ADD COLUMN FX_RATE_NBC FLOAT
    COMMENT 'Published NBC USD-KHR rate (gross pay and tax conversion); NULL = not yet published';
ALTER TABLE APP.T_D_PERIOD ADD COLUMN FX_RATE_NSSF FLOAT
    COMMENT 'Published NSSF USD-KHR rate (NSSF base conversion); NULL = not yet published';

UPDATE APP.T_D_PERIOD p
SET FX_RATE_NBC  = f.NBC,
    FX_RATE_NSSF = f.NSSF,
    UPDATE_DATE  = CURRENT_TIMESTAMP
FROM (SELECT PERIOD_KEY,
             MAX(IFF(RATE_TYPE = 'NBC',  EXCHANGE_RATE, NULL)) AS NBC,
             MAX(IFF(RATE_TYPE = 'NSSF', EXCHANGE_RATE, NULL)) AS NSSF
      FROM CORE.T_P_FX_RATE
      WHERE FROM_CURRENCY = 'USD' AND TO_CURRENCY = 'KHR'
      GROUP BY PERIOD_KEY) f
WHERE p.PERIOD_KEY = f.PERIOD_KEY;

DROP TABLE CORE.T_P_FX_RATE;

COMMENT ON TABLE APP.T_D_PERIOD IS
    'Calendar month dimension (one row per month): calendar attributes, working days (actual and budget) and the published NBC / NSSF exchange rates. The values actually applied to a scenario month are copied into T_F_SCENARIO_PERIOD.';

/* -------------------------------------------------------------------------------------
   3 + 4. App users: one role per user, and the signature image
   ------------------------------------------------------------------------------------- */
ALTER TABLE APP.T_D_APP_USER ADD COLUMN ROLE_CODE TEXT DEFAULT 'VIEWER'
    COMMENT 'The user''s role: PAYROLL_ADMIN, BUDGET_EDITOR, VIEWER, or an approver role such as HR_MANAGER (one role per user)';
ALTER TABLE APP.T_D_APP_USER ADD COLUMN SIGNATURE_IMAGE TEXT
    COMMENT 'E-signature image as Base64 (PNG), used by the Power BI report; NULL = no signature';

UPDATE APP.T_D_APP_USER u
SET ROLE_CODE   = r.ROLE_CODE,
    UPDATE_DATE = CURRENT_TIMESTAMP
FROM (SELECT USER_EMAIL, ROLE_CODE
      FROM APP.T_D_APP_USER_ROLE
      QUALIFY ROW_NUMBER() OVER (
          PARTITION BY USER_EMAIL
          ORDER BY CASE ROLE_CODE WHEN 'PAYROLL_ADMIN' THEN 1 WHEN 'HR_MANAGER' THEN 2
                                  WHEN 'TREASURER' THEN 3 WHEN 'DIRECTOR' THEN 4
                                  WHEN 'BUDGET_EDITOR' THEN 5 ELSE 6 END, ROLE_CODE) = 1) r
WHERE u.USER_EMAIL = r.USER_EMAIL;

UPDATE APP.T_D_APP_USER SET ROLE_CODE = 'VIEWER' WHERE ROLE_CODE IS NULL;

-- Signatures of people who are not app users yet: the user is created (role VIEWER) so
-- that the signature is kept; give them their real role later
INSERT INTO APP.T_D_APP_USER (USER_EMAIL, DISPLAY_NAME, IS_ACTIVE, ROLE_CODE)
SELECT DISTINCT LOWER(s.APPROVER_EMAIL), LOWER(s.APPROVER_EMAIL), TRUE, 'VIEWER'
FROM RPT.SIGNATURES s
WHERE NOT EXISTS (SELECT 1 FROM APP.T_D_APP_USER u WHERE u.USER_EMAIL = LOWER(s.APPROVER_EMAIL));

UPDATE APP.T_D_APP_USER u
SET SIGNATURE_IMAGE = s.IMAGE_BASE64,
    UPDATE_DATE     = CURRENT_TIMESTAMP
FROM (SELECT LOWER(APPROVER_EMAIL) AS EMAIL, MAX(IMAGE_BASE64) AS IMAGE_BASE64
      FROM RPT.SIGNATURES GROUP BY LOWER(APPROVER_EMAIL)) s
WHERE u.USER_EMAIL = s.EMAIL;

DROP TABLE APP.T_D_APP_USER_ROLE;
DROP TABLE RPT.SIGNATURES;

COMMENT ON TABLE APP.T_D_APP_USER IS
    'Users of the payroll app, with their one role (checked by the procedures) and their e-signature.';

ALTER TABLE APP.T_P_APPROVAL_STEP ALTER COLUMN APPROVER_ROLE
    COMMENT 'Role code (T_D_APP_USER.ROLE_CODE) a user needs to act on this step';

/* -------------------------------------------------------------------------------------
   5. Employee checks on the monthly input row
   ------------------------------------------------------------------------------------- */
ALTER TABLE APP.T_F_PAYROLL_INPUT ADD COLUMN CHECK_STATUS TEXT DEFAULT 'PENDING'
    COMMENT 'Actual payroll only: PENDING, CHECKED or REJECTED by the approval step that checks employees (step 2). Back to PENDING when the employee''s numbers change.';
ALTER TABLE APP.T_F_PAYROLL_INPUT ADD COLUMN CHECK_COMMENT TEXT
    COMMENT 'Actual payroll only: reason the employee was rejected, or another note from the checker';
ALTER TABLE APP.T_F_PAYROLL_INPUT ADD COLUMN CHECKED_BY TEXT
    COMMENT 'Actual payroll only: app user who checked or rejected the employee; NULL while PENDING';

UPDATE APP.T_F_PAYROLL_INPUT SET CHECK_STATUS = 'PENDING' WHERE CHECK_STATUS IS NULL;

UPDATE APP.T_F_PAYROLL_INPUT i
SET CHECK_STATUS  = c.CHECK_STATUS,
    CHECK_COMMENT = c.CHECK_COMMENT,
    CHECKED_BY    = c.CHECKED_BY
FROM (SELECT r.SCENARIO_ID, r.PERIOD_KEY, ec.EMPLOYEE_ID, ec.CHECK_STATUS, ec.CHECK_COMMENT, ec.CHECKED_BY
      FROM APP.T_F_APPROVAL_EMPLOYEE_CHECK ec
      JOIN APP.T_F_APPROVAL_REQUEST r ON r.REQUEST_ID = ec.REQUEST_ID
      WHERE r.PERIOD_KEY IS NOT NULL
      QUALIFY ROW_NUMBER() OVER (PARTITION BY r.SCENARIO_ID, r.PERIOD_KEY, ec.EMPLOYEE_ID
                                 ORDER BY r.REQUEST_ID DESC) = 1) c
WHERE i.SCENARIO_ID = c.SCENARIO_ID AND i.PERIOD_KEY = c.PERIOD_KEY AND i.EMPLOYEE_ID = c.EMPLOYEE_ID;

DROP TABLE APP.T_F_APPROVAL_EMPLOYEE_CHECK;

COMMENT ON TABLE APP.T_F_PAYROLL_INPUT IS
    'Monthly variable inputs per employee, plus (actual payroll) the employee check made during approval. For forecasts, rows act as user overrides on top of the projection.';

/* -------------------------------------------------------------------------------------
   6. Approvals: one table, keyed by scenario, period and step
   ------------------------------------------------------------------------------------- */
CREATE TABLE APP.T_F_APPROVAL (
    SCENARIO_ID   INT       NOT NULL COMMENT 'Scenario being approved (the actual payroll, or a budget)',
    PERIOD_KEY    INT       NOT NULL COMMENT 'Payroll month being approved (YYYYMM); 0 = a whole budget scenario',
    STEP_ORDER    INT       NOT NULL COMMENT 'Approval step, 1 = first',
    STEP_STATUS   TEXT      NOT NULL DEFAULT 'PENDING' COMMENT 'PENDING, APPROVED or REJECTED',
    LAST_ACTION   TEXT               COMMENT 'What last changed the step: APPROVE, REJECT, SEND_BACK (the next step rejected), UNDO or RESET (numbers changed after approval); NULL = not acted on yet',
    ACTED_BY      TEXT               COMMENT 'App user who last acted on the step (SYSTEM for a reset)',
    ACTED_AT      TIMESTAMP          COMMENT 'When the step was last acted on',
    STEP_COMMENT  TEXT               COMMENT 'Comment of the last action: approval note, rejection reason or send-back reason',
    INSERT_DATE   TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE   TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY     TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY     TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_F_APPROVAL PRIMARY KEY (SCENARIO_ID, PERIOD_KEY, STEP_ORDER),
    CONSTRAINT FK_APPROVAL_SCENARIO FOREIGN KEY (SCENARIO_ID) REFERENCES APP.T_D_SCENARIO (SCENARIO_ID)
) COMMENT = 'Current state of each approval step: one row per step for each payroll month (created when the month is opened) and for each submitted budget (period 0, created on submission). Every change is also written to T_F_CHANGE_LOG.';

-- Keep the current state (latest request of each scenario and month)
INSERT INTO APP.T_F_APPROVAL
    (SCENARIO_ID, PERIOD_KEY, STEP_ORDER, STEP_STATUS, LAST_ACTION, ACTED_BY, ACTED_AT, STEP_COMMENT,
     INSERT_DATE, UPDATE_DATE, INSERT_BY, UPDATE_BY)
SELECT r.SCENARIO_ID, COALESCE(r.PERIOD_KEY, 0), s.STEP_ORDER, s.STEP_STATUS, s.LAST_ACTION, s.ACTED_BY,
       s.ACTED_AT, s.STEP_COMMENT, s.INSERT_DATE, s.UPDATE_DATE, s.INSERT_BY, s.UPDATE_BY
FROM APP.T_F_APPROVAL_STEP_STATE s
JOIN (SELECT REQUEST_ID, SCENARIO_ID, PERIOD_KEY
      FROM APP.T_F_APPROVAL_REQUEST
      QUALIFY ROW_NUMBER() OVER (PARTITION BY SCENARIO_ID, COALESCE(PERIOD_KEY, 0) ORDER BY REQUEST_ID DESC) = 1) r
  ON r.REQUEST_ID = s.REQUEST_ID;

DROP TABLE APP.T_F_APPROVAL_STEP_STATE;
DROP TABLE APP.T_F_APPROVAL_REQUEST;

/* -------------------------------------------------------------------------------------
   7. Payroll adjustments removed
   ------------------------------------------------------------------------------------- */
DROP TABLE APP.T_F_PAYROLL_ADJUSTMENT;

-- The ADJUSTMENT pay component goes, unless old pay lines still use it (then it is
-- only switched off, so those months keep their meaning)
DELETE FROM APP.T_D_PAY_COMPONENT
WHERE PAY_COMPONENT_CODE = 'ADJUSTMENT'
  AND NOT EXISTS (SELECT 1 FROM APP.T_F_PAYROLL_LINE l WHERE l.PAY_COMPONENT_CODE = 'ADJUSTMENT');
UPDATE APP.T_D_PAY_COMPONENT
SET IS_ACTIVE = FALSE, IS_USER_ENTERED = FALSE, UPDATE_DATE = CURRENT_TIMESTAMP
WHERE PAY_COMPONENT_CODE = 'ADJUSTMENT';

/* -------------------------------------------------------------------------------------
   8. Cost allocation becomes a view (RPT.V_F_COST_ALLOCATION)
   ------------------------------------------------------------------------------------- */
DROP TABLE CORE.T_F_COST_ALLOCATION;

/* -------------------------------------------------------------------------------------
   9. Procedures whose parameters changed: drop the old versions (Snowflake would keep
      them next to the new ones). The R__sp_*.sql files create the new versions.
   ------------------------------------------------------------------------------------- */
DROP PROCEDURE IF EXISTS APP.SP_APPROVE_STEP(TEXT, INT, INT, TEXT);
DROP PROCEDURE IF EXISTS APP.SP_REJECT_STEP(TEXT, INT, INT, TEXT);
DROP PROCEDURE IF EXISTS APP.SP_UNDO_APPROVAL(TEXT, INT, INT);
DROP PROCEDURE IF EXISTS APP.SP_SET_EMPLOYEE_CHECK(TEXT, INT, INT, TEXT, TEXT, TEXT);
DROP PROCEDURE IF EXISTS APP.SP_SAVE_PAYROLL_ADJUSTMENT(TEXT, INT, INT, INT, FLOAT, INT, TEXT);

/* -------------------------------------------------------------------------------------
   10. CORE is now empty
   ------------------------------------------------------------------------------------- */
DROP SCHEMA CORE;

ALTER SCHEMA APP SET COMMENT = 'Every table and stored procedure of the payroll model. Power Apps writes only through the SP_ procedures.';
ALTER SCHEMA RPT SET COMMENT = 'Every view (nothing stored). Power Apps flows and Power BI read only from here.';
