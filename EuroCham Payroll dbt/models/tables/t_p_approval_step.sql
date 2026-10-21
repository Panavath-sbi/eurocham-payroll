-- depends_on: {{ ref('t_d_period') }}
-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created in CORE by V1.0.1, moved to APP by V1.5.0; V1.4.0 added MANAGES_EMPLOYEE_CHECKS, V1.7.0 set the APPROVER_ROLE comment).
-- CREATE TABLE IF NOT EXISTS: dbt runs this on every build; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS T_P_APPROVAL_STEP (
    APPROVAL_STEP_ID       INT       IDENTITY(1,1) NOT NULL COMMENT 'Surrogate key of the step version',
    STEP_ORDER             INT       NOT NULL COMMENT 'Sequence in the chain; 1 approves first',
    STEP_TITLE             TEXT      NOT NULL COMMENT 'Display name, e.g. HR Manager',
    APPROVER_ROLE          TEXT      NOT NULL COMMENT 'Level a user needs to act on this step (LEVEL_1 / LEVEL_2 / LEVEL_3 = step order); ADMIN may act on every step',
    APPLIES_TO             TEXT      NOT NULL DEFAULT 'ALL' COMMENT 'ACTUAL, BUDGET, FORECAST or ALL',
    VALID_FROM_PERIOD_KEY  INT       NOT NULL COMMENT 'First period this step version applies to',
    VALID_TO_PERIOD_KEY    INT                COMMENT 'Last period this step version applies to; NULL = still in effect',
    IS_ACTIVE              BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'Soft-disable flag',
    INSERT_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    MANAGES_EMPLOYEE_CHECKS BOOLEAN DEFAULT FALSE COMMENT 'TRUE for the step whose approver checks or rejects each employee (actual payroll only); that step can only be approved when every employee is CHECKED. Other steps are a plain approve.',
    CONSTRAINT PK_T_P_APPROVAL_STEP PRIMARY KEY (APPROVAL_STEP_ID),
    CONSTRAINT FK_APPROVAL_STEP_FROM FOREIGN KEY (VALID_FROM_PERIOD_KEY) REFERENCES T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Effective-dated approval chain definition.';

-- 2026-10-19  Reference data (from V1.1.0, with the roles of V1.7.0 and the employee-check flag of V1.4.0): the 3-step approval chain.
-- Reference rows: inserted once, only while the table is empty.
EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO :n FROM T_P_APPROVAL_STEP;
    IF (n = 0) THEN
        INSERT INTO T_P_APPROVAL_STEP (STEP_ORDER, STEP_TITLE, APPROVER_ROLE, APPLIES_TO, VALID_FROM_PERIOD_KEY, MANAGES_EMPLOYEE_CHECKS) VALUES
            (1, 'HR Manager', 'LEVEL_1', 'ALL', 202601, FALSE),
            (2, 'Treasurer',  'LEVEL_2', 'ALL', 202601, TRUE),
            (3, 'Director',   'LEVEL_3', 'ALL', 202601, FALSE);
    END IF;
END;
$$;
