/* =====================================================================================
   V1.0.2 - APP OPERATIONAL TABLES
   Employees, contracts, users, scenarios, inputs, allocations, adjustments, approvals, change log.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   NOTE: Snowflake does not enforce PRIMARY / UNIQUE / FOREIGN KEY constraints and has
   no CHECK constraints; they are declared for documentation. SP_ procedures enforce rules.
   Versioned file: never edit after deployment - add a new V file with ALTER statements.
   ===================================================================================== */

/* =====================================================================================
   3. APP - OPERATIONAL TABLES (edited by Power Apps through SP_ procedures)
   ===================================================================================== */

CREATE OR REPLACE TABLE APP.T_D_APP_USER (
    USER_EMAIL     TEXT      NOT NULL COMMENT 'Login email of the app user',
    DISPLAY_NAME   TEXT      NOT NULL COMMENT 'Name shown on approvals and audit screens',
    IS_ACTIVE      BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'Inactive users cannot act in the app',
    INSERT_DATE    TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE    TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY      TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY      TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_APP_USER PRIMARY KEY (USER_EMAIL)
) COMMENT = 'Users of the payroll app.';

CREATE OR REPLACE TABLE APP.T_D_APP_USER_ROLE (
    USER_EMAIL   TEXT      NOT NULL COMMENT 'App user',
    ROLE_CODE    TEXT      NOT NULL COMMENT 'PAYROLL_ADMIN, BUDGET_EDITOR, VIEWER, or an approver role such as HR_MANAGER',
    INSERT_DATE  TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp (when the role was granted)',
    UPDATE_DATE  TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY    TEXT      DEFAULT CURRENT_USER      COMMENT 'User who granted the role',
    UPDATE_BY    TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_APP_USER_ROLE PRIMARY KEY (USER_EMAIL, ROLE_CODE),
    CONSTRAINT FK_USER_ROLE_USER FOREIGN KEY (USER_EMAIL) REFERENCES APP.T_D_APP_USER (USER_EMAIL)
) COMMENT = 'Roles held by each user. Procedures check this table before saving, approving or finalizing.';

