CREATE OR REPLACE VIEW RPT.V_P_STATUTORY_PARAMETER 
(
    PERIOD_KEY            COMMENT 'Month the value applies to',
    PARAM_CODE,
    PARAM_GROUP           COMMENT 'Heading in the app: NSSF, Salary tax or Other',
    SORT_ORDER            COMMENT 'Display order in the app',
    PARAM_LABEL           COMMENT 'Display name in the app',
    PARAM_VALUE,
    UNIT,
    VALID_FROM_PERIOD_KEY COMMENT 'Month this value started (shown as "Since")'
)
COMMENT = 'Statutory parameters in force in each month, with display labels: Monthly Inputs dialog.'
AS
SELECT
    p.PERIOD_KEY,
    sp.PARAM_CODE,
    CASE
        WHEN sp.PARAM_CODE LIKE 'NSSF%' THEN 'NSSF'
        WHEN sp.PARAM_CODE IN ('DEPENDANT_ALLOWANCE_KHR', 'TAX_NON_RESIDENT_RATE', 'SENIORITY_TAX_EXEMPT_KHR') THEN 'Salary tax'
        ELSE 'Other'
    END,
    CASE sp.PARAM_CODE
        WHEN 'NSSF_EE_PENSION_RATE'       THEN 1
        WHEN 'NSSF_ER_PENSION_RATE'       THEN 2
        WHEN 'NSSF_HEALTH_RATE'           THEN 3
        WHEN 'NSSF_ORC_RATE'              THEN 4
        WHEN 'NSSF_BASE_FLOOR_KHR'        THEN 5
        WHEN 'NSSF_BASE_CAP_KHR'          THEN 6
        WHEN 'DEPENDANT_ALLOWANCE_KHR'    THEN 7
        WHEN 'TAX_NON_RESIDENT_RATE'      THEN 8
        WHEN 'SENIORITY_TAX_EXEMPT_KHR'   THEN 9
        WHEN 'SENIORITY_DAYS_PER_PAYMENT' THEN 10
        WHEN 'OVERTIME_MULTIPLIER'        THEN 11
        ELSE 99
    END,
    CASE sp.PARAM_CODE
        WHEN 'NSSF_EE_PENSION_RATE'       THEN 'Employee pension rate'
        WHEN 'NSSF_ER_PENSION_RATE'       THEN 'Employer pension rate'
        WHEN 'NSSF_HEALTH_RATE'           THEN 'Health care rate (employer)'
        WHEN 'NSSF_ORC_RATE'              THEN 'Occupational risk rate (employer)'
        WHEN 'NSSF_BASE_FLOOR_KHR'        THEN 'Contribution base - minimum'
        WHEN 'NSSF_BASE_CAP_KHR'          THEN 'Contribution base - maximum'
        WHEN 'DEPENDANT_ALLOWANCE_KHR'    THEN 'Dependant allowance'
        WHEN 'TAX_NON_RESIDENT_RATE'      THEN 'Non-resident flat rate'
        WHEN 'SENIORITY_TAX_EXEMPT_KHR'   THEN 'Seniority exempt amount'
        WHEN 'SENIORITY_DAYS_PER_PAYMENT' THEN 'Seniority days per payment'
        WHEN 'OVERTIME_MULTIPLIER'        THEN 'Overtime multiplier'
        ELSE sp.PARAM_CODE
    END,
    sp.PARAM_VALUE,
    sp.UNIT,
    sp.VALID_FROM_PERIOD_KEY
FROM APP.T_D_PERIOD p
JOIN APP.T_P_STATUTORY_PARAMETER sp
  ON p.PERIOD_KEY BETWEEN sp.VALID_FROM_PERIOD_KEY AND COALESCE(sp.VALID_TO_PERIOD_KEY, 999912);
