/* =====================================================================================
   DEV DATA - DUMMY DATA AND CHECKS
   Development / test only. Never run in production. Run after all migrations.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-02  Approvals use APP.T_F_APPROVAL_STEP_STATE (one row per step) instead of the
               dropped action log; employee checks have no step column (step 2 only).
   Part D: dummy working days and FX rates. Part B: employees, scenarios, inputs,
   approvals and fact rows. Part C: check queries with expected results.
   ===================================================================================== */

/* =====================================================================================
   PART D - DUMMY CALENDAR AND FX VALUES
   ===================================================================================== */

-- D.1 Working days (dummy values; normally set on the Settings page)
UPDATE CORE.T_D_PERIOD p
SET WORKING_DAYS = v.WD, UPDATE_DATE = CURRENT_TIMESTAMP
FROM (VALUES
    (202601, 22), (202602, 20), (202603, 20), (202604, 22), (202605, 21), (202606, 21),
    (202607, 21), (202608, 21), (202609, 22), (202610, 22), (202611, 21), (202612, 22)
) AS v (PK, WD)
WHERE p.PERIOD_KEY = v.PK;

UPDATE CORE.T_D_PERIOD p
SET BUDGET_WORKING_DAYS = v.WD, UPDATE_DATE = CURRENT_TIMESTAMP
FROM (VALUES
    (202701, 20), (202702, 20), (202703, 20), (202704, 20), (202705, 20), (202706, 22),
    (202707, 20), (202708, 20), (202709, 20), (202710, 20), (202711, 20), (202712, 20)
) AS v (PK, WD)
WHERE p.PERIOD_KEY = v.PK;

-- D.2 Exchange rates (dummy)
INSERT INTO CORE.T_P_FX_RATE (PERIOD_KEY, RATE_TYPE, EXCHANGE_RATE, SOURCE_NOTE) VALUES
    (202609, 'NBC',  4080, 'Dummy value'),
    (202609, 'NSSF', 4050, 'Dummy value'),
    (202610, 'NBC',  4085, 'Dummy value'),
    (202610, 'NSSF', 4050, 'Dummy value');

/* =====================================================================================
   PART B - DUMMY DATA
   ===================================================================================== */

-- B.1 App users and roles
INSERT INTO APP.T_D_APP_USER (USER_EMAIL, DISPLAY_NAME) VALUES
    ('admin@example.org',     'Payroll Admin'),
    ('clerk@example.org',     'Payroll Clerk'),
    ('hr@example.org',        'HR Manager'),
    ('treasurer@example.org', 'Treasurer'),
    ('director@example.org',  'Director');

INSERT INTO APP.T_D_APP_USER_ROLE (USER_EMAIL, ROLE_CODE) VALUES
    ('admin@example.org',     'PAYROLL_ADMIN'),
    ('clerk@example.org',     'BUDGET_EDITOR'),
    ('hr@example.org',        'HR_MANAGER'),
    ('treasurer@example.org', 'TREASURER'),
    ('director@example.org',  'DIRECTOR');

-- B.2 Scenarios: the actual payroll, two budget scenarios for 2027, one forecast for 2026
INSERT INTO APP.T_D_SCENARIO (SCENARIO_TYPE, SCENARIO_NAME, FISCAL_YEAR, SCENARIO_STATUS, IS_OFFICIAL, FORECAST_AS_OF_PERIOD_KEY, DESCRIPTION) VALUES
    ('ACTUAL',   'Actual payroll',     NULL, 'ACTIVE',   FALSE, NULL,   'All real payroll periods, open and finalized'),
    ('BUDGET',   'Budget 2027 Base',   2027, 'APPROVED', TRUE,  NULL,   'Official 2027 budget'),
    ('BUDGET',   'Budget 2027 Growth', 2027, 'DRAFT',    FALSE, NULL,   'Higher raises and one planned intern'),
    ('FORECAST', 'Forecast 2026 Q3',   2026, 'DRAFT',    FALSE, 202609, 'Actuals to Sep, rolled forward Oct-Dec');

UPDATE APP.T_D_SCENARIO
SET BASE_SCENARIO_ID = (SELECT SCENARIO_ID FROM APP.T_D_SCENARIO WHERE SCENARIO_NAME = 'Budget 2027 Base')
WHERE SCENARIO_NAME = 'Budget 2027 Growth';

-- B.3 Employees: three active, one deactivated, one planned hire (Growth scenario only)
INSERT INTO APP.T_D_EMPLOYEE
    (RESOURCE_CODE, FIRST_NAME, LAST_NAME, EMAIL, NATIONALITY, EMPLOYMENT_START_DATE, EMPLOYMENT_END_DATE, IS_ACTIVE,
     BANK_NAME, BANK_ACCOUNT_NAME, BANK_ACCOUNT_NUMBER, IS_PLANNED)