CREATE OR REPLACE TABLE APP.T_D_SCENARIO (
    SCENARIO_ID                INT       IDENTITY(1,1) NOT NULL COMMENT 'Surrogate key',
    SCENARIO_TYPE              TEXT      NOT NULL COMMENT 'ACTUAL (exactly one row), BUDGET or FORECAST',
    SCENARIO_NAME              TEXT      NOT NULL COMMENT 'Display name, e.g. Budget 2027 Base',
    FISCAL_YEAR                INT                COMMENT 'Year covered by a budget or forecast; NULL for ACTUAL',
    SCENARIO_STATUS            TEXT      NOT NULL DEFAULT 'DRAFT' COMMENT 'ACTIVE (actual), DRAFT, IN_APPROVAL, APPROVED, REJECTED, ARCHIVED',
    IS_OFFICIAL                BOOLEAN   NOT NULL DEFAULT FALSE COMMENT 'TRUE for the one official approved budget per fiscal year',
    BASE_SCENARIO_ID           INT                COMMENT 'Scenario this one was copied from',
    FORECAST_AS_OF_PERIOD_KEY  INT                COMMENT 'Forecast only: last actual period included; later periods are projected',
    DESCRIPTION                TEXT               COMMENT 'Assumptions behind the scenario',
    INSERT_DATE                TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE                TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY                  TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY                  TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_SCENARIO PRIMARY KEY (SCENARIO_ID),
    CONSTRAINT FK_SCENARIO_BASE FOREIGN KEY (BASE_SCENARIO_ID) REFERENCES APP.T_D_SCENARIO (SCENARIO_ID),
    CONSTRAINT FK_SCENARIO_ASOF FOREIGN KEY (FORECAST_AS_OF_PERIOD_KEY) REFERENCES CORE.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Scenario dimension: actual payroll, budget scenarios and forecast versions.';

CREATE OR REPLACE TABLE APP.T_F_SCENARIO_PERIOD (
    SCENARIO_ID     INT       NOT NULL COMMENT 'Scenario',
    PERIOD_KEY      INT       NOT NULL COMMENT 'Period',
    PERIOD_STATUS   TEXT      NOT NULL DEFAULT 'OPEN' COMMENT 'OPEN, IN_APPROVAL, FINALIZED (actual); DRAFT, LOCKED (budget/forecast)',
    WORKING_DAYS    INT       NOT NULL COMMENT 'Working days applied, copied from T_D_PERIOD when the period is created',
    FX_RATE_NBC     FLOAT     NOT NULL COMMENT 'NBC rate applied (actual: copied from T_P_FX_RATE; budget: assumption)',
    FX_RATE_NSSF    FLOAT     NOT NULL COMMENT 'NSSF rate applied (actual: copied from T_P_FX_RATE; budget: assumption)',
    FINALIZED_AT    TIMESTAMP          COMMENT 'When the period was finalized and locked',
    FINALIZED_BY    TEXT               COMMENT 'User who finalized the period',
    INSERT_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp (when the period was opened)',
    UPDATE_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'User who opened the period',
    UPDATE_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_F_SCENARIO_PERIOD PRIMARY KEY (SCENARIO_ID, PERIOD_KEY),
    CONSTRAINT FK_SP_SCENARIO FOREIGN KEY (SCENARIO_ID) REFERENCES APP.T_D_SCENARIO (SCENARIO_ID),
    CONSTRAINT FK_SP_PERIOD FOREIGN KEY (PERIOD_KEY) REFERENCES CORE.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Status and locked assumptions (working days, FX) of each period within a scenario. For actuals, only one period may be OPEN or IN_APPROVAL at a time.';

CREATE OR REPLACE TABLE APP.T_D_EMPLOYEE (
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
    CONSTRAINT FK_EMPLOYEE_PLANNED_SCENARIO FOREIGN KEY (PLANNED_SCENARIO_ID) REFERENCES APP.T_D_SCENARIO (SCENARIO_ID)
) COMMENT = 'Employee master: identity and banking details that rarely change. Pay-related terms live in T_D_EMPLOYEE_CONTRACT.';

CREATE OR REPLACE TABLE APP.T_D_EMPLOYEE_CONTRACT (
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
    CONSTRAINT PK_T_D_EMPLOYEE_CONTRACT PRIMARY KEY (CONTRACT_ID),
    CONSTRAINT FK_CONTRACT_EMPLOYEE FOREIGN KEY (EMPLOYEE_ID) REFERENCES APP.T_D_EMPLOYEE (EMPLOYEE_ID),
    CONSTRAINT FK_CONTRACT_ENTITY FOREIGN KEY (ENTITY_CODE) REFERENCES CORE.T_D_ENTITY (ENTITY_CODE),
    CONSTRAINT FK_CONTRACT_FROM FOREIGN KEY (VALID_FROM_PERIOD_KEY) REFERENCES CORE.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Effective-dated pay terms (SCD Type 2). A salary or dependant change closes the current version and adds a new one, so past payrolls keep the terms that applied at the time.';

CREATE OR REPLACE TABLE APP.T_F_PAYROLL_INPUT (
    SCENARIO_ID          INT       NOT NULL COMMENT 'Scenario (actual, budget or forecast)',
    PERIOD_KEY           INT       NOT NULL COMMENT 'Period',
    EMPLOYEE_ID          INT       NOT NULL COMMENT 'Employee',
    INCLUDE_IN_PAYROLL   BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'FALSE excludes the employee from this period',
    ABSENCE_DAYS         FLOAT     NOT NULL DEFAULT 0 COMMENT 'Unpaid absence days',
    OVERTIME_DAYS        FLOAT     NOT NULL DEFAULT 0 COMMENT 'Overtime expressed in days',
    OUTSTANDING_DAYS     FLOAT     NOT NULL DEFAULT 0 COMMENT 'Unused paid leave days paid out at the daily rate',
    BONUS_USD            FLOAT     NOT NULL DEFAULT 0 COMMENT 'Bonus paid in this period (USD)',
    SALARY_OVERRIDE_USD  FLOAT              COMMENT 'Budget/forecast only: replaces the scenario salary for this one month; NULL = use scenario terms',
    FRINGE_BENEFIT_OVERRIDE_USD FLOAT       COMMENT 'Budget/forecast only: replaces the scenario fringe benefit for this one month; NULL = use scenario terms',
    NOTES                TEXT               COMMENT 'Free-text note for reviewers',
    INSERT_DATE          TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE          TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY            TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY            TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_F_PAYROLL_INPUT PRIMARY KEY (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID),
    CONSTRAINT FK_INPUT_SP FOREIGN KEY (SCENARIO_ID, PERIOD_KEY) REFERENCES APP.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY),
    CONSTRAINT FK_INPUT_EMPLOYEE FOREIGN KEY (EMPLOYEE_ID) REFERENCES APP.T_D_EMPLOYEE (EMPLOYEE_ID)
) COMMENT = 'Monthly variable inputs per employee. For forecasts, rows act as user overrides on top of the projection.';

CREATE OR REPLACE TABLE APP.T_F_FUND_ALLOCATION (
    SCENARIO_ID   INT       NOT NULL COMMENT 'Scenario',
    PERIOD_KEY    INT       NOT NULL COMMENT 'Period',
    EMPLOYEE_ID   INT       NOT NULL COMMENT 'Employee',
    FUND_CODE     TEXT      NOT NULL COMMENT 'Fund charged',
    SHARE_PCT     FLOAT     NOT NULL COMMENT 'Share of cost charged to the fund (0-100); shares per employee must total 100',
    INSERT_DATE   TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE   TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY     TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY     TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_F_FUND_ALLOCATION PRIMARY KEY (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, FUND_CODE),
    CONSTRAINT FK_FUND_ALLOC_SP FOREIGN KEY (SCENARIO_ID, PERIOD_KEY) REFERENCES APP.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY),
    CONSTRAINT FK_FUND_ALLOC_EMP FOREIGN KEY (EMPLOYEE_ID) REFERENCES APP.T_D_EMPLOYEE (EMPLOYEE_ID),
    CONSTRAINT FK_FUND_ALLOC_FUND FOREIGN KEY (FUND_CODE) REFERENCES CORE.T_D_FUND (FUND_CODE)
) COMMENT = 'Fund split per employee and period, as percentages. Replaces ECCC_FUND / CCIFC_FUND / EU_GATE_FUND day columns (days / working days x 100).';

CREATE OR REPLACE TABLE APP.T_F_DEPARTMENT_ALLOCATION (
    SCENARIO_ID      INT       NOT NULL COMMENT 'Scenario',
    PERIOD_KEY       INT       NOT NULL COMMENT 'Period',
    EMPLOYEE_ID      INT       NOT NULL COMMENT 'Employee',
    DEPARTMENT_CODE  TEXT      NOT NULL COMMENT 'Department charged',
    SHARE_PCT        FLOAT     NOT NULL COMMENT 'Share of cost charged to the department (0-100); shares per employee must total 100',
    INSERT_DATE      TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE      TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY        TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY        TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_F_DEPARTMENT_ALLOCATION PRIMARY KEY (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, DEPARTMENT_CODE),
    CONSTRAINT FK_DEPT_ALLOC_SP FOREIGN KEY (SCENARIO_ID, PERIOD_KEY) REFERENCES APP.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY),
    CONSTRAINT FK_DEPT_ALLOC_EMP FOREIGN KEY (EMPLOYEE_ID) REFERENCES APP.T_D_EMPLOYEE (EMPLOYEE_ID),
    CONSTRAINT FK_DEPT_ALLOC_DEPT FOREIGN KEY (DEPARTMENT_CODE) REFERENCES CORE.T_D_DEPARTMENT (DEPARTMENT_CODE)
) COMMENT = 'Department split per employee and period, as percentages. Replaces the PCT_* columns.';

