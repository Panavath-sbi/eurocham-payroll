USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.1; moved to APP by V1.5.0).
-- 2026-10-26  Reference rows removed from this script: they are loaded and maintained in each environment, not by the deployment.
-- CREATE TABLE IF NOT EXISTS: safe to run on every deployment; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS APP.T_D_PAY_COMPONENT (
    PAY_COMPONENT_CODE  TEXT      NOT NULL COMMENT 'Pay component code, e.g. BASE_SALARY, SALARY_TAX',
    PAY_COMPONENT_NAME  TEXT      NOT NULL COMMENT 'Display name',
    CATEGORY            TEXT      NOT NULL COMMENT 'EARNING, EMPLOYEE_DEDUCTION, EMPLOYER_CONTRIBUTION, EMPLOYER_COST or INFORMATION',
    IS_TAXABLE          BOOLEAN   NOT NULL DEFAULT FALSE COMMENT 'Included in the salary tax base',
    IS_NSSF_BASE        BOOLEAN   NOT NULL DEFAULT FALSE COMMENT 'Included in the NSSF contribution base',
    IS_USER_ENTERED     BOOLEAN   NOT NULL DEFAULT FALSE COMMENT 'Can be entered manually as an adjustment',
    DISPLAY_ORDER       INT                COMMENT 'Sort order on payslips and reports',
    IS_ACTIVE           BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'Whether the component is currently used',
    DESCRIPTION         TEXT               COMMENT 'How the component is calculated or used',
    INSERT_DATE         TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE         TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY           TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY           TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_PAY_COMPONENT PRIMARY KEY (PAY_COMPONENT_CODE)
) COMMENT = 'Pay elements (earnings, deductions, employer costs). Each becomes a row in T_F_PAYROLL_LINE. INFORMATION rows (e.g. tax base) are stored for audit and never summed into pay.';
