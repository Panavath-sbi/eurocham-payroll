/* =====================================================================================
   V_D_SCENARIO - Scenario dimension for reporting: actual payroll, budget scenarios and forecast versions
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-19  Own file for DLSync (was in R__views_core.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.
   ===================================================================================== */
CREATE OR REPLACE VIEW ${DB}.RPT.V_D_SCENARIO
COPY GRANTS
COMMENT = 'Scenario dimension for reporting: actual payroll, budget scenarios and forecast versions.'
AS
SELECT
    SCENARIO_ID,
    SCENARIO_TYPE,
    SCENARIO_NAME,
    FISCAL_YEAR,
    SCENARIO_STATUS,
    IS_OFFICIAL,
    BASE_SCENARIO_ID,
    FORECAST_AS_OF_PERIOD_KEY,
    DESCRIPTION
FROM ${DB}.APP.T_D_SCENARIO;