CREATE OR REPLACE TABLE APP.T_F_PAYROLL_ADJUSTMENT (
    ADJUSTMENT_ID         INT       IDENTITY(1,1) NOT NULL COMMENT 'Surrogate key',
    SCENARIO_ID           INT       NOT NULL COMMENT 'Scenario (normally ACTUAL)',
    PERIOD_KEY            INT       NOT NULL COMMENT 'Open period the adjustment is paid in',
    EMPLOYEE_ID           INT       NOT NULL COMMENT 'Employee',
    PAY_COMPONENT_CODE    TEXT      NOT NULL COMMENT 'Component adjusted, e.g. ADJUSTMENT or BASE_SALARY',
    AMOUNT_USD            FLOAT     NOT NULL COMMENT 'Signed amount: positive pays more, negative recovers',
    REFERENCE_PERIOD_KEY  INT                COMMENT 'Closed period being corrected, if any',
    REASON                TEXT      NOT NULL COMMENT 'Why the adjustment is needed',
    INSERT_DATE           TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE           TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY             TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY             TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_F_PAYROLL_ADJUSTMENT PRIMARY KEY (ADJUSTMENT_ID),
    CONSTRAINT FK_ADJ_SP FOREIGN KEY (SCENARIO_ID, PERIOD_KEY) REFERENCES APP.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY),
    CONSTRAINT FK_ADJ_EMP FOREIGN KEY (EMPLOYEE_ID) REFERENCES APP.T_D_EMPLOYEE (EMPLOYEE_ID),
    CONSTRAINT FK_ADJ_COMPONENT FOREIGN KEY (PAY_COMPONENT_CODE) REFERENCES CORE.T_D_PAY_COMPONENT (PAY_COMPONENT_CODE),
    CONSTRAINT FK_ADJ_REF_PERIOD FOREIGN KEY (REFERENCE_PERIOD_KEY) REFERENCES CORE.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'One-off corrections paid in the open period. Closed periods are never edited; errors are corrected here.';

