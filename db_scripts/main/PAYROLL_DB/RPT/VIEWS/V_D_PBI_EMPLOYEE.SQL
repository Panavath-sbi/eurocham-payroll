/* =====================================================================================
   V_D_PBI_EMPLOYEE - Power BI: DimEmployee (one row per employee)
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
   DimEmployee  ->  RPT.V_D_PBI_EMPLOYEE
   One row per employee (active and inactive, as Essbase listed all members).
   Employee_ID = the Resource ID (e.g. HR-FRA-001); Employee_Name = "First LAST".
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW ${DB}.RPT.V_D_PBI_EMPLOYEE (
    "Employee_ID"   COMMENT 'Resource ID shown to users, e.g. HR-FRA-001',
    "Employee_Name" COMMENT 'First name and last name, e.g. Martin BRISSON'
)
COPY GRANTS
COMMENT = 'Power BI: DimEmployee (one row per employee)'
AS
SELECT
    e.RESOURCE_CODE                                                  AS "Employee_ID",
    TRIM(COALESCE(e.FIRST_NAME, '') || ' ' || COALESCE(e.LAST_NAME, '')) AS "Employee_Name"
FROM ${DB}.APP.T_D_EMPLOYEE e
WHERE NOT e.IS_PLANNED;
