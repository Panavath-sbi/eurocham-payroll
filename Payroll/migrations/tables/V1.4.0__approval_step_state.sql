/* =====================================================================================
   V1.4.0 - SIMPLER APPROVAL TRACKING
   One row per approval step instead of a log of every click; one employee check per
   employee instead of one per step.
   =====================================================================================

   HISTORY
   -------
   2026-10-02  Initial version.
               * New APP.T_F_APPROVAL_STEP_STATE: the current state of each approval step
                 (one row per request and step: PENDING, APPROVED or REJECTED). Replaces
                 APP.T_F_APPROVAL_ACTION, which is dropped. Its rows are first copied to
                 APP.T_F_CHANGE_LOG, which now holds the full history of approval clicks.
               * APP.T_F_APPROVAL_EMPLOYEE_CHECK loses STEP_ORDER: one check per employee
                 per payroll month, made by the step flagged MANAGES_EMPLOYEE_CHECKS.
                 Checks made by other steps (and budget checks, never used) are removed.
               * CORE.T_P_APPROVAL_STEP gets MANAGES_EMPLOYEE_CHECKS (TRUE for step 2).
               * Table comment of APP.T_F_APPROVAL_REQUEST corrected (a payroll
                 rejection keeps the same request since V1.2.0).
   Versioned file: never edit after deployment.

   ORDER: run after V1.3.0, then re-run R__views_core.sql, R__views_rpt.sql and the
   changed procedures (they use the new table).
   ===================================================================================== */

/* -------------------------------------------------------------------------------------
   1. Which approval step checks employees one by one
   ------------------------------------------------------------------------------------- */
ALTER TABLE CORE.T_P_APPROVAL_STEP ADD COLUMN MANAGES_EMPLOYEE_CHECKS BOOLEAN DEFAULT FALSE
    COMMENT 'TRUE for the step whose approver checks or rejects each employee (actual payroll only); that step can only be approved when every employee is CHECKED. Other steps are a plain approve.';

UPDATE CORE.T_P_APPROVAL_STEP
SET MANAGES_EMPLOYEE_CHECKS = (STEP_ORDER = 2),
    UPDATE_DATE = CURRENT_TIMESTAMP;

/* -------------------------------------------------------------------------------------
   2. Current state of each approval step
   ------------------------------------------------------------------------------------- */
CREATE TABLE APP.T_F_APPROVAL_STEP_STATE (
    REQUEST_ID    INT       NOT NULL COMMENT 'Approval request (one per payroll month, or one per budget submission)',
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
    CONSTRAINT PK_T_F_APPROVAL_STEP_STATE PRIMARY KEY (REQUEST_ID, STEP_ORDER),
    CONSTRAINT FK_STEP_STATE_REQUEST FOREIGN KEY (REQUEST_ID) REFERENCES APP.T_F_APPROVAL_REQUEST (REQUEST_ID)
) COMMENT = 'Current state of each step of each approval request (one row per request and step, created when the month is opened or the budget submitted). Every change is also written to T_F_CHANGE_LOG.';

-- Fill it from the existing approvals: each step of each request, with its latest action
INSERT INTO APP.T_F_APPROVAL_STEP_STATE
    (REQUEST_ID, STEP_ORDER, STEP_STATUS, LAST_ACTION, ACTED_BY, ACTED_AT, STEP_COMMENT)
SELECT st.REQUEST_ID,
       st.STEP_ORDER,
       CASE la.ACTION_TYPE WHEN 'APPROVE' THEN 'APPROVED' WHEN 'REJECT' THEN 'REJECTED' ELSE 'PENDING' END,
       la.ACTION_TYPE,
       la.ACTED_BY,
       la.INSERT_DATE,
       la.ACTION_COMMENT
FROM (
    SELECT DISTINCT r.REQUEST_ID, s.STEP_ORDER
    FROM APP.T_F_APPROVAL_REQUEST r
    JOIN APP.T_D_SCENARIO sc ON sc.SCENARIO_ID = r.SCENARIO_ID
    JOIN CORE.T_P_APPROVAL_STEP s
      ON s.IS_ACTIVE
     AND s.APPLIES_TO IN ('ALL', sc.SCENARIO_TYPE)
     AND COALESCE(r.PERIOD_KEY, sc.FISCAL_YEAR * 100 + 1)
         BETWEEN s.VALID_FROM_PERIOD_KEY AND COALESCE(s.VALID_TO_PERIOD_KEY, 999912)
) st
LEFT JOIN (
    SELECT *
    FROM APP.T_F_APPROVAL_ACTION
    QUALIFY ROW_NUMBER() OVER (PARTITION BY REQUEST_ID, STEP_ORDER ORDER BY INSERT_DATE DESC, ACTION_ID DESC) = 1
) la ON la.REQUEST_ID = st.REQUEST_ID AND la.STEP_ORDER = st.STEP_ORDER;

