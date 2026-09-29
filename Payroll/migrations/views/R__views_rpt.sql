/* =====================================================================================
   R - RPT REPORTING VIEWS
   Dashboard, scenario summary, budget vs actual, cost center, approval progress.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).
   ===================================================================================== */

/* =====================================================================================
   6. RPT - REPORTING VIEWS (V_F_)
   ===================================================================================== */

CREATE OR REPLACE VIEW RPT.V_F_DASHBOARD_KPI
COMMENT = 'Dashboard cards for the latest actual period, per entity plus an ALL total row.'
AS
WITH latest AS (
    SELECT sp.SCENARIO_ID, MAX(sp.PERIOD_KEY) AS PERIOD_KEY
    FROM APP.T_F_SCENARIO_PERIOD sp
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = sp.SCENARIO_ID AND s.SCENARIO_TYPE = 'ACTUAL'
    GROUP BY sp.SCENARIO_ID
)
SELECT
    f.PERIOD_KEY,
    p.PERIOD_LABEL,
    sp.PERIOD_STATUS,
    COALESCE(f.ENTITY_CODE, 'ALL')      AS ENTITY_CODE,
    COUNT(DISTINCT f.EMPLOYEE_ID)       AS HEADCOUNT,
    SUM(f.GROSS_PAY_USD)                AS GROSS_PAY_USD,
    SUM(f.NSSF_EE_USD)                  AS NSSF_EE_USD,
    SUM(f.NSSF_ER_USD)                  AS NSSF_ER_USD,
    SUM(f.SALARY_TAX_USD)               AS SALARY_TAX_USD,
    SUM(f.NET_PAY_USD)                  AS NET_PAY_USD,
    SUM(f.EMPLOYER_COST_USD)            AS EMPLOYER_COST_USD
FROM CORE.V_F_PAYROLL_SUMMARY f
JOIN latest l                   ON l.SCENARIO_ID = f.SCENARIO_ID AND l.PERIOD_KEY = f.PERIOD_KEY
JOIN APP.T_F_SCENARIO_PERIOD sp ON sp.SCENARIO_ID = f.SCENARIO_ID AND sp.PERIOD_KEY = f.PERIOD_KEY
JOIN CORE.T_D_PERIOD p          ON p.PERIOD_KEY = f.PERIOD_KEY
GROUP BY GROUPING SETS (
    (f.PERIOD_KEY, p.PERIOD_LABEL, sp.PERIOD_STATUS, f.ENTITY_CODE),
    (f.PERIOD_KEY, p.PERIOD_LABEL, sp.PERIOD_STATUS)
);

CREATE OR REPLACE VIEW RPT.V_F_SCENARIO_SUMMARY
COMMENT = 'Monthly totals per scenario and entity. Power Apps filters on SCENARIO_ID; no comparison logic in Snowflake.'
AS
SELECT
    s.SCENARIO_ID,
    s.SCENARIO_TYPE,
    s.SCENARIO_NAME,
    s.SCENARIO_STATUS,
    s.IS_OFFICIAL,
    p.YEAR,
    f.PERIOD_KEY,
    p.PERIOD_LABEL,
    f.ENTITY_CODE,
    COUNT(DISTINCT f.EMPLOYEE_ID)  AS HEADCOUNT,
    SUM(f.GROSS_PAY_USD)           AS GROSS_PAY_USD,
    SUM(f.NSSF_ER_USD)             AS NSSF_ER_USD,
    SUM(f.SALARY_TAX_USD)          AS SALARY_TAX_USD,
    SUM(f.NET_PAY_USD)             AS NET_PAY_USD,
    SUM(f.EMPLOYER_COST_USD)       AS EMPLOYER_COST_USD
FROM CORE.V_F_PAYROLL_SUMMARY f
JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = f.SCENARIO_ID
JOIN CORE.T_D_PERIOD p  ON p.PERIOD_KEY = f.PERIOD_KEY
GROUP BY s.SCENARIO_ID, s.SCENARIO_TYPE, s.SCENARIO_NAME, s.SCENARIO_STATUS, s.IS_OFFICIAL,
         p.YEAR, f.PERIOD_KEY, p.PERIOD_LABEL, f.ENTITY_CODE;

