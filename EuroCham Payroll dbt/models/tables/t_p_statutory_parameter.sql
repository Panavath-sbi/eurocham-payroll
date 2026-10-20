-- depends_on: {{ ref('t_d_period') }}
-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.1; moved to APP by V1.5.0).
-- CREATE TABLE IF NOT EXISTS: dbt runs this on every build; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS {{ app() }}.T_P_STATUTORY_PARAMETER (
    PARAM_CODE             TEXT      NOT NULL COMMENT 'Parameter code, e.g. NSSF_EE_PENSION_RATE',
    VALID_FROM_PERIOD_KEY  INT       NOT NULL COMMENT 'First period the value applies to',
    VALID_TO_PERIOD_KEY    INT                COMMENT 'Last period the value applies to; NULL = still in effect',
    PARAM_VALUE            FLOAT     NOT NULL COMMENT 'Numeric value (rates as decimals, e.g. 0.02 = 2%)',
    UNIT                   TEXT      NOT NULL COMMENT 'RATE, KHR, MULTIPLIER or DAYS',
    DESCRIPTION            TEXT               COMMENT 'What the parameter controls',
    LEGAL_REFERENCE        TEXT               COMMENT 'Prakas / regulation the value comes from',
    INSERT_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE            TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY              TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_P_STATUTORY_PARAMETER PRIMARY KEY (PARAM_CODE, VALID_FROM_PERIOD_KEY),
    CONSTRAINT FK_PARAM_FROM FOREIGN KEY (VALID_FROM_PERIOD_KEY) REFERENCES {{ app() }}.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Statutory rates, caps and constants, effective-dated. A change is a new row with a new VALID_FROM; old values stay for history. Replaces T_P_TAX_CEILING (except brackets).';

-- 2026-10-19  Reference data (from V1.1.0). Statutory values migrated from DEV.T_P_TAX_CEILING - verify against current law.
-- Reference rows: inserted once, only while the table is empty.
EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO :n FROM {{ app() }}.T_P_STATUTORY_PARAMETER;
    IF (n = 0) THEN
        INSERT INTO {{ app() }}.T_P_STATUTORY_PARAMETER (PARAM_CODE, VALID_FROM_PERIOD_KEY, PARAM_VALUE, UNIT, DESCRIPTION) VALUES
            ('NSSF_EE_PENSION_RATE',       202601, 0.02,    'RATE',       'Employee pension contribution rate'),
            ('NSSF_ER_PENSION_RATE',       202601, 0.02,    'RATE',       'Employer pension contribution rate'),
            ('NSSF_HEALTH_RATE',           202601, 0.026,   'RATE',       'Employer healthcare contribution rate'),
            ('NSSF_ORC_RATE',              202601, 0.008,   'RATE',       'Employer occupational risk contribution rate'),
            ('NSSF_BASE_FLOOR_KHR',        202601, 200000,  'KHR',        'Minimum NSSF contribution base'),
            ('NSSF_BASE_CAP_KHR',          202601, 1200000, 'KHR',        'Maximum NSSF contribution base'),
            ('DEPENDANT_ALLOWANCE_KHR',    202601, 150000,  'KHR',        'Tax relief per qualifying dependant (residents only)'),
            ('TAX_NON_RESIDENT_RATE',      202601, 0.20,    'RATE',       'Flat salary tax rate for non-residents'),
            ('SENIORITY_TAX_EXEMPT_KHR',   202601, 2000000, 'KHR',        'Seniority indemnity exempt from salary tax'),
            ('SENIORITY_DAYS_PER_PAYMENT', 202601, 7.5,     'DAYS',       'Days of average wage paid per seniority payment'),
            ('OVERTIME_MULTIPLIER',        202601, 1.5,     'MULTIPLIER', 'Overtime pay multiplier');
    END IF;
END;
$$;
