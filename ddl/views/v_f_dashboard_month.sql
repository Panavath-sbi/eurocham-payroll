
CREATE OR REPLACE VIEW RPT.V_F_DASHBOARD_MONTH 
(
    PERIOD_KEY, 
    YEAR, 
    MONTH_NUMBER, 
    PERIOD_LABEL,
    SHORT_LABEL        COMMENT 'Chart label, e.g. Oct''26',
    HEADCOUNT          COMMENT 'Employees paid in the actual payroll that month',
    HEADCOUNT_ECCC, 
    HEADCOUNT_CCIFC,
    GROSS_USD, 
    GROSS_ECCC_USD, 
    GROSS_CCIFC_USD,
    NSSF_EE_USD        COMMENT 'Employee NSSF (pension)',
    NSSF_ER_USD        COMMENT 'Employer NSSF (pension, healthcare, occupational risk)',
    NSSF_USD           COMMENT 'Employee + employer NSSF',
    NSSF_ECCC_USD, 
    NSSF_CCIFC_USD,
    NET_USD            COMMENT 'Net pay to bank',
    NET_ECCC_USD, 
    NET_CCIFC_USD,
    TOS_USD            COMMENT 'Salary tax withheld, USD',
    TOS_KHR            COMMENT 'Salary tax withheld, KHR (as calculated)',
    TOS_ECCC_KHR, 
    TOS_CCIFC_KHR,
    FX_RATE_NBC        COMMENT 'NBC rate applied to the actual month (else the published rate)',
    BUDGET_GROSS_USD   COMMENT 'Gross pay of the official budget of that year',
    FORECAST_GROSS_USD COMMENT 'Gross pay of the latest forecast of that year'
)
COMMENT = 'Dashboard figures per calendar month: actual totals (total and per chamber), applied NBC rate, official budget and latest forecast gross pay.'
AS
WITH act AS (
    SELECT 
           s.PERIOD_KEY,
           COUNT(DISTINCT s.EMPLOYEE_ID)                                        AS HC,
           COUNT(DISTINCT IFF(s.ENTITY_CODE = 'ECCC',  s.EMPLOYEE_ID, NULL))    AS HC_E,
           COUNT(DISTINCT IFF(s.ENTITY_CODE = 'CCIFC', s.EMPLOYEE_ID, NULL))    AS HC_C,
           SUM(s.GROSS_PAY_USD)                                                 AS GROSS,
           SUM(IFF(s.ENTITY_CODE = 'ECCC',  s.GROSS_PAY_USD, 0))                AS GROSS_E,
           SUM(IFF(s.ENTITY_CODE = 'CCIFC', s.GROSS_PAY_USD, 0))                AS GROSS_C,
           SUM(s.NSSF_EE_USD)                                                   AS EE,
           SUM(s.NSSF_ER_USD)                                                   AS ER,
           SUM(IFF(s.ENTITY_CODE = 'ECCC',  s.NSSF_EE_USD + s.NSSF_ER_USD, 0))  AS NSSF_E,
           SUM(IFF(s.ENTITY_CODE = 'CCIFC', s.NSSF_EE_USD + s.NSSF_ER_USD, 0))  AS NSSF_C,
           SUM(s.NET_PAY_USD)                                                   AS NET,
           SUM(IFF(s.ENTITY_CODE = 'ECCC',  s.NET_PAY_USD, 0))                  AS NET_E,
           SUM(IFF(s.ENTITY_CODE = 'CCIFC', s.NET_PAY_USD, 0))                  AS NET_C,
           SUM(s.SALARY_TAX_USD)                                                AS TOS_U,
           SUM(s.SALARY_TAX_KHR)                                                AS TOS_K,
           SUM(IFF(s.ENTITY_CODE = 'ECCC',  s.SALARY_TAX_KHR, 0))               AS TOS_E,
           SUM(IFF(s.ENTITY_CODE = 'CCIFC', s.SALARY_TAX_KHR, 0))               AS TOS_C
    FROM RPT.V_F_PAYROLL_SUMMARY s
    JOIN APP.T_D_SCENARIO sc ON sc.SCENARIO_ID = s.SCENARIO_ID AND sc.SCENARIO_TYPE = 'ACTUAL'
    GROUP BY s.PERIOD_KEY
),
plan AS (
    SELECT PERIOD_KEY,
           SUM(BUDGET_GROSS_PAY_USD)   AS BUD,
           SUM(FORECAST_GROSS_PAY_USD) AS FCST
    FROM RPT.V_F_BUDGET_VS_ACTUAL
    GROUP BY PERIOD_KEY
),
actual_scenario AS (
    SELECT MIN(SCENARIO_ID) AS SCENARIO_ID FROM APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'ACTUAL'
)
SELECT
    p.PERIOD_KEY,
    p.YEAR,
    p.MONTH_NUMBER,
    p.PERIOD_LABEL,
    LEFT(p.MONTH_NAME, 3) || '''' || RIGHT(p.YEAR::TEXT, 2),
    COALESCE(a.HC, 0), COALESCE(a.HC_E, 0), COALESCE(a.HC_C, 0),
    ROUND(COALESCE(a.GROSS, 0), 2), ROUND(COALESCE(a.GROSS_E, 0), 2), ROUND(COALESCE(a.GROSS_C, 0), 2),
    ROUND(COALESCE(a.EE, 0), 2), ROUND(COALESCE(a.ER, 0), 2), ROUND(COALESCE(a.EE + a.ER, 0), 2),
    ROUND(COALESCE(a.NSSF_E, 0), 2), ROUND(COALESCE(a.NSSF_C, 0), 2),
    ROUND(COALESCE(a.NET, 0), 2), ROUND(COALESCE(a.NET_E, 0), 2), ROUND(COALESCE(a.NET_C, 0), 2),
    ROUND(COALESCE(a.TOS_U, 0), 2), ROUND(COALESCE(a.TOS_K, 0), 0),
    ROUND(COALESCE(a.TOS_E, 0), 0), ROUND(COALESCE(a.TOS_C, 0), 0),
    COALESCE(sp.FX_RATE_NBC, p.FX_RATE_NBC),
    ROUND(COALESCE(pl.BUD, 0), 2), ROUND(COALESCE(pl.FCST, 0), 2)
FROM APP.T_D_PERIOD p
CROSS JOIN actual_scenario x
LEFT JOIN act a   ON a.PERIOD_KEY = p.PERIOD_KEY
LEFT JOIN plan pl ON pl.PERIOD_KEY = p.PERIOD_KEY
LEFT JOIN APP.T_F_SCENARIO_PERIOD sp ON sp.SCENARIO_ID = x.SCENARIO_ID AND sp.PERIOD_KEY = p.PERIOD_KEY;
