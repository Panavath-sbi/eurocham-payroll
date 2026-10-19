---version: 0, author: panavath.dinsophary
-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.2).
-- Plain CREATE TABLE on purpose: if the table already exists the deploy stops instead of
-- replacing it and losing its rows.
CREATE TABLE ${DB}.APP.T_D_SCENARIO (
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
    CONSTRAINT FK_SCENARIO_BASE FOREIGN KEY (BASE_SCENARIO_ID) REFERENCES ${DB}.APP.T_D_SCENARIO (SCENARIO_ID),
    CONSTRAINT FK_SCENARIO_ASOF FOREIGN KEY (FORECAST_AS_OF_PERIOD_KEY) REFERENCES ${DB}.APP.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Scenario dimension: actual payroll, budget scenarios and forecast versions.';
---rollback: DROP TABLE IF EXISTS ${DB}.APP.T_D_SCENARIO;
---verify: SELECT SCENARIO_ID, SCENARIO_TYPE, SCENARIO_NAME FROM ${DB}.APP.T_D_SCENARIO LIMIT 1;