-- Keep the click history: copy every old action to the change log, in the same format
-- the procedures now use (TABLE_NAME = APP.T_F_APPROVAL_STEP_STATE)
INSERT INTO APP.T_F_CHANGE_LOG
    (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY,
     INSERT_DATE, UPDATE_DATE, INSERT_BY, UPDATE_BY)
SELECT 'APP.T_F_APPROVAL_STEP_STATE',
       OBJECT_CONSTRUCT('REQUEST_ID', REQUEST_ID, 'STEP_ORDER', STEP_ORDER),
       'UPDATE',
       NULL,
       OBJECT_CONSTRUCT('ACTION_TYPE', ACTION_TYPE,
                        'STEP_STATUS', CASE ACTION_TYPE WHEN 'APPROVE' THEN 'APPROVED'
                                                        WHEN 'REJECT'  THEN 'REJECTED'
                                                        ELSE 'PENDING' END,
                        'COMMENT', ACTION_COMMENT,
                        'NOTE', 'Copied from T_F_APPROVAL_ACTION by V1.4.0'),
       ACTED_BY,
       INSERT_DATE, INSERT_DATE, INSERT_BY, CURRENT_USER
FROM APP.T_F_APPROVAL_ACTION
ORDER BY ACTION_ID;

/* -------------------------------------------------------------------------------------
   3. Employee checks: one per employee per payroll month (no step column)
   ------------------------------------------------------------------------------------- */
-- Only the checks of step 2 (the step that manages them) on actual payroll are kept
DELETE FROM APP.T_F_APPROVAL_EMPLOYEE_CHECK c
WHERE c.STEP_ORDER <> 2
   OR c.REQUEST_ID IN (SELECT r.REQUEST_ID
                       FROM APP.T_F_APPROVAL_REQUEST r
                       JOIN APP.T_D_SCENARIO sc ON sc.SCENARIO_ID = r.SCENARIO_ID
                       WHERE sc.SCENARIO_TYPE <> 'ACTUAL');

ALTER TABLE APP.T_F_APPROVAL_EMPLOYEE_CHECK DROP PRIMARY KEY;
ALTER TABLE APP.T_F_APPROVAL_EMPLOYEE_CHECK DROP COLUMN STEP_ORDER;
ALTER TABLE APP.T_F_APPROVAL_EMPLOYEE_CHECK
    ADD CONSTRAINT PK_T_F_APPROVAL_EMPLOYEE_CHECK PRIMARY KEY (REQUEST_ID, EMPLOYEE_ID);

ALTER TABLE APP.T_F_APPROVAL_EMPLOYEE_CHECK ALTER COLUMN CHECKED_BY
    COMMENT 'App user (approver of the step that manages employee checks) who checked or rejected the employee';

COMMENT ON TABLE APP.T_F_APPROVAL_EMPLOYEE_CHECK IS
    'Per-employee checks of an actual payroll month (one row per request and employee), made by the approval step flagged MANAGES_EMPLOYEE_CHECKS. That step can only be approved when every employee is CHECKED. Status history is kept in T_F_CHANGE_LOG.';

/* -------------------------------------------------------------------------------------
   4. Corrected request comment
   ------------------------------------------------------------------------------------- */
COMMENT ON TABLE APP.T_F_APPROVAL_REQUEST IS
    'One approval cycle. Actual payroll: one per month, created automatically when the month is opened; a rejection keeps the same request. Budget: one per submission; a rejection closes it and resubmitting creates a new one.';

/* -------------------------------------------------------------------------------------
   5. Remove the old action log (its history is now in T_F_CHANGE_LOG)
   CORE.V_F_APPROVAL_EVENT is recreated from the change log by R__views_core.sql.
   ------------------------------------------------------------------------------------- */
DROP VIEW IF EXISTS CORE.V_F_APPROVAL_EVENT;
DROP TABLE APP.T_F_APPROVAL_ACTION;
