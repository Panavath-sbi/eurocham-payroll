/* =====================================================================================
   V_F_SCENARIO_PERIOD - Each month of each scenario with its status and the working days and rates applied to it
   =====================================================================================

   HISTORY
   -------
   2026-10-05  Initial version: V_D_PERIOD, V_F_SCENARIO_PERIOD, V_F_PAYROLL_INPUT,
               V_F_ALLOCATION, V_D_SCENARIO_EMPLOYEE, V_F_PAYROLL_LINE, V_D_LOOKUP,
               V_P_APPROVAL_STEP, V_D_APP_USER.
   2026-10-19  Own file for DLSync (was in R__views_rpt_app.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.

   NOTES
   -----
   * No view here contains bank details or signature images: every app user reads through
     the same Snowflake connection, so anything in a view is visible to all of them.
   * Column comments: views inherit the meaning of the APP columns they show; only new or
     calculated columns are described.
   ===================================================================================== */
/* -------------------------------------------------------------------------------------
   Months of a scenario: period dropdown, FX card, open-month logic
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW ${DB}.RPT.V_F_SCENARIO_PERIOD (
    SCENARIO_ID, SCENARIO_TYPE, SCENARIO_NAME, PERIOD_KEY, PERIOD_LABEL, YEAR, MONTH_NUMBER,
    PERIOD_STATUS,
    IS_OPEN COMMENT 'TRUE for the actual month that can still be edited or approved (OPEN or IN_APPROVAL)',
    WORKING_DAYS, FX_RATE_NBC, FX_RATE_NSSF, FINALIZED_AT, FINALIZED_BY
)
COPY GRANTS
COMMENT = 'Each month of each scenario with its status and the working days and rates applied to it.'
AS
SELECT
    sp.SCENARIO_ID,
    s.SCENARIO_TYPE,
    s.SCENARIO_NAME,
    sp.PERIOD_KEY,
    p.PERIOD_LABEL,
    p.YEAR,
    p.MONTH_NUMBER,
    sp.PERIOD_STATUS,
    sp.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'),
    sp.WORKING_DAYS,
    sp.FX_RATE_NBC,
    sp.FX_RATE_NSSF,
    sp.FINALIZED_AT,
    sp.FINALIZED_BY
FROM ${DB}.APP.T_F_SCENARIO_PERIOD sp
JOIN ${DB}.APP.T_D_SCENARIO s ON s.SCENARIO_ID = sp.SCENARIO_ID
JOIN ${DB}.APP.T_D_PERIOD p   ON p.PERIOD_KEY = sp.PERIOD_KEY;
