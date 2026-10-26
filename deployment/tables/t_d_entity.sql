USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

-- 2026-10-19  Baseline for DLSync: the table as it stood after V1.0.1 - V1.8.0 (created in
--             CORE by V1.0.1, moved to APP by V1.5.0, unchanged otherwise).
-- CREATE TABLE IF NOT EXISTS: safe to run on every deployment; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS APP.T_D_ENTITY (
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

-- 2026-10-19  Reference data (from V1.1.0): the two chambers.
-- Reference rows: inserted once, only while the table is empty.
EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO :n FROM APP.T_D_ENTITY;
    IF (n = 0) THEN
        INSERT INTO APP.T_D_ENTITY (ENTITY_CODE, ENTITY_NAME) VALUES
            ('ECCC',  'EuroCham Cambodia'),
            ('CCIFC', 'CCIFC');
    END IF;
END;
$$;
