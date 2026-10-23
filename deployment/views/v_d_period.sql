-- depends_on: T_D_PERIOD
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_D_PERIOD - Calendar months with working days (actual and budget calendars) and published NBC / NSSF rates
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
   Calendar: Settings (working days), Create Payroll (rates of the next month)
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW {{ schema_rpt }}.V_D_PERIOD
COPY GRANTS
COMMENT = 'Calendar months with working days (actual and budget calendars) and published NBC / NSSF rates.'
AS
SELECT
    PERIOD_KEY,
    PERIOD_LABEL,
    YEAR,
    MONTH_NUMBER,
    MONTH_NAME,
    QUARTER,
    IS_SENIORITY_MONTH,
    WEEKDAY_COUNT,
    WORKING_DAYS,
    BUDGET_WORKING_DAYS,
    FX_RATE_NBC,
    FX_RATE_NSSF
FROM {{ schema_app }}.T_D_PERIOD;
