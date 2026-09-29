/* =====================================================================================
   V1.0.1 - CORE DIMENSION AND PARAMETER TABLES
   T_D_PERIOD, T_D_ENTITY, T_D_FUND, T_D_DEPARTMENT, T_D_PAY_COMPONENT, T_P_* tables.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   NOTE: Snowflake does not enforce PRIMARY / UNIQUE / FOREIGN KEY constraints and has
   no CHECK constraints; they are declared for documentation. SP_ procedures enforce rules.
   Versioned file: never edit after deployment - add a new V file with ALTER statements.
   ===================================================================================== */

/* =====================================================================================
   1. CORE - DIMENSION TABLES (T_D_)
   ===================================================================================== */

CREATE OR REPLACE TABLE CORE.T_D_PERIOD (
    PERIOD_KEY          INT       NOT NULL COMMENT 'Period identifier in YYYYMM form, e.g. 202609',
    PERIOD_START_DATE   DATE      NOT NULL COMMENT 'First day of the month',
    PERIOD_END_DATE     DATE      NOT NULL COMMENT 'Last day of the month',
    YEAR                INT       NOT NULL COMMENT 'Calendar year',
    MONTH_NUMBER        INT       NOT NULL COMMENT 'Month number 1-12',
    MONTH_NAME          TEXT      NOT NULL COMMENT 'Full month name, e.g. September',
    PERIOD_LABEL        TEXT      NOT NULL COMMENT 'Display label, e.g. Sep 2026',
    QUARTER             INT       NOT NULL COMMENT 'Calendar quarter 1-4',
    HALF_YEAR           INT       NOT NULL COMMENT '1 = Jan-Jun, 2 = Jul-Dec (seniority averaging window)',
    IS_SENIORITY_MONTH  BOOLEAN   NOT NULL COMMENT 'TRUE for June and December, when seniority indemnity is paid',
    FISCAL_YEAR         INT       NOT NULL COMMENT 'Fiscal year (currently equal to calendar year)',
    WEEKDAY_COUNT       INT       NOT NULL COMMENT 'Number of Monday-Friday days in the month (reference only)',
    WORKING_DAYS        INT                COMMENT 'Official working days for actual payroll; NULL or 0 = not yet set',
    BUDGET_WORKING_DAYS INT                COMMENT 'Working days used by budget scenarios; NULL or 0 = not yet set',
    INSERT_DATE         TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE         TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY           TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY           TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_PERIOD PRIMARY KEY (PERIOD_KEY)
) COMMENT = 'Calendar month dimension (one row per month of each year). Replaces T_P_WORKING_DAY and T_P_BUDGET_WORKING_DAY.';

CREATE OR REPLACE TABLE CORE.T_D_ENTITY (
    ENTITY_CODE   TEXT      NOT NULL COMMENT 'Entity (chamber) code, e.g. ECCC, CCIFC',
    ENTITY_NAME   TEXT      NOT NULL COMMENT 'Full entity name',
    IS_ACTIVE     BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'Whether the entity can be assigned to new contracts',
    DESCRIPTION   TEXT               COMMENT 'Free-text description',
    INSERT_DATE   TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE   TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY     TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY     TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_ENTITY PRIMARY KEY (ENTITY_CODE)
) COMMENT = 'Legal entity / chamber that employs the staff member.';

CREATE OR REPLACE TABLE CORE.T_D_FUND (
    FUND_CODE     TEXT      NOT NULL COMMENT 'Fund code, e.g. ECCC, CCIFC, EU_GATE',
    FUND_NAME     TEXT      NOT NULL COMMENT 'Fund display name',
    IS_ACTIVE     BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'Whether new allocations can use this fund',
    DESCRIPTION   TEXT               COMMENT 'Free-text description, e.g. donor or grant',
    INSERT_DATE   TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE   TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY     TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY     TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_FUND PRIMARY KEY (FUND_CODE)
) COMMENT = 'Funding source that payroll cost is charged to. New funds are added as rows.';

CREATE OR REPLACE TABLE CORE.T_D_DEPARTMENT (
    DEPARTMENT_CODE  TEXT      NOT NULL COMMENT 'Department / cost center code',
    DEPARTMENT_NAME  TEXT      NOT NULL COMMENT 'Department display name',
    IS_ACTIVE        BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'Whether new allocations can use this department',
    DISPLAY_ORDER    INT                COMMENT 'Sort order in the app and reports',
    INSERT_DATE      TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE      TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY        TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY        TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_DEPARTMENT PRIMARY KEY (DEPARTMENT_CODE)
) COMMENT = 'Department / cost center that payroll cost is allocated to. Replaces the PCT_* columns.';

