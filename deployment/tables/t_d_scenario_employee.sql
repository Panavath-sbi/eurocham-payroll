-- depends_on: T_D_SCENARIO, T_D_EMPLOYEE, T_D_EMPLOYEE_CONTRACT, T_D_ENTITY, T_D_PERIOD
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.2).
-- CREATE TABLE IF NOT EXISTS: safe to run on every deployment; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS {{ schema_app }}.T_D_SCENARIO_EMPLOYEE (
    SCENARIO_ID             INT       NOT NULL COMMENT 'Budget or forecast scenario',
    EMPLOYEE_ID             INT       NOT NULL COMMENT 'Employee (actual or planned hire)',
    SOURCE_CONTRACT_ID      INT                COMMENT 'Contract version the terms were copied from; NULL for planned hires',
    POSITION                TEXT               COMMENT 'Job title in this scenario',
    EMPLOYMENT_TYPE         TEXT      NOT NULL DEFAULT 'FULL_TIME' COMMENT 'FULL_TIME, PART_TIME, INTERNSHIP',
    CONTRACT_TYPE           TEXT               COMMENT 'Contract type in this scenario',
    ENTITY_CODE             TEXT      NOT NULL COMMENT 'Entity (chamber) in this scenario',
    MONTHLY_SALARY_USD      FLOAT     NOT NULL COMMENT 'Salary before the revaluation month',
    RAISE_PCT               FLOAT     NOT NULL DEFAULT 0 COMMENT 'Raise entered for this employee in this scenario, e.g. 5 = 5%',
    REVALUATION_PERIOD_KEY  INT                COMMENT 'First month the final salary applies; NULL = no raise',
    FINAL_SALARY_USD        FLOAT     NOT NULL COMMENT 'Salary from the revaluation month onwards (equals MONTHLY_SALARY_USD when no raise)',
    TAX_STATUS              TEXT      NOT NULL DEFAULT 'RESIDENT' COMMENT 'RESIDENT or NON_RESIDENT in this scenario',
    DEPENDANT_CHILDREN      INT       NOT NULL DEFAULT 0 COMMENT 'Dependant children in this scenario',
    DEPENDANT_SPOUSE        INT       NOT NULL DEFAULT 0 COMMENT 'Dependant spouse (0 or 1) in this scenario',
    INSURANCE_USD           FLOAT     NOT NULL DEFAULT 0 COMMENT 'Monthly employer-paid insurance in this scenario',
    VISA_USD                FLOAT     NOT NULL DEFAULT 0 COMMENT 'Monthly employer-paid visa in this scenario',
    WORK_PERMIT_USD         FLOAT     NOT NULL DEFAULT 0 COMMENT 'Monthly employer-paid work permit in this scenario',
    FRINGE_BENEFIT_USD      FLOAT     NOT NULL DEFAULT 0 COMMENT 'Monthly fringe benefits in this scenario',
    INSERT_DATE             TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE             TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY               TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY               TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_SCENARIO_EMPLOYEE PRIMARY KEY (SCENARIO_ID, EMPLOYEE_ID),
    CONSTRAINT FK_SCEN_EMP_SCENARIO FOREIGN KEY (SCENARIO_ID) REFERENCES {{ schema_app }}.T_D_SCENARIO (SCENARIO_ID),
    CONSTRAINT FK_SCEN_EMP_EMPLOYEE FOREIGN KEY (EMPLOYEE_ID) REFERENCES {{ schema_app }}.T_D_EMPLOYEE (EMPLOYEE_ID),
    CONSTRAINT FK_SCEN_EMP_CONTRACT FOREIGN KEY (SOURCE_CONTRACT_ID) REFERENCES {{ schema_app }}.T_D_EMPLOYEE_CONTRACT (CONTRACT_ID),
    CONSTRAINT FK_SCEN_EMP_ENTITY FOREIGN KEY (ENTITY_CODE) REFERENCES {{ schema_app }}.T_D_ENTITY (ENTITY_CODE),
    CONSTRAINT FK_SCEN_EMP_REVAL FOREIGN KEY (REVALUATION_PERIOD_KEY) REFERENCES {{ schema_app }}.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Employee terms within a budget or forecast scenario (one row per employee per scenario). Copied from the actual contracts (or another scenario) when the scenario is created, then edited independently. Never used for actual payroll.';
