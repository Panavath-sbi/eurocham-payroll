-- depends_on: T_D_PERIOD, T_D_SCENARIO, T_F_SCENARIO_PERIOD
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_P_PBI_EMPLOYEE_PARAMS - Power BI: EmployeeParams (monthly FX rates and working days, current year)
   =====================================================================================

   HISTORY
   -------
   2026-09-30  Initial version: EmployeeParams, DimEmployee, Employee_Details.
   2026-10-19  Own file for DLSync (was in R__views_pbi.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.

   NOTES
   -----
   * "Current year" = the calendar year of CURRENT_DATE(), as DynamicFiscalYear did.
   * Only real employees are shown (planned hires of budgets / forecasts are excluded).
   ===================================================================================== */
/* -------------------------------------------------------------------------------------
   EmployeeParams  ->  RPT.V_P_PBI_EMPLOYEE_PARAMS
   One row per month of the current year: M01..M12.
   FX rates: the rates applied to the actual payroll month, 0 when the month has no
   payroll yet (as in Essbase). Working days: the payroll month's value, otherwise the
   Settings calendar, otherwise 0.
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_P_PBI_EMPLOYEE_PARAMS (
    "Month"        COMMENT 'Month code M01..M12',
    "MonthNo"      COMMENT 'Month number 1..12',
    "FX_USD_KHR"   COMMENT 'NBC USD-KHR rate applied to the payroll month; 0 if not opened',
    "FX_NSSF_KHR"  COMMENT 'NSSF USD-KHR rate applied to the payroll month; 0 if not opened',
    "Working_Days" COMMENT 'Working days of the month; 0 if not set'
)
COPY GRANTS
COMMENT = 'Power BI: EmployeeParams (monthly FX rates and working days, current year)'
AS
SELECT
    'M' || LPAD(p.MONTH_NUMBER, 2, '0')                          AS "Month",
    p.MONTH_NUMBER                                               AS "MonthNo",
    COALESCE(sp.FX_RATE_NBC, 0)::FLOAT                           AS "FX_USD_KHR",
    COALESCE(sp.FX_RATE_NSSF, 0)::FLOAT                          AS "FX_NSSF_KHR",
    COALESCE(sp.WORKING_DAYS, NULLIF(p.WORKING_DAYS, 0), 0)::INT AS "Working_Days"
FROM APP.T_D_PERIOD p
LEFT JOIN APP.T_D_SCENARIO s
       ON s.SCENARIO_TYPE = 'ACTUAL'
LEFT JOIN APP.T_F_SCENARIO_PERIOD sp
       ON sp.SCENARIO_ID = s.SCENARIO_ID AND sp.PERIOD_KEY = p.PERIOD_KEY
WHERE p.YEAR = YEAR(CURRENT_DATE());
