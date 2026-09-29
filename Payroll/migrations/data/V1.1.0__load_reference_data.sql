/* =====================================================================================
   V1.1.0 - LOAD REFERENCE DATA
   Periods 2020-2035, entities, funds, departments, pay components, statutory parameters,
   tax brackets, approval chain. Loaded once in every environment (dev, test, prod).
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   NOTE: statutory values migrated from DEV.T_P_TAX_CEILING - verify against current law.
   Working days and FX rates are not loaded here: they are set in the app (Settings /
   Monthly Inputs). Dummy values for development are in dev_data/load_dummy_data.sql.
   ===================================================================================== */

-- A.1 Periods: one row per month, Jan 2020 to Dec 2035 (192 months).
--     Months are generated directly (not from days), so no month can be skipped.
INSERT INTO CORE.T_D_PERIOD (
    PERIOD_KEY, PERIOD_START_DATE, PERIOD_END_DATE, YEAR, MONTH_NUMBER, MONTH_NAME,
    PERIOD_LABEL, QUARTER, HALF_YEAR, IS_SENIORITY_MONTH, FISCAL_YEAR, WEEKDAY_COUNT)
WITH months AS (
    SELECT DATEADD(MONTH, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2020-01-01'::DATE) AS M
    FROM TABLE(GENERATOR(ROWCOUNT => 192))
),
days AS (
    SELECT DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2020-01-01'::DATE) AS D
    FROM TABLE(GENERATOR(ROWCOUNT => 5845))          -- 2020-01-01 to 2035-12-31
),
weekdays AS (
    SELECT DATE_TRUNC('MONTH', D) AS M, COUNT_IF(DAYOFWEEKISO(D) <= 5) AS WEEKDAY_COUNT
    FROM days
    GROUP BY 1
)
SELECT
    YEAR(m.M) * 100 + MONTH(m.M),
    m.M,
    LAST_DAY(m.M),
    YEAR(m.M),
    MONTH(m.M),
    TO_CHAR(m.M, 'MMMM'),
    TO_CHAR(m.M, 'Mon YYYY'),
    QUARTER(m.M),
    IFF(MONTH(m.M) <= 6, 1, 2),
    MONTH(m.M) IN (6, 12),
    YEAR(m.M),
    w.WEEKDAY_COUNT
FROM months m
JOIN weekdays w ON w.M = m.M;

-- A.2 Entities, funds, departments
INSERT INTO CORE.T_D_ENTITY (ENTITY_CODE, ENTITY_NAME) VALUES
    ('ECCC',  'EuroCham Cambodia'),
    ('CCIFC', 'CCIFC');

INSERT INTO CORE.T_D_FUND (FUND_CODE, FUND_NAME) VALUES
    ('ECCC',    'ECCC'),
    ('CCIFC',   'CCIFC'),
    ('EU_GATE', 'EU Gate');

INSERT INTO CORE.T_D_DEPARTMENT (DEPARTMENT_CODE, DEPARTMENT_NAME, DISPLAY_ORDER) VALUES
    ('ADMIN',         'Admin',         1),
    ('ADVOCACY',      'Advocacy',      2),
    ('COMMUNICATION', 'Communication', 3),
    ('EVENTS',        'Events',        4),
    ('EXECUTIVE',     'Executive',     5),
    ('MEMBERSHIPS',   'Memberships',   6),
    ('SERVICES',      'Services',      7);

-- A.3 Pay components
INSERT INTO CORE.T_D_PAY_COMPONENT
    (PAY_COMPONENT_CODE, PAY_COMPONENT_NAME, CATEGORY, IS_TAXABLE, IS_NSSF_BASE, IS_USER_ENTERED, DISPLAY_ORDER, DESCRIPTION)
VALUES
    ('BASE_SALARY',        'Base salary',                'EARNING',               TRUE,  TRUE,  FALSE, 10,  'Contract monthly salary'),
    ('UNPAID_LEAVE',       'Unpaid leave',               'EARNING',               TRUE,  FALSE, FALSE, 20,  'Negative amount: daily rate x absence days'),
    ('OVERTIME',           'Overtime',                   'EARNING',               TRUE,  FALSE, FALSE, 30,  'Daily rate x overtime days x overtime multiplier'),
    ('BONUS',              'Bonus',                      'EARNING',               TRUE,  FALSE, FALSE, 40,  'Bonus entered for the period'),
    ('OUTSTANDING_LEAVE',  'Outstanding leave payout',   'EARNING',               TRUE,  FALSE, FALSE, 50,  'Daily rate x unused leave days'),
    ('SENIORITY',          'Seniority indemnity',        'EARNING',               TRUE,  TRUE,  FALSE, 60,  'Paid in June and December; taxable above the exemption threshold'),
    ('ADJUSTMENT',         'Adjustment',                 'EARNING',               TRUE,  FALSE, TRUE,  70,  'Manual correction from APP.T_F_PAYROLL_ADJUSTMENT'),
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

-- A.4 Statutory parameters (migrated from DEV.T_P_TAX_CEILING - verify against current law)
INSERT INTO CORE.T_P_STATUTORY_PARAMETER (PARAM_CODE, VALID_FROM_PERIOD_KEY, PARAM_VALUE, UNIT, DESCRIPTION) VALUES
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

-- A.5 Resident tax brackets
INSERT INTO CORE.T_P_TAX_BRACKET
    (VALID_FROM_PERIOD_KEY, BRACKET_NUMBER, LOWER_BOUND_KHR, UPPER_BOUND_KHR, TAX_RATE, CUMULATIVE_DEDUCTION_KHR)
VALUES
    (202601, 1, 0,        1500000,  0.00, 0),
    (202601, 2, 1500000,  2000000,  0.05, 75000),
    (202601, 3, 2000000,  8500000,  0.10, 175000),
    (202601, 4, 8500000,  12500000, 0.15, 600000),
    (202601, 5, 12500000, NULL,     0.20, 1225000);

-- A.6 Approval chain
INSERT INTO CORE.T_P_APPROVAL_STEP (STEP_ORDER, STEP_TITLE, APPROVER_ROLE, APPLIES_TO, VALID_FROM_PERIOD_KEY) VALUES
    (1, 'HR Manager', 'HR_MANAGER', 'ALL', 202601),
    (2, 'Treasurer',  'TREASURER',  'ALL', 202601),
    (3, 'Director',   'DIRECTOR',   'ALL', 202601);