VALUES
    ('HR-KH-001', 'Sokha',  'CHAN',   'sokha@example.org',  'Cambodian', '2021-03-01', NULL,         TRUE,  'Demo Bank', 'CHAN SOKHA',    '000111222', FALSE),
    ('HR-FR-002', 'Martin', 'DUPONT', 'martin@example.org', 'French',    '2024-01-01', NULL,         TRUE,  'Demo Bank', 'MARTIN DUPONT', '000333444', FALSE),
    ('HR-KH-003', 'Dara',   'KIM',    'dara@example.org',   'Cambodian', '2023-06-01', NULL,         TRUE,  'Demo Bank', 'KIM DARA',      '000555666', FALSE),
    ('HR-KH-004', 'Vanna',  'SOK',    'vanna@example.org',  'Cambodian', '2022-02-01', '2026-08-31', FALSE, 'Demo Bank', 'SOK VANNA',     '000777888', FALSE);

INSERT INTO APP.T_D_EMPLOYEE (RESOURCE_CODE, FIRST_NAME, LAST_NAME, IS_PLANNED, PLANNED_SCENARIO_ID)
SELECT 'PLAN-2027-001', 'Planned', 'Intern', TRUE, SCENARIO_ID
FROM APP.T_D_SCENARIO WHERE SCENARIO_NAME = 'Budget 2027 Growth';

-- B.4 Contract versions. Sokha has two versions: a raise to 1,100 from Nov 2026.
INSERT INTO APP.T_D_EMPLOYEE_CONTRACT
    (EMPLOYEE_ID, VALID_FROM_PERIOD_KEY, VALID_TO_PERIOD_KEY, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
     MONTHLY_SALARY_USD, TAX_STATUS, DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD, WORK_PERMIT_USD, CHANGE_REASON)
SELECT e.EMPLOYEE_ID, v.VF, v.VT, v.POS, v.ETYPE, v.CTYPE, v.ENT, v.SAL, v.TAX, v.CH, v.SP, v.INS, v.VISA, v.WP, v.REASON
FROM (VALUES
    ('HR-KH-001', 202601, 202610::INT, 'Officer',          'FULL_TIME',  'UDC', 'ECCC',  1000, 'RESIDENT',     1, 1, 30, 0,  0,  'Initial load'),
    ('HR-KH-001', 202611, NULL,        'Officer',          'FULL_TIME',  'UDC', 'ECCC',  1100, 'RESIDENT',     1, 1, 30, 0,  0,  'Annual raise'),
    ('HR-FR-002', 202601, NULL,        'Director',         'FULL_TIME',  'FDC', 'ECCC',  3500, 'NON_RESIDENT', 0, 0, 50, 25, 20, 'Initial load'),
    ('HR-KH-003', 202601, NULL,        'Assistant',        'FULL_TIME',  'UDC', 'CCIFC', 650,  'RESIDENT',     0, 0, 0,  0,  0,  'Initial load'),
    ('HR-KH-004', 202601, 202608,      'Assistant',        'INTERNSHIP', 'FDC', 'ECCC',  300,  'RESIDENT',     0, 0, 0,  0,  0,  'Initial load')
) AS v (RC, VF, VT, POS, ETYPE, CTYPE, ENT, SAL, TAX, CH, SP, INS, VISA, WP, REASON)
JOIN APP.T_D_EMPLOYEE e ON e.RESOURCE_CODE = v.RC;

-- B.5 Scenario periods
--     Actual: Sep 2026 finalized, Oct 2026 open.
INSERT INTO APP.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY, PERIOD_STATUS, WORKING_DAYS, FX_RATE_NBC, FX_RATE_NSSF, FINALIZED_AT, FINALIZED_BY)
SELECT s.SCENARIO_ID, v.PK, v.STATUS, p.WORKING_DAYS, v.NBC, v.NSSF, v.FIN_AT, v.FIN_BY
FROM (VALUES
    (202609, 'FINALIZED', 4080, 4050, '2026-09-25 10:00:00'::TIMESTAMP, 'admin@example.org'),
    (202610, 'OPEN',      4085, 4050, NULL,                             NULL)
) AS v (PK, STATUS, NBC, NSSF, FIN_AT, FIN_BY)
JOIN APP.T_D_SCENARIO s ON s.SCENARIO_NAME = 'Actual payroll'
JOIN CORE.T_D_PERIOD p  ON p.PERIOD_KEY = v.PK;

