-- depends_on: T_F_SCENARIO_PERIOD, T_D_EMPLOYEE, T_D_FUND
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.2).
-- CREATE TABLE IF NOT EXISTS: safe to run on every deployment; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS APP.T_F_FUND_ALLOCATION (
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
    CONSTRAINT FK_FUND_ALLOC_FUND FOREIGN KEY (FUND_CODE) REFERENCES APP.T_D_FUND (FUND_CODE)
) COMMENT = 'Fund split per employee and period, as percentages. Replaces ECCC_FUND / CCIFC_FUND / EU_GATE_FUND day columns (days / working days x 100).';
