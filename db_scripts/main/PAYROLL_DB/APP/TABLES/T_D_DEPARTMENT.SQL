---version: 0, author: panavath.dinsophary
-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.1; moved to APP by V1.5.0).
-- Plain CREATE TABLE on purpose: if the table already exists the deploy stops instead of
-- replacing it and losing its rows.
CREATE TABLE ${DB}.APP.T_D_DEPARTMENT (
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
---rollback: DROP TABLE IF EXISTS ${DB}.APP.T_D_DEPARTMENT;
---verify: SELECT DEPARTMENT_CODE, DEPARTMENT_NAME, IS_ACTIVE FROM ${DB}.APP.T_D_DEPARTMENT LIMIT 1;

---version: 1, author: panavath.dinsophary
-- 2026-10-19  Reference data (from V1.1.0): the seven departments (no Default).
INSERT INTO ${DB}.APP.T_D_DEPARTMENT (DEPARTMENT_CODE, DEPARTMENT_NAME, DISPLAY_ORDER) VALUES
    ('ADMIN',         'Admin',         1),
    ('ADVOCACY',      'Advocacy',      2),
    ('COMMUNICATION', 'Communication', 3),
    ('EVENTS',        'Events',        4),
    ('EXECUTIVE',     'Executive',     5),
    ('MEMBERSHIPS',   'Memberships',   6),
    ('SERVICES',      'Services',      7);
---rollback: DELETE FROM ${DB}.APP.T_D_DEPARTMENT;
---verify: SELECT COUNT(*) FROM ${DB}.APP.T_D_DEPARTMENT;