--     Budgets: all 12 months of 2027, using the budget calendar and an assumed FX rate.
INSERT INTO APP.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY, PERIOD_STATUS, WORKING_DAYS, FX_RATE_NBC, FX_RATE_NSSF)
SELECT s.SCENARIO_ID, p.PERIOD_KEY, IFF(s.SCENARIO_STATUS = 'APPROVED', 'LOCKED', 'DRAFT'), p.BUDGET_WORKING_DAYS, 4100, 4050
FROM APP.T_D_SCENARIO s
JOIN CORE.T_D_PERIOD p ON p.YEAR = s.FISCAL_YEAR
WHERE s.SCENARIO_TYPE = 'BUDGET';

--     Forecast: Oct-Dec 2026 (Jan-Sep come from actuals).
INSERT INTO APP.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY, PERIOD_STATUS, WORKING_DAYS, FX_RATE_NBC, FX_RATE_NSSF)
SELECT s.SCENARIO_ID, p.PERIOD_KEY, 'DRAFT', p.WORKING_DAYS, 4085, 4050
FROM APP.T_D_SCENARIO s
JOIN CORE.T_D_PERIOD p ON p.PERIOD_KEY BETWEEN 202610 AND 202612
WHERE s.SCENARIO_NAME = 'Forecast 2026 Q3';

-- B.6 Scenario employee terms (budgets and forecast)
INSERT INTO APP.T_D_SCENARIO_EMPLOYEE
    (SCENARIO_ID, EMPLOYEE_ID, SOURCE_CONTRACT_ID, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
     MONTHLY_SALARY_USD, RAISE_PCT, REVALUATION_PERIOD_KEY, FINAL_SALARY_USD, TAX_STATUS,
     DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD, WORK_PERMIT_USD, FRINGE_BENEFIT_USD)
SELECT s.SCENARIO_ID, e.EMPLOYEE_ID, c.CONTRACT_ID, v.POS, v.ETYPE, v.CTYPE, v.ENT,
       v.SAL, v.RAISE, v.REVAL, v.FINAL, v.TAX, v.CH, v.SP, v.INS, v.VISA, v.WP, v.FRINGE
FROM (VALUES
    -- scenario,            employee,        position,    type,         contract, entity, salary, raise, reval,       final,  tax,           ch, sp, ins, visa, wp, fringe
    ('Budget 2027 Base',   'HR-KH-001',     'Officer',   'FULL_TIME',  'UDC',    'ECCC',  1100,   5,     202704::INT, 1155,   'RESIDENT',     1,  1,  30,  0,    0,  0),
    ('Budget 2027 Base',   'HR-FR-002',     'Director',  'FULL_TIME',  'FDC',    'ECCC',  3500,   0,     NULL,        3500,   'NON_RESIDENT', 0,  0,  50,  25,   20, 0),
    ('Budget 2027 Base',   'HR-KH-003',     'Assistant', 'FULL_TIME',  'UDC',    'CCIFC', 650,    0,     NULL,        650,    'RESIDENT',     0,  0,  0,   0,    0,  0),
    ('Budget 2027 Growth', 'HR-KH-001',     'Officer',   'FULL_TIME',  'UDC',    'ECCC',  1100,   10,    202704,      1210,   'RESIDENT',     1,  1,  30,  0,    0,  0),
    ('Budget 2027 Growth', 'HR-FR-002',     'Director',  'FULL_TIME',  'FDC',    'ECCC',  3500,   6,     202701,      3710,   'NON_RESIDENT', 0,  0,  50,  25,   20, 100),
    ('Budget 2027 Growth', 'HR-KH-003',     'Assistant', 'FULL_TIME',  'UDC',    'CCIFC', 650,    4,     202707,      676,    'RESIDENT',     0,  0,  0,   0,    0,  0),
    ('Budget 2027 Growth', 'PLAN-2027-001', 'Intern',    'INTERNSHIP', 'FDC',    'ECCC',  300,    0,     NULL,        300,    'RESIDENT',     0,  0,  0,   0,    0,  0),
    ('Forecast 2026 Q3',   'HR-KH-001',     'Officer',   'FULL_TIME',  'UDC',    'ECCC',  1000,   10,    202611,      1100,   'RESIDENT',     1,  1,  30,  0,    0,  0),
    ('Forecast 2026 Q3',   'HR-FR-002',     'Director',  'FULL_TIME',  'FDC',    'ECCC',  3500,   0,     NULL,        3500,   'NON_RESIDENT', 0,  0,  50,  25,   20, 0),
    ('Forecast 2026 Q3',   'HR-KH-003',     'Assistant', 'FULL_TIME',  'UDC',    'CCIFC', 650,    0,     NULL,        650,    'RESIDENT',     0,  0,  0,   0,    0,  0)
) AS v (SCEN, RC, POS, ETYPE, CTYPE, ENT, SAL, RAISE, REVAL, FINAL, TAX, CH, SP, INS, VISA, WP, FRINGE)
JOIN APP.T_D_SCENARIO s ON s.SCENARIO_NAME = v.SCEN
JOIN APP.T_D_EMPLOYEE e ON e.RESOURCE_CODE = v.RC
LEFT JOIN APP.T_D_EMPLOYEE_CONTRACT c
       ON c.EMPLOYEE_ID = e.EMPLOYEE_ID AND c.VALID_TO_PERIOD_KEY IS NULL;

