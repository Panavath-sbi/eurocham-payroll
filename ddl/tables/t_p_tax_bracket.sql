-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.1; moved to APP by V1.5.0).
-- CREATE OR REPLACE TABLE: safe to run on every deployment; an existing table keeps its rows.
CREATE OR REPLACE TABLE APP.T_P_TAX_BRACKET 
(
    VALID_FROM_PERIOD_KEY    INT       NOT NULL                  COMMENT 'First period the bracket set applies to',
    VALID_TO_PERIOD_KEY      INT                                 COMMENT 'Last period the bracket set applies to; NULL = still in effect',
    BRACKET_NUMBER           INT       NOT NULL                  COMMENT 'Bracket sequence 1..n',
    LOWER_BOUND_KHR          FLOAT     NOT NULL                  COMMENT 'Bracket applies when tax base is above this amount',
    UPPER_BOUND_KHR          FLOAT                               COMMENT 'Bracket applies when tax base is at or below this amount; NULL = no upper limit',
    TAX_RATE                 FLOAT     NOT NULL                  COMMENT 'Marginal rate as a decimal, e.g. 0.10',
    CUMULATIVE_DEDUCTION_KHR FLOAT     NOT NULL                  COMMENT 'Amount subtracted: tax = base x rate - deduction',
    INSERT_DATE              TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE              TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY                TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY                TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',

    CONSTRAINT PK_T_P_TAX_BRACKET PRIMARY KEY (VALID_FROM_PERIOD_KEY, BRACKET_NUMBER),
    CONSTRAINT FK_BRACKET_FROM    FOREIGN KEY (VALID_FROM_PERIOD_KEY) REFERENCES APP.T_D_PERIOD (PERIOD_KEY)
) 
COMMENT = 'Resident salary tax brackets, effective-dated as a set.';