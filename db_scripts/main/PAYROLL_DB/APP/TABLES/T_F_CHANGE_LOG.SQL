---version: 0, author: panavath.dinsophary
-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.2).
-- Plain CREATE TABLE on purpose: if the table already exists the deploy stops instead of
-- replacing it and losing its rows.
CREATE TABLE ${DB}.APP.T_F_CHANGE_LOG (
    CHANGE_ID    INT       IDENTITY(1,1) NOT NULL COMMENT 'Surrogate key',
    TABLE_NAME   TEXT      NOT NULL COMMENT 'Table that changed, e.g. APP.T_D_EMPLOYEE_CONTRACT',
    RECORD_KEY   VARIANT   NOT NULL COMMENT 'Primary key of the changed row as JSON',
    CHANGE_TYPE  TEXT      NOT NULL COMMENT 'INSERT, UPDATE or DELETE',
    OLD_VALUES   VARIANT            COMMENT 'Changed columns before the change (JSON)',
    NEW_VALUES   VARIANT            COMMENT 'Changed columns after the change (JSON)',
    CHANGED_BY   TEXT      NOT NULL COMMENT 'App user who made the change',
    INSERT_DATE  TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp (when the change happened)',
    UPDATE_DATE  TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp (rows are never updated)',
    INSERT_BY    TEXT      DEFAULT CURRENT_USER      COMMENT 'Snowflake user who wrote the row',
    UPDATE_BY    TEXT      DEFAULT CURRENT_USER      COMMENT 'Snowflake user who last updated the row',
    CONSTRAINT PK_T_F_CHANGE_LOG PRIMARY KEY (CHANGE_ID)
) COMMENT = 'Append-only audit trail written by every SP_ procedure. Answers who changed what, and when.';
---rollback: DROP TABLE IF EXISTS ${DB}.APP.T_F_CHANGE_LOG;
---verify: SELECT CHANGE_ID, TABLE_NAME, RECORD_KEY FROM ${DB}.APP.T_F_CHANGE_LOG LIMIT 1;
