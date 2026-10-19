---version: 0, author: panavath.dinsophary
-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.1; moved to APP by V1.5.0).
-- Plain CREATE TABLE on purpose: if the table already exists the deploy stops instead of
-- replacing it and losing its rows.
CREATE TABLE ${DB}.APP.T_P_TAX_BRACKET (
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
    CONSTRAINT FK_BRACKET_FROM FOREIGN KEY (VALID_FROM_PERIOD_KEY) REFERENCES ${DB}.APP.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Resident salary tax brackets, effective-dated as a set.';
---rollback: DROP TABLE IF EXISTS ${DB}.APP.T_P_TAX_BRACKET;
---verify: SELECT VALID_FROM_PERIOD_KEY, VALID_TO_PERIOD_KEY, BRACKET_NUMBER FROM ${DB}.APP.T_P_TAX_BRACKET LIMIT 1;

---version: 1, author: panavath.dinsophary
-- 2026-10-19  Reference data (from V1.1.0): resident tax brackets from 202601.
INSERT INTO ${DB}.APP.T_P_TAX_BRACKET
    (VALID_FROM_PERIOD_KEY, BRACKET_NUMBER, LOWER_BOUND_KHR, UPPER_BOUND_KHR, TAX_RATE, CUMULATIVE_DEDUCTION_KHR)
VALUES
    (202601, 1, 0,        1500000,  0.00, 0),
    (202601, 2, 1500000,  2000000,  0.05, 75000),
    (202601, 3, 2000000,  8500000,  0.10, 175000),
    (202601, 4, 8500000,  12500000, 0.15, 600000),
    (202601, 5, 12500000, NULL,     0.20, 1225000);
---rollback: DELETE FROM ${DB}.APP.T_P_TAX_BRACKET;
---verify: SELECT COUNT(*) FROM ${DB}.APP.T_P_TAX_BRACKET;