-- B.7 Monthly inputs (a few rows)
INSERT INTO APP.T_F_PAYROLL_INPUT
    (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, INCLUDE_IN_PAYROLL, ABSENCE_DAYS, OVERTIME_DAYS, OUTSTANDING_DAYS, BONUS_USD,
     SALARY_OVERRIDE_USD, FRINGE_BENEFIT_OVERRIDE_USD, NOTES)
SELECT s.SCENARIO_ID, v.PK, e.EMPLOYEE_ID, v.INC, v.ABS_D, v.OT_D, v.OUT_D, v.BONUS, v.SAL_OVR, v.FB_OVR, v.NOTES
FROM (VALUES
    ('Actual payroll',     202609, 'HR-KH-001',     TRUE,  0, 0, 0, 0,   NULL::FLOAT, NULL::FLOAT, NULL::TEXT),
    ('Actual payroll',     202609, 'HR-FR-002',     TRUE,  0, 0, 0, 0,   NULL,        NULL,        NULL),
    ('Actual payroll',     202609, 'HR-KH-003',     TRUE,  0, 0, 0, 0,   NULL,        NULL,        NULL),
    ('Actual payroll',     202610, 'HR-KH-001',     TRUE,  2, 0, 0, 0,   NULL,        NULL,        'Two days unpaid leave'),
    ('Actual payroll',     202610, 'HR-FR-002',     TRUE,  0, 1, 0, 0,   NULL,        NULL,        'One overtime day'),
    ('Actual payroll',     202610, 'HR-KH-003',     TRUE,  0, 0, 3, 50,  NULL,        NULL,        'Leave payout and small bonus'),
    ('Budget 2027 Base',   202703, 'HR-KH-001',     TRUE,  0, 0, 0, 200, NULL,        NULL,        'March bonus'),
    ('Budget 2027 Growth', 202701, 'PLAN-2027-001', FALSE, 0, 0, 0, 0,   NULL,        NULL,        'Intern starts in June'),
    ('Budget 2027 Growth', 202706, 'PLAN-2027-001', TRUE,  0, 0, 0, 0,   NULL,        NULL,        'Intern first month'),
    ('Forecast 2026 Q3',   202612, 'HR-FR-002',     TRUE,  0, 0, 0, 0,   3800,        NULL,        'One-month override for December')
) AS v (SCEN, PK, RC, INC, ABS_D, OT_D, OUT_D, BONUS, SAL_OVR, FB_OVR, NOTES)
JOIN APP.T_D_SCENARIO s ON s.SCENARIO_NAME = v.SCEN
JOIN APP.T_D_EMPLOYEE e ON e.RESOURCE_CODE = v.RC;

-- B.8 Fund and department allocations for the open month (Oct 2026)
INSERT INTO APP.T_F_FUND_ALLOCATION (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, FUND_CODE, SHARE_PCT)
SELECT s.SCENARIO_ID, 202610, e.EMPLOYEE_ID, v.FUND, v.PCT
FROM (VALUES
    ('HR-KH-001', 'ECCC',    100),
    ('HR-FR-002', 'ECCC',    70),
    ('HR-FR-002', 'EU_GATE', 30),
    ('HR-KH-003', 'CCIFC',   100)
) AS v (RC, FUND, PCT)
JOIN APP.T_D_SCENARIO s ON s.SCENARIO_NAME = 'Actual payroll'
JOIN APP.T_D_EMPLOYEE e ON e.RESOURCE_CODE = v.RC;