CREATE OR REPLACE VIEW RPT.V_F_BUDGET_VS_ACTUAL
COMMENT = 'Per period and entity: official budget vs latest forecast vs actual employer cost and gross pay.'
AS
WITH sources AS (
    SELECT SCENARIO_ID, 'ACTUAL' AS SOURCE
    FROM APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'ACTUAL'
    UNION ALL
    SELECT SCENARIO_ID, 'BUDGET'
    FROM APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'BUDGET' AND IS_OFFICIAL
    UNION ALL
    SELECT SCENARIO_ID, 'FORECAST'
    FROM (
        SELECT SCENARIO_ID
        FROM APP.T_D_SCENARIO
        WHERE SCENARIO_TYPE = 'FORECAST' AND SCENARIO_STATUS <> 'ARCHIVED'
        QUALIFY ROW_NUMBER() OVER (PARTITION BY FISCAL_YEAR
                                   ORDER BY FORECAST_AS_OF_PERIOD_KEY DESC, SCENARIO_ID DESC) = 1
    )
)
SELECT
    p.YEAR,
    f.PERIOD_KEY,
    p.PERIOD_LABEL,
    f.ENTITY_CODE,
    SUM(IFF(src.SOURCE = 'BUDGET',   f.EMPLOYER_COST_USD, 0)) AS BUDGET_EMPLOYER_COST_USD,
    SUM(IFF(src.SOURCE = 'FORECAST', f.EMPLOYER_COST_USD, 0)) AS FORECAST_EMPLOYER_COST_USD,
    SUM(IFF(src.SOURCE = 'ACTUAL',   f.EMPLOYER_COST_USD, 0)) AS ACTUAL_EMPLOYER_COST_USD,
    ACTUAL_EMPLOYER_COST_USD - BUDGET_EMPLOYER_COST_USD       AS VARIANCE_VS_BUDGET_USD,
    SUM(IFF(src.SOURCE = 'BUDGET',   f.GROSS_PAY_USD, 0))     AS BUDGET_GROSS_PAY_USD,
    SUM(IFF(src.SOURCE = 'FORECAST', f.GROSS_PAY_USD, 0))     AS FORECAST_GROSS_PAY_USD,
    SUM(IFF(src.SOURCE = 'ACTUAL',   f.GROSS_PAY_USD, 0))     AS ACTUAL_GROSS_PAY_USD
FROM CORE.V_F_PAYROLL_SUMMARY f
JOIN sources src       ON src.SCENARIO_ID = f.SCENARIO_ID
JOIN CORE.T_D_PERIOD p ON p.PERIOD_KEY = f.PERIOD_KEY
GROUP BY p.YEAR, f.PERIOD_KEY, p.PERIOD_LABEL, f.ENTITY_CODE;

CREATE OR REPLACE VIEW RPT.V_F_COST_CENTER_SUMMARY
COMMENT = 'Allocated cost per scenario, period, entity, fund and department.'
AS
SELECT
    a.SCENARIO_ID,
    a.PERIOD_KEY,
    p.PERIOD_LABEL,
    a.ENTITY_CODE,
    a.FUND_CODE,
    fu.FUND_NAME,
    a.DEPARTMENT_CODE,
    d.DEPARTMENT_NAME,
    COUNT(DISTINCT a.EMPLOYEE_ID)      AS EMPLOYEE_COUNT,
    ROUND(SUM(a.GROSS_PAY_USD), 2)     AS GROSS_PAY_USD,
    ROUND(SUM(a.EMPLOYER_COST_USD), 2) AS EMPLOYER_COST_USD
FROM CORE.T_F_COST_ALLOCATION a
JOIN CORE.T_D_PERIOD p      ON p.PERIOD_KEY = a.PERIOD_KEY
JOIN CORE.T_D_FUND fu       ON fu.FUND_CODE = a.FUND_CODE
JOIN CORE.T_D_DEPARTMENT d  ON d.DEPARTMENT_CODE = a.DEPARTMENT_CODE
GROUP BY a.SCENARIO_ID, a.PERIOD_KEY, p.PERIOD_LABEL, a.ENTITY_CODE,
         a.FUND_CODE, fu.FUND_NAME, a.DEPARTMENT_CODE, d.DEPARTMENT_NAME;

CREATE OR REPLACE VIEW RPT.V_F_APPROVAL_PROGRESS
COMMENT = 'Current state of every step of every approval request, with the next step to act on.'
AS
WITH req AS (
    SELECT r.*, s.SCENARIO_TYPE,
           COALESCE(r.PERIOD_KEY, s.FISCAL_YEAR * 100 + 1) AS STEP_PERIOD_KEY
    FROM APP.T_F_APPROVAL_REQUEST r
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = r.SCENARIO_ID
),
steps AS (
    SELECT req.REQUEST_ID, req.SCENARIO_ID, req.PERIOD_KEY, req.REQUEST_STATUS,
           st.STEP_ORDER, st.STEP_TITLE, st.APPROVER_ROLE
    FROM req
    JOIN CORE.T_P_APPROVAL_STEP st
      ON st.IS_ACTIVE
     AND st.APPLIES_TO IN ('ALL', req.SCENARIO_TYPE)
     AND req.STEP_PERIOD_KEY BETWEEN st.VALID_FROM_PERIOD_KEY AND COALESCE(st.VALID_TO_PERIOD_KEY, 999912)
),
last_action AS (
    SELECT *
    FROM APP.T_F_APPROVAL_ACTION
    QUALIFY ROW_NUMBER() OVER (PARTITION BY REQUEST_ID, STEP_ORDER
                               ORDER BY INSERT_DATE DESC, ACTION_ID DESC) = 1
),
state AS (
    SELECT s.*,
           CASE la.ACTION_TYPE WHEN 'APPROVE' THEN 'APPROVED'
                               WHEN 'REJECT'  THEN 'REJECTED'
                               ELSE 'PENDING' END AS STEP_STATUS,
           la.ACTED_BY,
           la.INSERT_DATE AS ACTED_AT,
           la.ACTION_COMMENT
    FROM steps s
    LEFT JOIN last_action la ON la.REQUEST_ID = s.REQUEST_ID AND la.STEP_ORDER = s.STEP_ORDER
)
SELECT
    state.*,
    STEP_ORDER = MIN(IFF(STEP_STATUS <> 'APPROVED', STEP_ORDER, NULL))
                 OVER (PARTITION BY REQUEST_ID)                     AS IS_NEXT_STEP
FROM state;
