EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO :n FROM APP.T_D_PAY_COMPONENT;
    IF (n = 0) THEN
        INSERT INTO APP.T_D_PAY_COMPONENT
            (PAY_COMPONENT_CODE, PAY_COMPONENT_NAME, CATEGORY, IS_TAXABLE, IS_NSSF_BASE, IS_USER_ENTERED, DISPLAY_ORDER, DESCRIPTION)
        VALUES
            ('BASE_SALARY',        'Base salary',                'EARNING',               TRUE,  TRUE,  FALSE, 10,  'Contract monthly salary'),
            ('UNPAID_LEAVE',       'Unpaid leave',               'EARNING',               TRUE,  FALSE, FALSE, 20,  'Negative amount: daily rate x absence days'),
            ('OVERTIME',           'Overtime',                   'EARNING',               TRUE,  FALSE, FALSE, 30,  'Daily rate x overtime days x overtime multiplier'),
            ('BONUS',              'Bonus',                      'EARNING',               TRUE,  FALSE, FALSE, 40,  'Bonus entered for the period'),
            ('OUTSTANDING_LEAVE',  'Outstanding leave payout',   'EARNING',               TRUE,  FALSE, FALSE, 50,  'Daily rate x unused leave days'),
            ('SENIORITY',          'Seniority indemnity',        'EARNING',               TRUE,  TRUE,  FALSE, 60,  'Paid in June and December; taxable above the exemption threshold'),
            ('NSSF_EE_PENSION',    'NSSF pension (employee)',    'EMPLOYEE_DEDUCTION',    FALSE, FALSE, FALSE, 110, 'Employee pension contribution'),
            ('SALARY_TAX',         'Salary tax',                 'EMPLOYEE_DEDUCTION',    FALSE, FALSE, FALSE, 120, 'Tax on salary withheld'),
            ('NSSF_ER_PENSION',    'NSSF pension (employer)',    'EMPLOYER_CONTRIBUTION', FALSE, FALSE, FALSE, 210, 'Employer pension contribution'),
            ('NSSF_ER_HEALTH',     'NSSF healthcare (employer)', 'EMPLOYER_CONTRIBUTION', FALSE, FALSE, FALSE, 220, 'Employer healthcare contribution'),
            ('NSSF_ER_ORC',        'NSSF occupational risk',     'EMPLOYER_CONTRIBUTION', FALSE, FALSE, FALSE, 230, 'Employer occupational risk contribution'),
            ('INSURANCE',          'Insurance',                  'EMPLOYER_COST',         FALSE, FALSE, FALSE, 310, 'Employer-paid insurance, never in pay'),
            ('VISA',               'Visa',                       'EMPLOYER_COST',         FALSE, FALSE, FALSE, 320, 'Employer-paid visa, never in pay'),
            ('WORK_PERMIT',        'Work permit',                'EMPLOYER_COST',         FALSE, FALSE, FALSE, 330, 'Employer-paid work permit, never in pay'),
            ('FRINGE_BENEFIT',     'Fringe benefit',             'EMPLOYER_COST',         FALSE, FALSE, FALSE, 340, 'Fringe benefit cost (fringe benefit tax to be modeled)'),
            ('NSSF_BASE',          'NSSF contribution base',     'INFORMATION',           FALSE, FALSE, FALSE, 910, 'Capped and floored NSSF base, stored for audit'),
            ('TAXABLE_BASE',       'Taxable base',               'INFORMATION',           FALSE, FALSE, FALSE, 920, 'Taxable income before dependant relief'),
            ('DEPENDANT_RELIEF',   'Dependant relief',           'INFORMATION',           FALSE, FALSE, FALSE, 930, 'Dependant deduction applied to the tax base'),
            ('TAX_CALC_BASE',      'Tax calculation base',       'INFORMATION',           FALSE, FALSE, FALSE, 940, 'Base used for the bracket lookup');
    END IF;
END;
$$;