INSERT INTO APP.T_F_DEPARTMENT_ALLOCATION (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, DEPARTMENT_CODE, SHARE_PCT)
SELECT s.SCENARIO_ID, 202610, e.EMPLOYEE_ID, v.DEPT, v.PCT
FROM (VALUES
    ('HR-KH-001', 'ADMIN',     60),
    ('HR-KH-001', 'ADVOCACY',  40),
    ('HR-FR-002', 'EXECUTIVE', 100),
    ('HR-KH-003', 'SERVICES',  100)
) AS v (RC, DEPT, PCT)
JOIN APP.T_D_SCENARIO s ON s.SCENARIO_NAME = 'Actual payroll'
JOIN APP.T_D_EMPLOYEE e ON e.RESOURCE_CODE = v.RC;

-- B.9 An adjustment in Oct correcting Sep
INSERT INTO APP.T_F_PAYROLL_ADJUSTMENT (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, PAY_COMPONENT_CODE, AMOUNT_USD, REFERENCE_PERIOD_KEY, REASON)
SELECT s.SCENARIO_ID, 202610, e.EMPLOYEE_ID, 'ADJUSTMENT', 20, 202609, 'September transport allowance was missed'
FROM APP.T_D_SCENARIO s
JOIN APP.T_D_EMPLOYEE e ON e.RESOURCE_CODE = 'HR-KH-003'
WHERE s.SCENARIO_NAME = 'Actual payroll';

-- B.10 Approval requests: Sep approved, Oct in progress, Budget 2027 Base approved
INSERT INTO APP.T_F_APPROVAL_REQUEST (SCENARIO_ID, PERIOD_KEY, REQUEST_STATUS, COMPLETED_AT, INSERT_BY)
SELECT s.SCENARIO_ID, v.PK, v.STATUS, v.DONE, 'admin@example.org'
FROM (VALUES
    ('Actual payroll',   202609::INT, 'APPROVED',    '2026-09-25 09:30:00'::TIMESTAMP),
    ('Actual payroll',   202610,      'IN_PROGRESS', NULL),
    ('Budget 2027 Base', NULL,        'APPROVED',    '2026-09-10 16:00:00')
) AS v (SCEN, PK, STATUS, DONE)
JOIN APP.T_D_SCENARIO s ON s.SCENARIO_NAME = v.SCEN;

-- One row per approval step: Sep and the Base budget fully approved, Oct approved by step 1 only
INSERT INTO APP.T_F_APPROVAL_STEP_STATE
    (REQUEST_ID, STEP_ORDER, STEP_STATUS, LAST_ACTION, ACTED_BY, ACTED_AT, STEP_COMMENT)
SELECT r.REQUEST_ID, v.STEP, v.STATUS, v.ACTION, v.BY_USER, v.AT, v.CMT
FROM (VALUES
    ('Actual payroll',   202609::INT, 1, 'APPROVED', 'APPROVE', 'hr@example.org',        '2026-09-24 09:00:00'::TIMESTAMP, NULL::TEXT),
    ('Actual payroll',   202609,      2, 'APPROVED', 'APPROVE', 'treasurer@example.org', '2026-09-24 15:00:00', NULL),
    ('Actual payroll',   202609,      3, 'APPROVED', 'APPROVE', 'director@example.org',  '2026-09-25 09:30:00', 'Approved'),
    ('Actual payroll',   202610,      1, 'APPROVED', 'APPROVE', 'hr@example.org',        '2026-10-26 10:00:00', 'Inputs checked'),
    ('Actual payroll',   202610,      2, 'PENDING',  NULL,      NULL,                    NULL,                  NULL),
    ('Actual payroll',   202610,      3, 'PENDING',  NULL,      NULL,                    NULL,                  NULL),
    ('Budget 2027 Base', NULL,        1, 'APPROVED', 'APPROVE', 'hr@example.org',        '2026-09-08 11:00:00', NULL),
    ('Budget 2027 Base', NULL,        2, 'APPROVED', 'APPROVE', 'treasurer@example.org', '2026-09-09 11:00:00', NULL),
    ('Budget 2027 Base', NULL,        3, 'APPROVED', 'APPROVE', 'director@example.org',  '2026-09-10 16:00:00', 'Approved as official 2027')
) AS v (SCEN, PK, STEP, STATUS, ACTION, BY_USER, AT, CMT)
JOIN APP.T_D_SCENARIO s          ON s.SCENARIO_NAME = v.SCEN
JOIN APP.T_F_APPROVAL_REQUEST r  ON r.SCENARIO_ID = s.SCENARIO_ID AND EQUAL_NULL(r.PERIOD_KEY, v.PK);

