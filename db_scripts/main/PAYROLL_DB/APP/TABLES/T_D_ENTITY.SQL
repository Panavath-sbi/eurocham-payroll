---version: 0, author: panavath.dinsophary
-- 2026-10-19  Baseline for DLSync: the table as it stood after V1.0.1 - V1.8.0 (created in
--             CORE by V1.0.1, moved to APP by V1.5.0, unchanged otherwise).
-- Plain CREATE TABLE on purpose: if the table already exists the deploy stops instead of
-- replacing it and losing its rows.
CREATE TABLE ${DB}.APP.T_D_ENTITY (
    ENTITY_CODE   TEXT      NOT NULL COMMENT 'Entity (chamber) code, e.g. ECCC, CCIFC',
    ENTITY_NAME   TEXT      NOT NULL COMMENT 'Full entity name',
    IS_ACTIVE     BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'Whether the entity can be assigned to new contracts',
    DESCRIPTION   TEXT               COMMENT 'Free-text description',
    INSERT_DATE   TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE   TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY     TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY     TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_D_ENTITY PRIMARY KEY (ENTITY_CODE)
) COMMENT = 'Legal entity / chamber that employs the staff member.';
---rollback: DROP TABLE IF EXISTS ${DB}.APP.T_D_ENTITY;
---verify: SELECT ENTITY_CODE, ENTITY_NAME, IS_ACTIVE, DESCRIPTION FROM ${DB}.APP.T_D_ENTITY LIMIT 1;

---version: 1, author: panavath.dinsophary
-- 2026-10-19  Reference data (from V1.1.0): the two chambers.
INSERT INTO ${DB}.APP.T_D_ENTITY (ENTITY_CODE, ENTITY_NAME) VALUES
    ('ECCC',  'EuroCham Cambodia'),
    ('CCIFC', 'CCIFC');
---rollback: DELETE FROM ${DB}.APP.T_D_ENTITY WHERE ENTITY_CODE IN ('ECCC', 'CCIFC');
---verify: SELECT ENTITY_CODE FROM ${DB}.APP.T_D_ENTITY WHERE ENTITY_CODE = 'ECCC';
