/* =====================================================================================
   V_F_BUDGET_VS_ACTUAL - Per period and entity: official budget vs latest forecast vs actual employer cost and gross pay
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-19  Own file for DLSync (was in R__views_rpt.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.
   ===================================================================================== */
CREATE OR REPLACE VIEW ${DB}.RPT.V_F_BUDGET_VS_ACTUAL
COPY GRANTS
COMMENT = 'Per period and entity: official budget vs latest forecast vs actual employer cost and gross pay.'
AS
WITH sources AS (
    SELECT SCENARIO_ID, 'ACTUAL' AS SOURCE
    FROM ${DB}.APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'ACTUAL'
    UNION ALL
    SELECT SCENARIO_ID, 'BUDGET'
    FROM ${DB}.APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'BUDGET' AND IS_OFFICIAL
    UNION ALL
    SELECT SCENARIO_ID, 'FORECAST'
    FROM (
        SELECT SCENARIO_ID
        FROM ${DB}.APP.T_D_SCENARIO
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
FROM ${DB}.RPT.V_F_PAYROLL_SUMMARY f
JOIN sources src       ON src.SCENARIO_ID = f.SCENARIO_ID
JOIN ${DB}.APP.T_D_PERIOD p ON p.PERIOD_KEY = f.PERIOD_KEY
GROUP BY p.YEAR, f.PERIOD_KEY, p.PERIOD_LABEL, f.ENTITY_CODE;