-- B.11 Per-employee checks on the Oct request (made by step 2, the Treasurer): one checked,
--      one rejected, one still pending
INSERT INTO APP.T_F_APPROVAL_EMPLOYEE_CHECK (REQUEST_ID, EMPLOYEE_ID, CHECK_STATUS, CHECK_COMMENT, CHECKED_BY)
SELECT r.REQUEST_ID, e.EMPLOYEE_ID, v.STATUS, v.CMT, v.BY_USER
FROM (VALUES
    ('HR-KH-001', 'CHECKED',  NULL::TEXT,                             'treasurer@example.org'),
    ('HR-FR-002', 'REJECTED', 'Overtime day not supported by a form', 'treasurer@example.org'),
    ('HR-KH-003', 'PENDING',  NULL,                                   NULL)
) AS v (RC, STATUS, CMT, BY_USER)
JOIN APP.T_D_SCENARIO s          ON s.SCENARIO_NAME = 'Actual payroll'
JOIN APP.T_F_APPROVAL_REQUEST r  ON r.SCENARIO_ID = s.SCENARIO_ID AND r.PERIOD_KEY = 202610
JOIN APP.T_D_EMPLOYEE e          ON e.RESOURCE_CODE = v.RC;

-- B.12 One change log entry (the Oct absence edit)
INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY)
SELECT 'APP.T_F_PAYROLL_INPUT',
       OBJECT_CONSTRUCT('SCENARIO_ID', s.SCENARIO_ID, 'PERIOD_KEY', 202610, 'EMPLOYEE_ID', e.EMPLOYEE_ID),
       'UPDATE',
       OBJECT_CONSTRUCT('ABSENCE_DAYS', 0),
       OBJECT_CONSTRUCT('ABSENCE_DAYS', 2),
       'clerk@example.org'
FROM APP.T_D_SCENARIO s
JOIN APP.T_D_EMPLOYEE e ON e.RESOURCE_CODE = 'HR-KH-001'
WHERE s.SCENARIO_NAME = 'Actual payroll';

-- B.13 Fact lines for HR-KH-001, Sep and Oct 2026 (normally written by the calculation)
--      Sep: no absence, NBC 4080.  Oct: 2 days unpaid leave, NBC 4085.  NSSF rate 4050.
INSERT INTO CORE.T_F_PAYROLL_LINE
    (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, PAY_COMPONENT_CODE, EMPLOYEE_VERSION_KEY, ENTITY_CODE,
     QUANTITY, RATE, AMOUNT_USD, AMOUNT_KHR, FX_RATE_APPLIED, CALCULATION_ID)
SELECT s.SCENARIO_ID, v.PK, e.EMPLOYEE_ID, v.COMP, c.CONTRACT_ID, 'ECCC',
       v.QTY, v.RATE, v.USD, v.KHR, v.FX, 'DUMMY-' || v.PK
FROM (VALUES
    (202609, 'BASE_SALARY',      NULL::FLOAT, NULL::FLOAT, 1000.00, 4080000, 4080),
    (202609, 'NSSF_BASE',        NULL,        NULL,        296.30,  1200000, 4050),
    (202609, 'NSSF_EE_PENSION',  NULL,        0.02,        5.88,    24000,   4080),
    (202609, 'NSSF_ER_PENSION',  NULL,        0.02,        5.88,    24000,   4080),
    (202609, 'NSSF_ER_HEALTH',   NULL,        0.026,       7.65,    31200,   4080),
    (202609, 'NSSF_ER_ORC',      NULL,        0.008,       2.35,    9600,    4080),
    (202609, 'TAXABLE_BASE',     NULL,        NULL,        994.12,  4056000, 4080),
    (202609, 'DEPENDANT_RELIEF', 2,           150000,      73.53,   300000,  4080),
    (202609, 'TAX_CALC_BASE',    NULL,        NULL,        920.59,  3756000, 4080),
    (202609, 'SALARY_TAX',       NULL,        0.10,        49.17,   200600,  4080),
    (202609, 'INSURANCE',        NULL,        NULL,        30.00,   122400,  4080),
    (202610, 'BASE_SALARY',      NULL,        NULL,        1000.00, 4085000, 4085),
    (202610, 'UNPAID_LEAVE',     2,           45.4545,     -90.91,  -371364, 4085),
    (202610, 'NSSF_BASE',        NULL,        NULL,        296.30,  1200000, 4050),
    (202610, 'NSSF_EE_PENSION',  NULL,        0.02,        5.88,    24000,   4085),
    (202610, 'NSSF_ER_PENSION',  NULL,        0.02,        5.88,    24000,   4085),
    (202610, 'NSSF_ER_HEALTH',   NULL,        0.026,       7.64,    31200,   4085),
    (202610, 'NSSF_ER_ORC',      NULL,        0.008,       2.35,    9600,    4085),
    (202610, 'TAXABLE_BASE',     NULL,        NULL,        903.22,  3689636, 4085),
    (202610, 'DEPENDANT_RELIEF', 2,           150000,      73.44,   300000,  4085),
    (202610, 'TAX_CALC_BASE',    NULL,        NULL,        829.78,  3389636, 4085),
    (202610, 'SALARY_TAX',       NULL,        0.10,        40.14,   163964,  4085),
    (202610, 'INSURANCE',        NULL,        NULL,        30.00,   122550,  4085)
) AS v (PK, COMP, QTY, RATE, USD, KHR, FX)
JOIN APP.T_D_SCENARIO s ON s.SCENARIO_NAME = 'Actual payroll'
JOIN APP.T_D_EMPLOYEE e ON e.RESOURCE_CODE = 'HR-KH-001'
JOIN APP.T_D_EMPLOYEE_CONTRACT c
  ON c.EMPLOYEE_ID = e.EMPLOYEE_ID
 AND v.PK BETWEEN c.VALID_FROM_PERIOD_KEY AND COALESCE(c.VALID_TO_PERIOD_KEY, 999912);

