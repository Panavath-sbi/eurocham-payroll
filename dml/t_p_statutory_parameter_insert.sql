EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO :n FROM APP.T_P_STATUTORY_PARAMETER;
    IF (n = 0) THEN
        INSERT INTO APP.T_P_STATUTORY_PARAMETER (PARAM_CODE, VALID_FROM_PERIOD_KEY, PARAM_VALUE, UNIT, DESCRIPTION) VALUES
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
