/* =====================================================================================
   V1.0.3 - CORE FACT TABLES
   T_F_PAYROLL_LINE and T_F_COST_ALLOCATION (written only by the calculation).
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   NOTE: Snowflake does not enforce PRIMARY / UNIQUE / FOREIGN KEY constraints and has
   no CHECK constraints; they are declared for documentation. SP_ procedures enforce rules.
   Versioned file: never edit after deployment - add a new V file with ALTER statements.
   ===================================================================================== */

/* =====================================================================================
   4. CORE - FACT TABLES (T_F_, written by the calculation procedures)
   ===================================================================================== */

CREATE OR REPLACE TABLE CORE.T_F_PAYROLL_LINE (
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
    CONSTRAINT FK_LINE_COMPONENT FOREIGN KEY (PAY_COMPONENT_CODE) REFERENCES CORE.T_D_PAY_COMPONENT (PAY_COMPONENT_CODE),
    CONSTRAINT FK_LINE_ENTITY FOREIGN KEY (ENTITY_CODE) REFERENCES CORE.T_D_ENTITY (ENTITY_CODE)
) COMMENT = 'Grain: one row per scenario x period x employee x pay component. Holds current AND historical payroll; finalized periods are never recalculated.';

CREATE OR REPLACE TABLE CORE.T_F_COST_ALLOCATION (
    SCENARIO_ID          INT       NOT NULL COMMENT 'Scenario',
    PERIOD_KEY           INT       NOT NULL COMMENT 'Period',
    EMPLOYEE_ID          INT       NOT NULL COMMENT 'Employee',
    FUND_CODE            TEXT      NOT NULL COMMENT 'Fund charged',
    DEPARTMENT_CODE      TEXT      NOT NULL COMMENT 'Department charged',
    ENTITY_CODE          TEXT      NOT NULL COMMENT 'Entity at the time of calculation',
    ALLOCATION_SHARE     FLOAT     NOT NULL COMMENT 'Combined share as a decimal: fund share x department share',
    GROSS_PAY_USD        FLOAT     NOT NULL COMMENT 'Allocated gross pay',
    EMPLOYER_COST_USD    FLOAT     NOT NULL COMMENT 'Allocated total employer cost',
    CALCULATION_ID       TEXT      NOT NULL COMMENT 'Calculation run that produced the row',
    INSERT_DATE          TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp (when the row was calculated)',
    UPDATE_DATE          TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY            TEXT      DEFAULT CURRENT_USER      COMMENT 'User who triggered the calculation',
    UPDATE_BY            TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_F_COST_ALLOCATION PRIMARY KEY (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, FUND_CODE, DEPARTMENT_CODE),
    CONSTRAINT FK_ALLOC_SP FOREIGN KEY (SCENARIO_ID, PERIOD_KEY) REFERENCES APP.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY),
    CONSTRAINT FK_ALLOC_EMPLOYEE FOREIGN KEY (EMPLOYEE_ID) REFERENCES APP.T_D_EMPLOYEE (EMPLOYEE_ID),
    CONSTRAINT FK_ALLOC_FUND FOREIGN KEY (FUND_CODE) REFERENCES CORE.T_D_FUND (FUND_CODE),
    CONSTRAINT FK_ALLOC_DEPT FOREIGN KEY (DEPARTMENT_CODE) REFERENCES CORE.T_D_DEPARTMENT (DEPARTMENT_CODE),
    CONSTRAINT FK_ALLOC_ENTITY FOREIGN KEY (ENTITY_CODE) REFERENCES CORE.T_D_ENTITY (ENTITY_CODE)
) COMMENT = 'Grain: one row per scenario x period x employee x fund x department. Cost distributed by fund and department shares.';
