---version: 0, author: panavath.dinsophary
-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.2).
-- Plain CREATE TABLE on purpose: if the table already exists the deploy stops instead of
-- replacing it and losing its rows.
CREATE TABLE ${DB}.APP.T_D_EMPLOYEE (
    EMPLOYEE_ID           INT       IDENTITY(1,1) NOT NULL COMMENT 'Surrogate key (no special ID ranges)',
    RESOURCE_CODE         TEXT      NOT NULL COMMENT 'Employee code shown to users, e.g. HR-KH-006; unique',
    FIRST_NAME            TEXT               COMMENT 'First name',
    LAST_NAME             TEXT               COMMENT 'Last name',
    EMAIL                 TEXT               COMMENT 'Work email',
    PHONE                 TEXT               COMMENT 'Phone number',
    NATIONALITY           TEXT               COMMENT 'Nationality',
    EMPLOYMENT_START_DATE DATE               COMMENT 'Contract start date',
    EMPLOYMENT_END_DATE   DATE               COMMENT 'Termination date; NULL = still employed',
    IS_ACTIVE             BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'FALSE removes the employee from new payroll periods; employees are never deleted',
    BANK_NAME             TEXT               COMMENT 'Disbursing bank (sensitive)',
    BANK_ACCOUNT_NAME     TEXT               COMMENT 'Account holder name (sensitive)',
    BANK_ACCOUNT_NUMBER   TEXT               COMMENT 'Bank account number (sensitive; apply masking policy)',
    IS_PLANNED            BOOLEAN   NOT NULL DEFAULT FALSE COMMENT 'TRUE for a planned hire that exists only in a budget or forecast',
    PLANNED_SCENARIO_ID   INT                COMMENT 'Scenario a planned hire belongs to; NULL for real employees',
    INSERT_DATE           TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE           TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY             TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY             TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_EMPLOYEE PRIMARY KEY (EMPLOYEE_ID),
    CONSTRAINT UQ_T_D_EMPLOYEE_RESOURCE UNIQUE (RESOURCE_CODE),
    CONSTRAINT FK_EMPLOYEE_PLANNED_SCENARIO FOREIGN KEY (PLANNED_SCENARIO_ID) REFERENCES ${DB}.APP.T_D_SCENARIO (SCENARIO_ID)
) COMMENT = 'Employee master: identity and banking details that rarely change. Pay-related terms live in T_D_EMPLOYEE_CONTRACT.';
---rollback: DROP TABLE IF EXISTS ${DB}.APP.T_D_EMPLOYEE;
---verify: SELECT EMPLOYEE_ID, RESOURCE_CODE, FIRST_NAME FROM ${DB}.APP.T_D_EMPLOYEE LIMIT 1;
