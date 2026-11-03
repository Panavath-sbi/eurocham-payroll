-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.1; moved to APP by V1.5.0).
-- CREATE OR REPLACE TABLE: safe to run on every deployment; an existing table keeps its rows.
CREATE OR REPLACE TABLE APP.T_P_STATUTORY_PARAMETER 
(
    PARAM_CODE             TEXT      NOT NULL                  COMMENT 'Parameter code, e.g. NSSF_EE_PENSION_RATE',
    VALID_FROM_PERIOD_KEY  INT       NOT NULL                  COMMENT 'First period the value applies to',
    VALID_TO_PERIOD_KEY    INT                                 COMMENT 'Last period the value applies to; NULL = still in effect',
    PARAM_VALUE            FLOAT     NOT NULL                  COMMENT 'Numeric value (rates as decimals, e.g. 0.02 = 2%)',
    UNIT                   TEXT      NOT NULL                  COMMENT 'RATE, KHR, MULTIPLIER or DAYS',
    DESCRIPTION            TEXT                                COMMENT 'What the parameter controls',
    LEGAL_REFERENCE        TEXT                                COMMENT 'Prakas / regulation the value comes from',
    INSERT_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',

    CONSTRAINT PK_T_P_STATUTORY_PARAMETER PRIMARY KEY (PARAM_CODE, VALID_FROM_PERIOD_KEY),
    CONSTRAINT FK_PARAM_FROM              FOREIGN KEY (VALID_FROM_PERIOD_KEY) REFERENCES APP.T_D_PERIOD (PERIOD_KEY)
) 
COMMENT = 'Statutory rates, caps and constants, effective-dated. A change is a new row with a new VALID_FROM; old values stay for history. Replaces T_P_TAX_CEILING (except brackets).';
