-- depends_on: T_D_EMPLOYEE, T_D_ENTITY, T_D_PERIOD
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.2; V1.6.0 added NON_RESIDENT_FROM and NON_RESIDENT_TO).
-- CREATE TABLE IF NOT EXISTS: safe to run on every deployment; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS {{ schema_app }}.T_D_EMPLOYEE_CONTRACT (
    CONTRACT_ID            INT       IDENTITY(1,1) NOT NULL COMMENT 'Surrogate key of the contract version (EMPLOYEE_VERSION_KEY in facts)',
    EMPLOYEE_ID            INT       NOT NULL COMMENT 'Employee',
    VALID_FROM_PERIOD_KEY  INT       NOT NULL COMMENT 'First period these terms apply to',
    VALID_TO_PERIOD_KEY    INT                COMMENT 'Last period these terms apply to; NULL = current version',
    POSITION               TEXT               COMMENT 'Job title',
    EMPLOYMENT_TYPE        TEXT      NOT NULL DEFAULT 'FULL_TIME' COMMENT 'FULL_TIME, PART_TIME, INTERNSHIP',
    CONTRACT_TYPE          TEXT               COMMENT 'Contract type, e.g. UDC (undetermined duration) or FDC (fixed duration)',
    ENTITY_CODE            TEXT      NOT NULL COMMENT 'Employing entity (chamber)',
    MONTHLY_SALARY_USD     FLOAT     NOT NULL COMMENT 'Contracted monthly base salary in USD',
    TAX_STATUS             TEXT      NOT NULL DEFAULT 'RESIDENT' COMMENT 'RESIDENT or NON_RESIDENT for salary tax',
    DEPENDANT_CHILDREN     INT       NOT NULL DEFAULT 0 COMMENT 'Qualifying dependant children for tax relief',
    DEPENDANT_SPOUSE       INT       NOT NULL DEFAULT 0 COMMENT 'Qualifying dependant spouse (0 or 1)',
    INSURANCE_USD          FLOAT     NOT NULL DEFAULT 0 COMMENT 'Monthly employer-paid insurance (employer cost only)',
    VISA_USD               FLOAT     NOT NULL DEFAULT 0 COMMENT 'Monthly employer-paid visa (employer cost only)',
    WORK_PERMIT_USD        FLOAT     NOT NULL DEFAULT 0 COMMENT 'Monthly employer-paid work permit (employer cost only)',
    FRINGE_BENEFIT_USD     FLOAT     NOT NULL DEFAULT 0 COMMENT 'Monthly fringe benefits in USD',
    CHANGE_REASON          TEXT               COMMENT 'Why this version was created, e.g. annual raise',
    INSERT_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    NON_RESIDENT_FROM    DATE               COMMENT 'Non-residents only: first day of the non-residency (information)',
    NON_RESIDENT_TO      DATE               COMMENT 'Non-residents only: last day of the non-residency. When a payroll month opens after this date, a new contract version makes the employee RESIDENT from that month.',
    CONSTRAINT PK_T_D_EMPLOYEE_CONTRACT PRIMARY KEY (CONTRACT_ID),
    CONSTRAINT FK_CONTRACT_EMPLOYEE FOREIGN KEY (EMPLOYEE_ID) REFERENCES {{ schema_app }}.T_D_EMPLOYEE (EMPLOYEE_ID),
    CONSTRAINT FK_CONTRACT_ENTITY FOREIGN KEY (ENTITY_CODE) REFERENCES {{ schema_app }}.T_D_ENTITY (ENTITY_CODE),
    CONSTRAINT FK_CONTRACT_FROM FOREIGN KEY (VALID_FROM_PERIOD_KEY) REFERENCES {{ schema_app }}.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Effective-dated pay terms (SCD Type 2). A salary or dependant change closes the current version and adds a new one, so past payrolls keep the terms that applied at the time.';
