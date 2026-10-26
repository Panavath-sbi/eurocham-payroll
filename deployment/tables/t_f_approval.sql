-- depends_on: T_D_SCENARIO
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.5.0 in APP).
-- CREATE TABLE IF NOT EXISTS: safe to run on every deployment; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS APP.T_F_APPROVAL (
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
