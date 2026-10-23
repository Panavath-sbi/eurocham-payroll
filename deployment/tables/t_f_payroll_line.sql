-- depends_on: T_F_SCENARIO_PERIOD, T_D_EMPLOYEE, T_D_PAY_COMPONENT, T_D_ENTITY
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.3; moved to APP by V1.5.0).
-- CREATE TABLE IF NOT EXISTS: safe to run on every deployment; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS APP.T_F_PAYROLL_LINE (
    SCENARIO_ID           INT       NOT NULL COMMENT 'Scenario (actual, budget or forecast)',
    PERIOD_KEY            INT       NOT NULL COMMENT 'Period',
    EMPLOYEE_ID           INT       NOT NULL COMMENT 'Employee',
    PAY_COMPONENT_CODE    TEXT      NOT NULL COMMENT 'Pay component',
    EMPLOYEE_VERSION_KEY  INT       NOT NULL COMMENT 'Contract version used (APP.T_D_EMPLOYEE_CONTRACT.CONTRACT_ID)',
    ENTITY_CODE           TEXT      NOT NULL COMMENT 'Entity at the time of calculation',
    QUANTITY              FLOAT              COMMENT 'Days, hours or other quantity behind the amount, if any',
    RATE                  FLOAT              COMMENT 'Rate applied (daily rate, tax rate, NSSF rate), if any',
    AMOUNT_USD            FLOAT     NOT NULL COMMENT 'Amount in USD, rounded to 2 decimals. Positive, except reductions such as UNPAID_LEAVE',
    AMOUNT_KHR            FLOAT     NOT NULL COMMENT 'Amount in KHR, rounded to whole riel',
    FX_RATE_APPLIED       FLOAT              COMMENT 'Exchange rate used to convert this line',
    CALCULATION_ID        TEXT      NOT NULL COMMENT 'Identifier of the calculation run that produced the line',
    INSERT_DATE           TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp (when the line was calculated)',
    UPDATE_DATE           TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY             TEXT      DEFAULT CURRENT_USER      COMMENT 'User who triggered the calculation',
    UPDATE_BY             TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_F_PAYROLL_LINE PRIMARY KEY (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, PAY_COMPONENT_CODE),
    CONSTRAINT FK_LINE_SP FOREIGN KEY (SCENARIO_ID, PERIOD_KEY) REFERENCES APP.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY),
    CONSTRAINT FK_LINE_EMPLOYEE FOREIGN KEY (EMPLOYEE_ID) REFERENCES APP.T_D_EMPLOYEE (EMPLOYEE_ID),
    CONSTRAINT FK_LINE_COMPONENT FOREIGN KEY (PAY_COMPONENT_CODE) REFERENCES APP.T_D_PAY_COMPONENT (PAY_COMPONENT_CODE),
    CONSTRAINT FK_LINE_ENTITY FOREIGN KEY (ENTITY_CODE) REFERENCES APP.T_D_ENTITY (ENTITY_CODE)
) COMMENT = 'Grain: one row per scenario x period x employee x pay component. Holds current AND historical payroll; finalized periods are never recalculated.';
