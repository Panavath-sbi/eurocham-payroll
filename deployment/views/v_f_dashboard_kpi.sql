-- depends_on: T_F_SCENARIO_PERIOD, T_D_SCENARIO, V_F_PAYROLL_SUMMARY, T_D_PERIOD
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_F_DASHBOARD_KPI - Dashboard cards for the latest actual period, per entity plus an ALL total row
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-19  Own file for DLSync (was in R__views_rpt.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.
   ===================================================================================== */
CREATE OR REPLACE VIEW {{ schema_rpt }}.V_F_DASHBOARD_KPI
COPY GRANTS
COMMENT = 'Dashboard cards for the latest actual period, per entity plus an ALL total row.'
AS
WITH latest AS (
    SELECT sp.SCENARIO_ID, MAX(sp.PERIOD_KEY) AS PERIOD_KEY
    FROM {{ schema_app }}.T_F_SCENARIO_PERIOD sp
    JOIN {{ schema_app }}.T_D_SCENARIO s ON s.SCENARIO_ID = sp.SCENARIO_ID AND s.SCENARIO_TYPE = 'ACTUAL'
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
FROM {{ schema_rpt }}.V_F_PAYROLL_SUMMARY f
JOIN latest l                   ON l.SCENARIO_ID = f.SCENARIO_ID AND l.PERIOD_KEY = f.PERIOD_KEY
JOIN {{ schema_app }}.T_F_SCENARIO_PERIOD sp ON sp.SCENARIO_ID = f.SCENARIO_ID AND sp.PERIOD_KEY = f.PERIOD_KEY
JOIN {{ schema_app }}.T_D_PERIOD p          ON p.PERIOD_KEY = f.PERIOD_KEY
GROUP BY GROUPING SETS (
    (f.PERIOD_KEY, p.PERIOD_LABEL, sp.PERIOD_STATUS, f.ENTITY_CODE),
    (f.PERIOD_KEY, p.PERIOD_LABEL, sp.PERIOD_STATUS)
);
