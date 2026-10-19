---version: 0, author: panavath.dinsophary
-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.1; moved to APP by V1.5.0).
-- Plain CREATE TABLE on purpose: if the table already exists the deploy stops instead of
-- replacing it and losing its rows.
CREATE TABLE ${DB}.APP.T_D_FUND (
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
---rollback: DROP TABLE IF EXISTS ${DB}.APP.T_D_FUND;
---verify: SELECT FUND_CODE, FUND_NAME, IS_ACTIVE FROM ${DB}.APP.T_D_FUND LIMIT 1;

---version: 1, author: panavath.dinsophary
-- 2026-10-19  Reference data (from V1.1.0): the three funds.
INSERT INTO ${DB}.APP.T_D_FUND (FUND_CODE, FUND_NAME) VALUES
    ('ECCC',    'ECCC'),
    ('CCIFC',   'CCIFC'),
    ('EU_GATE', 'EU Gate');
---rollback: DELETE FROM ${DB}.APP.T_D_FUND WHERE FUND_CODE IN ('ECCC', 'CCIFC', 'EU_GATE');
---verify: SELECT FUND_CODE FROM ${DB}.APP.T_D_FUND WHERE FUND_CODE = 'ECCC';
