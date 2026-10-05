/* =====================================================================================
   R - RPT REPORTING VIEWS
   Dashboard, scenario summary, budget vs actual, cost center, approval progress.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-02  V_F_APPROVAL_PROGRESS reads APP.T_F_APPROVAL_STEP_STATE (one row per step)
               instead of the dropped action log; adds LAST_ACTION and MANAGES_EMPLOYEE_CHECKS.
   2026-10-02  V1.5.0: base views and tables referenced in RPT / APP (CORE removed).
               V_F_COST_CENTER_SUMMARY reads RPT.V_F_COST_ALLOCATION. V_F_APPROVAL_PROGRESS
               reads APP.T_F_APPROVAL by scenario + period (no request id): REQUEST_ID and
               REQUEST_STATUS are replaced by SCENARIO_TYPE, APPROVAL_STATUS (the month's
               or the budget's status) and IS_IN_PROGRESS; ACTION_COMMENT is now STEP_COMMENT.
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
FROM RPT.V_F_PAYROLL_SUMMARY f
JOIN latest l                   ON l.SCENARIO_ID = f.SCENARIO_ID AND l.PERIOD_KEY = f.PERIOD_KEY
JOIN APP.T_F_SCENARIO_PERIOD sp ON sp.SCENARIO_ID = f.SCENARIO_ID AND sp.PERIOD_KEY = f.PERIOD_KEY
JOIN APP.T_D_PERIOD p          ON p.PERIOD_KEY = f.PERIOD_KEY
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
FROM RPT.V_F_PAYROLL_SUMMARY f
JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = f.SCENARIO_ID
JOIN APP.T_D_PERIOD p  ON p.PERIOD_KEY = f.PERIOD_KEY
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
FROM RPT.V_F_PAYROLL_SUMMARY f
JOIN sources src       ON src.SCENARIO_ID = f.SCENARIO_ID
JOIN APP.T_D_PERIOD p ON p.PERIOD_KEY = f.PERIOD_KEY
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
FROM RPT.V_F_COST_ALLOCATION a
JOIN APP.T_D_PERIOD p      ON p.PERIOD_KEY = a.PERIOD_KEY
JOIN APP.T_D_FUND fu       ON fu.FUND_CODE = a.FUND_CODE
JOIN APP.T_D_DEPARTMENT d  ON d.DEPARTMENT_CODE = a.DEPARTMENT_CODE
GROUP BY a.SCENARIO_ID, a.PERIOD_KEY, p.PERIOD_LABEL, a.ENTITY_CODE,
         a.FUND_CODE, fu.FUND_NAME, a.DEPARTMENT_CODE, d.DEPARTMENT_NAME;

CREATE OR REPLACE VIEW RPT.V_F_APPROVAL_PROGRESS
COMMENT = 'Every step of every approval (each payroll month, each submitted budget with PERIOD_KEY 0), its current state, and the next step to act on.'
AS
WITH item AS (   -- each approval: a payroll month, or a whole budget (period 0)
    SELECT DISTINCT a.SCENARIO_ID, a.PERIOD_KEY
    FROM APP.T_F_APPROVAL a
),
src AS (
    SELECT i.SCENARIO_ID, i.PERIOD_KEY, s.SCENARIO_TYPE,
           IFF(s.SCENARIO_TYPE = 'ACTUAL', sp.PERIOD_STATUS, s.SCENARIO_STATUS)         AS APPROVAL_STATUS,
           IFF(s.SCENARIO_TYPE = 'ACTUAL', sp.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'),
                                           s.SCENARIO_STATUS = 'IN_APPROVAL')           AS IS_IN_PROGRESS,
           IFF(i.PERIOD_KEY = 0, s.FISCAL_YEAR * 100 + 1, i.PERIOD_KEY)                 AS STEP_PERIOD_KEY
    FROM item i
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = i.SCENARIO_ID
    LEFT JOIN APP.T_F_SCENARIO_PERIOD sp ON sp.SCENARIO_ID = i.SCENARIO_ID AND sp.PERIOD_KEY = i.PERIOD_KEY
),
steps AS (       -- the step definitions in force for that month / budget year
    SELECT src.*, st.STEP_ORDER, st.STEP_TITLE, st.APPROVER_ROLE,
           (COALESCE(st.MANAGES_EMPLOYEE_CHECKS, FALSE) AND src.SCENARIO_TYPE = 'ACTUAL') AS MANAGES_EMPLOYEE_CHECKS
    FROM src
    JOIN APP.T_P_APPROVAL_STEP st
      ON st.IS_ACTIVE
     AND st.APPLIES_TO IN ('ALL', src.SCENARIO_TYPE)
     AND src.STEP_PERIOD_KEY BETWEEN st.VALID_FROM_PERIOD_KEY AND COALESCE(st.VALID_TO_PERIOD_KEY, 999912)
),
state AS (       -- a step without a row in T_F_APPROVAL counts as PENDING
    SELECT s.*,
           COALESCE(a.STEP_STATUS, 'PENDING') AS STEP_STATUS,
           a.LAST_ACTION, a.ACTED_BY, a.ACTED_AT, a.STEP_COMMENT
    FROM steps s
    LEFT JOIN APP.T_F_APPROVAL a
           ON a.SCENARIO_ID = s.SCENARIO_ID AND a.PERIOD_KEY = s.PERIOD_KEY AND a.STEP_ORDER = s.STEP_ORDER
)
SELECT
    SCENARIO_ID, PERIOD_KEY, SCENARIO_TYPE, APPROVAL_STATUS, IS_IN_PROGRESS,
    STEP_ORDER, STEP_TITLE, APPROVER_ROLE,
    STEP_STATUS, LAST_ACTION, ACTED_BY, ACTED_AT, STEP_COMMENT,
    STEP_ORDER = MIN(IFF(STEP_STATUS <> 'APPROVED', STEP_ORDER, NULL))
                 OVER (PARTITION BY SCENARIO_ID, PERIOD_KEY)                       AS IS_NEXT_STEP,
    MANAGES_EMPLOYEE_CHECKS
FROM state;
