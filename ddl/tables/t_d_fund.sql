-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.1; moved to APP by V1.5.0).
-- CREATE OR REPLACE TABLE: safe to run on every deployment; an existing table keeps its rows.
CREATE OR REPLACE TABLE APP.T_D_FUND 
(
    FUND_CODE     TEXT      NOT NULL                           COMMENT 'Fund code, e.g. ECCC, CCIFC, EU_GATE',
    FUND_NAME     TEXT      NOT NULL                           COMMENT 'Fund display name',
    IS_ACTIVE     BOOLEAN   NOT NULL DEFAULT TRUE              COMMENT 'Whether new allocations can use this fund',
    DESCRIPTION   TEXT                                         COMMENT 'Free-text description, e.g. donor or grant',
    INSERT_DATE   TIMESTAMP          DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE   TIMESTAMP          DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY     TEXT               DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY     TEXT               DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_FUND PRIMARY KEY (FUND_CODE)
) 
COMMENT = 'Funding source that payroll cost is charged to. New funds are added as rows.';