CREATE OR REPLACE TABLE CORE.T_D_PAY_COMPONENT (
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

/* =====================================================================================
   2. CORE - PARAMETER TABLES (T_P_)
   ===================================================================================== */

CREATE OR REPLACE TABLE CORE.T_P_APPROVAL_STEP (
    APPROVAL_STEP_ID       INT       IDENTITY(1,1) NOT NULL COMMENT 'Surrogate key of the step version',
    STEP_ORDER             INT       NOT NULL COMMENT 'Sequence in the chain; 1 approves first',
    STEP_TITLE             TEXT      NOT NULL COMMENT 'Display name, e.g. HR Manager',
    APPROVER_ROLE          TEXT      NOT NULL COMMENT 'Role code a user needs in T_D_APP_USER_ROLE to act on this step',
    APPLIES_TO             TEXT      NOT NULL DEFAULT 'ALL' COMMENT 'ACTUAL, BUDGET, FORECAST or ALL',
    VALID_FROM_PERIOD_KEY  INT       NOT NULL COMMENT 'First period this step version applies to',
    VALID_TO_PERIOD_KEY    INT                COMMENT 'Last period this step version applies to; NULL = still in effect',
    IS_ACTIVE              BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'Soft-disable flag',
    INSERT_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_P_APPROVAL_STEP PRIMARY KEY (APPROVAL_STEP_ID),
    CONSTRAINT FK_APPROVAL_STEP_FROM FOREIGN KEY (VALID_FROM_PERIOD_KEY) REFERENCES CORE.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Effective-dated approval chain definition.';

CREATE OR REPLACE TABLE CORE.T_P_STATUTORY_PARAMETER (
    PARAM_CODE             TEXT      NOT NULL COMMENT 'Parameter code, e.g. NSSF_EE_PENSION_RATE',
    VALID_FROM_PERIOD_KEY  INT       NOT NULL COMMENT 'First period the value applies to',
    VALID_TO_PERIOD_KEY    INT                COMMENT 'Last period the value applies to; NULL = still in effect',
    PARAM_VALUE            FLOAT     NOT NULL COMMENT 'Numeric value (rates as decimals, e.g. 0.02 = 2%)',
    UNIT                   TEXT      NOT NULL COMMENT 'RATE, KHR, MULTIPLIER or DAYS',
    DESCRIPTION            TEXT               COMMENT 'What the parameter controls',
    LEGAL_REFERENCE        TEXT               COMMENT 'Prakas / regulation the value comes from',
    INSERT_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_P_STATUTORY_PARAMETER PRIMARY KEY (PARAM_CODE, VALID_FROM_PERIOD_KEY),
    CONSTRAINT FK_PARAM_FROM FOREIGN KEY (VALID_FROM_PERIOD_KEY) REFERENCES CORE.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Statutory rates, caps and constants, effective-dated. A change is a new row with a new VALID_FROM; old values stay for history. Replaces T_P_TAX_CEILING (except brackets).';

CREATE OR REPLACE TABLE CORE.T_P_TAX_BRACKET (
    VALID_FROM_PERIOD_KEY    INT       NOT NULL COMMENT 'First period the bracket set applies to',
    VALID_TO_PERIOD_KEY      INT                COMMENT 'Last period the bracket set applies to; NULL = still in effect',
    BRACKET_NUMBER           INT       NOT NULL COMMENT 'Bracket sequence 1..n',
    LOWER_BOUND_KHR          FLOAT     NOT NULL COMMENT 'Bracket applies when tax base is above this amount',
    UPPER_BOUND_KHR          FLOAT              COMMENT 'Bracket applies when tax base is at or below this amount; NULL = no upper limit',
    TAX_RATE                 FLOAT     NOT NULL COMMENT 'Marginal rate as a decimal, e.g. 0.10',
    CUMULATIVE_DEDUCTION_KHR FLOAT     NOT NULL COMMENT 'Amount subtracted: tax = base x rate - deduction',
    INSERT_DATE              TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE              TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY                TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY                TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_P_TAX_BRACKET PRIMARY KEY (VALID_FROM_PERIOD_KEY, BRACKET_NUMBER),
    CONSTRAINT FK_BRACKET_FROM FOREIGN KEY (VALID_FROM_PERIOD_KEY) REFERENCES CORE.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Resident salary tax brackets, effective-dated as a set.';

CREATE OR REPLACE TABLE CORE.T_P_FX_RATE (
    PERIOD_KEY      INT       NOT NULL COMMENT 'Period the rate is published for',
    RATE_TYPE       TEXT      NOT NULL COMMENT 'NBC (gross and tax conversion) or NSSF (NSSF base conversion)',
    FROM_CURRENCY   TEXT      NOT NULL DEFAULT 'USD' COMMENT 'Source currency',
    TO_CURRENCY     TEXT      NOT NULL DEFAULT 'KHR' COMMENT 'Target currency',
    EXCHANGE_RATE   FLOAT     NOT NULL COMMENT 'Units of TO_CURRENCY per 1 FROM_CURRENCY, e.g. 4085',
    SOURCE_NOTE     TEXT               COMMENT 'Where the rate was published',
    INSERT_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_P_FX_RATE PRIMARY KEY (PERIOD_KEY, RATE_TYPE, FROM_CURRENCY, TO_CURRENCY),
    CONSTRAINT FK_FX_PERIOD FOREIGN KEY (PERIOD_KEY) REFERENCES CORE.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Officially published exchange rates per month. The rate actually applied to a scenario period is snapshotted in T_F_SCENARIO_PERIOD.';
