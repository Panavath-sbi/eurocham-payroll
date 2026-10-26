-- depends_on: T_D_PERIOD
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created in CORE by V1.0.1, moved to APP by V1.5.0; V1.4.0 added MANAGES_EMPLOYEE_CHECKS, V1.7.0 set the APPROVER_ROLE comment).
-- 2026-10-26  Reference rows removed from this script: they are loaded and maintained in each environment, not by the deployment.
-- CREATE TABLE IF NOT EXISTS: safe to run on every deployment; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS APP.T_P_APPROVAL_STEP (
    APPROVAL_STEP_ID       INT       IDENTITY(1,1) NOT NULL COMMENT 'Surrogate key of the step version',
    STEP_ORDER             INT       NOT NULL COMMENT 'Sequence in the chain; 1 approves first',
    STEP_TITLE             TEXT      NOT NULL COMMENT 'Display name, e.g. HR Manager',
    APPROVER_ROLE          TEXT      NOT NULL COMMENT 'Level a user needs to act on this step (LEVEL_1 / LEVEL_2 / LEVEL_3 = step order); ADMIN may act on every step',
    APPLIES_TO             TEXT      NOT NULL DEFAULT 'ALL' COMMENT 'ACTUAL, BUDGET, FORECAST or ALL',
    VALID_FROM_PERIOD_KEY  INT       NOT NULL COMMENT 'First period this step version applies to',
    VALID_TO_PERIOD_KEY    INT                COMMENT 'Last period this step version applies to; NULL = still in effect',
    IS_ACTIVE              BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'Soft-disable flag',
    INSERT_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    MANAGES_EMPLOYEE_CHECKS BOOLEAN DEFAULT FALSE COMMENT 'TRUE for the step whose approver checks or rejects each employee (actual payroll only); that step can only be approved when every employee is CHECKED. Other steps are a plain approve.',
    CONSTRAINT PK_T_P_APPROVAL_STEP PRIMARY KEY (APPROVAL_STEP_ID),
    CONSTRAINT FK_APPROVAL_STEP_FROM FOREIGN KEY (VALID_FROM_PERIOD_KEY) REFERENCES APP.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Effective-dated approval chain definition.';
