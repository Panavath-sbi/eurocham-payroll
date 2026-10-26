USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.1; moved to APP by V1.5.0).
-- 2026-10-26  Reference rows removed from this script: they are loaded and maintained in each environment, not by the deployment.
-- CREATE TABLE IF NOT EXISTS: safe to run on every deployment; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS APP.T_D_DEPARTMENT (
    DEPARTMENT_CODE  TEXT      NOT NULL COMMENT 'Department / cost center code',
    DEPARTMENT_NAME  TEXT      NOT NULL COMMENT 'Department display name',
    IS_ACTIVE        BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'Whether new allocations can use this department',
    DISPLAY_ORDER    INT                COMMENT 'Sort order in the app and reports',
    INSERT_DATE      TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE      TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY        TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY        TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_DEPARTMENT PRIMARY KEY (DEPARTMENT_CODE)
) COMMENT = 'Department / cost center that payroll cost is allocated to. Replaces the PCT_* columns.';