CREATE OR REPLACE TABLE APP.T_D_SCENARIO_EMPLOYEE (
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
    CONSTRAINT FK_SCEN_EMP_SCENARIO FOREIGN KEY (SCENARIO_ID) REFERENCES APP.T_D_SCENARIO (SCENARIO_ID),
    CONSTRAINT FK_SCEN_EMP_EMPLOYEE FOREIGN KEY (EMPLOYEE_ID) REFERENCES APP.T_D_EMPLOYEE (EMPLOYEE_ID),
    CONSTRAINT FK_SCEN_EMP_CONTRACT FOREIGN KEY (SOURCE_CONTRACT_ID) REFERENCES APP.T_D_EMPLOYEE_CONTRACT (CONTRACT_ID),
    CONSTRAINT FK_SCEN_EMP_ENTITY FOREIGN KEY (ENTITY_CODE) REFERENCES CORE.T_D_ENTITY (ENTITY_CODE),
    CONSTRAINT FK_SCEN_EMP_REVAL FOREIGN KEY (REVALUATION_PERIOD_KEY) REFERENCES CORE.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Employee terms within a budget or forecast scenario (one row per employee per scenario). Copied from the actual contracts (or another scenario) when the scenario is created, then edited independently. Never used for actual payroll.';

CREATE OR REPLACE TABLE APP.T_F_APPROVAL_REQUEST (
    REQUEST_ID      INT       IDENTITY(1,1) NOT NULL COMMENT 'Surrogate key',
    SCENARIO_ID     INT       NOT NULL COMMENT 'Scenario being approved',
    PERIOD_KEY      INT                COMMENT 'Period being approved (actual payroll); NULL for a whole budget scenario',
    REQUEST_STATUS  TEXT      NOT NULL DEFAULT 'IN_PROGRESS' COMMENT 'IN_PROGRESS, APPROVED, REJECTED, CANCELLED',
    COMPLETED_AT    TIMESTAMP          COMMENT 'When the request was fully approved, rejected or cancelled',
    INSERT_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp (when approval was requested)',
    UPDATE_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'User who submitted the request',
    UPDATE_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_F_APPROVAL_REQUEST PRIMARY KEY (REQUEST_ID),
    CONSTRAINT FK_REQUEST_SCENARIO FOREIGN KEY (SCENARIO_ID) REFERENCES APP.T_D_SCENARIO (SCENARIO_ID),
    CONSTRAINT FK_REQUEST_PERIOD FOREIGN KEY (PERIOD_KEY) REFERENCES CORE.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'One approval cycle for a payroll period or a budget scenario. A rejection ends the request; resubmitting creates a new one.';

CREATE OR REPLACE TABLE APP.T_F_APPROVAL_ACTION (
    ACTION_ID       INT       IDENTITY(1,1) NOT NULL COMMENT 'Surrogate key',
    REQUEST_ID      INT       NOT NULL COMMENT 'Approval request',
    STEP_ORDER      INT       NOT NULL COMMENT 'Step acted on',
    ACTION_TYPE     TEXT      NOT NULL COMMENT 'APPROVE, REJECT, UNDO, or RESET (written by the system when data changes)',
    ACTED_BY        TEXT      NOT NULL COMMENT 'App user who acted, or SYSTEM',
    ACTION_COMMENT  TEXT               COMMENT 'Reason for rejection or other notes',
    INSERT_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp (when the action happened)',
    UPDATE_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp (rows are never updated)',
    INSERT_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'Snowflake user who wrote the row',
    UPDATE_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'Snowflake user who last updated the row',
    CONSTRAINT PK_T_F_APPROVAL_ACTION PRIMARY KEY (ACTION_ID),
    CONSTRAINT FK_ACTION_REQUEST FOREIGN KEY (REQUEST_ID) REFERENCES APP.T_F_APPROVAL_REQUEST (REQUEST_ID)
) COMMENT = 'Append-only log of every approval action. The current state of each step is its latest action.';

CREATE OR REPLACE TABLE APP.T_F_APPROVAL_EMPLOYEE_CHECK (
    REQUEST_ID      INT       NOT NULL COMMENT 'Approval request',
    STEP_ORDER      INT       NOT NULL COMMENT 'Approval step whose approver made the check',
    EMPLOYEE_ID     INT       NOT NULL COMMENT 'Employee being checked',
    CHECK_STATUS    TEXT      NOT NULL DEFAULT 'PENDING' COMMENT 'PENDING, CHECKED or REJECTED',
    CHECK_COMMENT   TEXT               COMMENT 'Reason the employee was rejected, or other notes',
    CHECKED_BY      TEXT               COMMENT 'App user who checked or rejected the employee',
    INSERT_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp (when the status last changed)',
    INSERT_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_F_APPROVAL_EMPLOYEE_CHECK PRIMARY KEY (REQUEST_ID, STEP_ORDER, EMPLOYEE_ID),
    CONSTRAINT FK_CHECK_REQUEST FOREIGN KEY (REQUEST_ID) REFERENCES APP.T_F_APPROVAL_REQUEST (REQUEST_ID),
    CONSTRAINT FK_CHECK_EMPLOYEE FOREIGN KEY (EMPLOYEE_ID) REFERENCES APP.T_D_EMPLOYEE (EMPLOYEE_ID)
) COMMENT = 'Per-employee checks by each approver. A step can only be approved when every employee is CHECKED for that step. Status history is kept in T_F_CHANGE_LOG.';

CREATE OR REPLACE TABLE APP.T_F_CHANGE_LOG (
    CHANGE_ID    INT       IDENTITY(1,1) NOT NULL COMMENT 'Surrogate key',
    TABLE_NAME   TEXT      NOT NULL COMMENT 'Table that changed, e.g. APP.T_D_EMPLOYEE_CONTRACT',
    RECORD_KEY   VARIANT   NOT NULL COMMENT 'Primary key of the changed row as JSON',
    CHANGE_TYPE  TEXT      NOT NULL COMMENT 'INSERT, UPDATE or DELETE',
    OLD_VALUES   VARIANT            COMMENT 'Changed columns before the change (JSON)',
    NEW_VALUES   VARIANT            COMMENT 'Changed columns after the change (JSON)',
    CHANGED_BY   TEXT      NOT NULL COMMENT 'App user who made the change',
    INSERT_DATE  TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp (when the change happened)',
    UPDATE_DATE  TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp (rows are never updated)',
    INSERT_BY    TEXT      DEFAULT CURRENT_USER      COMMENT 'Snowflake user who wrote the row',
    UPDATE_BY    TEXT      DEFAULT CURRENT_USER      COMMENT 'Snowflake user who last updated the row',
    CONSTRAINT PK_T_F_CHANGE_LOG PRIMARY KEY (CHANGE_ID)
) COMMENT = 'Append-only audit trail written by every SP_ procedure. Answers who changed what, and when.';