-- B.14 Cost allocation for HR-KH-001, Oct 2026 (ECCC 100% x Admin 60% / Advocacy 40%)
INSERT INTO CORE.T_F_COST_ALLOCATION
    (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, FUND_CODE, DEPARTMENT_CODE, ENTITY_CODE,
     ALLOCATION_SHARE, GROSS_PAY_USD, EMPLOYER_COST_USD, CALCULATION_ID)
SELECT s.SCENARIO_ID, 202610, e.EMPLOYEE_ID, 'ECCC', v.DEPT, 'ECCC', v.SHARE, v.GROSS, v.COST, 'DUMMY-202610'
FROM (VALUES
    ('ADMIN',    0.6, 545.45, 572.98),
    ('ADVOCACY', 0.4, 363.64, 381.98)
) AS v (DEPT, SHARE, GROSS, COST)
JOIN APP.T_D_SCENARIO s ON s.SCENARIO_NAME = 'Actual payroll'
JOIN APP.T_D_EMPLOYEE e ON e.RESOURCE_CODE = 'HR-KH-001';

/* =====================================================================================
   PART C - CHECKS (run and review the results)
   ===================================================================================== */

-- C.1 Periods: expect 192 rows, 202001 to 203512, NO_GAPS = TRUE
SELECT COUNT(*)                                                         AS PERIOD_COUNT,
       MIN(PERIOD_KEY)                                                  AS FIRST_PERIOD,
       MAX(PERIOD_KEY)                                                  AS LAST_PERIOD,
       COUNT(*) = DATEDIFF(MONTH, MIN(PERIOD_START_DATE), MAX(PERIOD_START_DATE)) + 1 AS NO_GAPS,
       COUNT(*) = COUNT(DISTINCT PERIOD_KEY)                            AS NO_DUPLICATES
FROM CORE.T_D_PERIOD;

-- C.2 Any missing months between the first and last period (expect no rows)
SELECT DATEADD(MONTH, 1, PERIOD_START_DATE) AS MISSING_AFTER
FROM CORE.T_D_PERIOD
QUALIFY LEAD(PERIOD_START_DATE) OVER (ORDER BY PERIOD_START_DATE) <> DATEADD(MONTH, 1, PERIOD_START_DATE);

