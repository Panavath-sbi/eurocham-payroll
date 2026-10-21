-- depends_on: {{ ref('v_f_payroll_summary') }}, {{ ref('t_d_scenario') }}, {{ ref('t_d_period') }}
/* =====================================================================================
   V_F_SCENARIO_SUMMARY - Monthly totals per scenario and entity
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-19  Own file for DLSync (was in R__views_rpt.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.
   ===================================================================================== */
CREATE OR REPLACE VIEW V_F_SCENARIO_SUMMARY
COPY GRANTS
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
FROM V_F_PAYROLL_SUMMARY f
JOIN T_D_SCENARIO s ON s.SCENARIO_ID = f.SCENARIO_ID
JOIN T_D_PERIOD p  ON p.PERIOD_KEY = f.PERIOD_KEY
GROUP BY s.SCENARIO_ID, s.SCENARIO_TYPE, s.SCENARIO_NAME, s.SCENARIO_STATUS, s.IS_OFFICIAL,
         p.YEAR, f.PERIOD_KEY, p.PERIOD_LABEL, f.ENTITY_CODE;
