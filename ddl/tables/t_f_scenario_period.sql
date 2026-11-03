-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.2).
-- CREATE OR REPLACE TABLE: safe to run on every deployment; an existing table keeps its rows.
CREATE OR REPLACE TABLE APP.T_F_SCENARIO_PERIOD 
(
    SCENARIO_ID     INT       NOT NULL                  COMMENT 'Scenario',
    PERIOD_KEY      INT       NOT NULL                  COMMENT 'Period',
    PERIOD_STATUS   TEXT      NOT NULL DEFAULT 'OPEN'   COMMENT 'OPEN, IN_APPROVAL, FINALIZED (actual); DRAFT, LOCKED (budget/forecast)',
    WORKING_DAYS    INT       NOT NULL                  COMMENT 'Working days applied, copied from T_D_PERIOD when the period is created',
    FX_RATE_NBC     FLOAT     NOT NULL                  COMMENT 'NBC rate applied (actual: copied from T_P_FX_RATE; budget: assumption)',
    FX_RATE_NSSF    FLOAT     NOT NULL                  COMMENT 'NSSF rate applied (actual: copied from T_P_FX_RATE; budget: assumption)',
    FINALIZED_AT    TIMESTAMP                           COMMENT 'When the period was finalized and locked',
    FINALIZED_BY    TEXT                                COMMENT 'User who finalized the period',
    INSERT_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp (when the period was opened)',
    UPDATE_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'User who opened the period',
    UPDATE_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',

    CONSTRAINT PK_T_F_SCENARIO_PERIOD PRIMARY KEY (SCENARIO_ID, PERIOD_KEY),
    CONSTRAINT FK_SP_SCENARIO         FOREIGN KEY (SCENARIO_ID) REFERENCES APP.T_D_SCENARIO (SCENARIO_ID),
    CONSTRAINT FK_SP_PERIOD           FOREIGN KEY (PERIOD_KEY)  REFERENCES APP.T_D_PERIOD (PERIOD_KEY)
)  
COMMENT = 'Status and locked assumptions (working days, FX) of each period within a scenario. For actuals, only one period may be OPEN or IN_APPROVAL at a time.';