-- C.3 Row counts per table
SELECT 'CORE.T_D_PERIOD'                 AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM CORE.T_D_PERIOD                UNION ALL
SELECT 'CORE.T_D_ENTITY',                 COUNT(*) FROM CORE.T_D_ENTITY                 UNION ALL
SELECT 'CORE.T_D_FUND',                   COUNT(*) FROM CORE.T_D_FUND                   UNION ALL
SELECT 'CORE.T_D_DEPARTMENT',             COUNT(*) FROM CORE.T_D_DEPARTMENT             UNION ALL
SELECT 'CORE.T_D_PAY_COMPONENT',          COUNT(*) FROM CORE.T_D_PAY_COMPONENT          UNION ALL
SELECT 'CORE.T_P_STATUTORY_PARAMETER',    COUNT(*) FROM CORE.T_P_STATUTORY_PARAMETER    UNION ALL
SELECT 'CORE.T_P_TAX_BRACKET',            COUNT(*) FROM CORE.T_P_TAX_BRACKET            UNION ALL
SELECT 'CORE.T_P_FX_RATE',                COUNT(*) FROM CORE.T_P_FX_RATE                UNION ALL
SELECT 'CORE.T_P_APPROVAL_STEP',          COUNT(*) FROM CORE.T_P_APPROVAL_STEP          UNION ALL
SELECT 'APP.T_D_APP_USER',                COUNT(*) FROM APP.T_D_APP_USER                UNION ALL
SELECT 'APP.T_D_APP_USER_ROLE',           COUNT(*) FROM APP.T_D_APP_USER_ROLE           UNION ALL
SELECT 'APP.T_D_SCENARIO',                COUNT(*) FROM APP.T_D_SCENARIO                UNION ALL
SELECT 'APP.T_D_EMPLOYEE',                COUNT(*) FROM APP.T_D_EMPLOYEE                UNION ALL
SELECT 'APP.T_D_EMPLOYEE_CONTRACT',       COUNT(*) FROM APP.T_D_EMPLOYEE_CONTRACT       UNION ALL
SELECT 'APP.T_D_SCENARIO_EMPLOYEE',       COUNT(*) FROM APP.T_D_SCENARIO_EMPLOYEE       UNION ALL
SELECT 'APP.T_F_SCENARIO_PERIOD',         COUNT(*) FROM APP.T_F_SCENARIO_PERIOD         UNION ALL
SELECT 'APP.T_F_PAYROLL_INPUT',           COUNT(*) FROM APP.T_F_PAYROLL_INPUT           UNION ALL
SELECT 'APP.T_F_FUND_ALLOCATION',         COUNT(*) FROM APP.T_F_FUND_ALLOCATION         UNION ALL
SELECT 'APP.T_F_DEPARTMENT_ALLOCATION',   COUNT(*) FROM APP.T_F_DEPARTMENT_ALLOCATION   UNION ALL
SELECT 'APP.T_F_PAYROLL_ADJUSTMENT',      COUNT(*) FROM APP.T_F_PAYROLL_ADJUSTMENT      UNION ALL
SELECT 'APP.T_F_APPROVAL_REQUEST',        COUNT(*) FROM APP.T_F_APPROVAL_REQUEST        UNION ALL
SELECT 'APP.T_F_APPROVAL_STEP_STATE',     COUNT(*) FROM APP.T_F_APPROVAL_STEP_STATE     UNION ALL
SELECT 'APP.T_F_APPROVAL_EMPLOYEE_CHECK', COUNT(*) FROM APP.T_F_APPROVAL_EMPLOYEE_CHECK UNION ALL
SELECT 'APP.T_F_CHANGE_LOG',              COUNT(*) FROM APP.T_F_CHANGE_LOG              UNION ALL
SELECT 'CORE.T_F_PAYROLL_LINE',           COUNT(*) FROM CORE.T_F_PAYROLL_LINE           UNION ALL
SELECT 'CORE.T_F_COST_ALLOCATION',        COUNT(*) FROM CORE.T_F_COST_ALLOCATION;
-- Expected: PERIOD 192, ENTITY 2, FUND 3, DEPARTMENT 7, PAY_COMPONENT 20, STATUTORY_PARAMETER 11,
-- TAX_BRACKET 5, FX_RATE 4, APPROVAL_STEP 3, APP_USER 5, APP_USER_ROLE 5, SCENARIO 4, EMPLOYEE 5,
-- EMPLOYEE_CONTRACT 5, SCENARIO_EMPLOYEE 10, SCENARIO_PERIOD 29, PAYROLL_INPUT 10,
-- FUND_ALLOCATION 4, DEPARTMENT_ALLOCATION 4, PAYROLL_ADJUSTMENT 1, APPROVAL_REQUEST 3,
-- APPROVAL_STEP_STATE 9, APPROVAL_EMPLOYEE_CHECK 3, CHANGE_LOG 1, PAYROLL_LINE 23, COST_ALLOCATION 2

-- C.4 Payroll summary for the dummy employee
--     Expected Sep: gross 1000.00, net 944.95, employer cost 1045.88
--     Expected Oct: gross  909.09, net 863.07, employer cost  954.96
SELECT PERIOD_KEY, EMPLOYEE_ID, GROSS_PAY_USD, NSSF_EE_USD, SALARY_TAX_USD, NET_PAY_USD,
       NSSF_ER_USD, OTHER_EMPLOYER_COST_USD, EMPLOYER_COST_USD
FROM CORE.V_F_PAYROLL_SUMMARY
ORDER BY PERIOD_KEY;

-- C.5 Approval progress (Oct should show step 1 APPROVED, step 2 as the next step)
SELECT REQUEST_ID, PERIOD_KEY, STEP_ORDER, STEP_TITLE, STEP_STATUS, ACTED_BY, IS_NEXT_STEP
FROM RPT.V_F_APPROVAL_PROGRESS
ORDER BY REQUEST_ID, STEP_ORDER;

-- End of script
