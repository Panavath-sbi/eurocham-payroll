/* =====================================================================================
   R - POWER BI COMPATIBILITY VIEWS
   Views shaped exactly like the tables of the existing Power BI report (previously fed
   by Essbase and SharePoint), so the report keeps its tables, columns, relationships
   and measures. Each view replaces the Power Query of the same name.
   =====================================================================================

   HISTORY
   -------
   2026-09-30  Initial version: EmployeeParams, DimEmployee, Employee_Details.
               Fct_Payroll and Payroll_Approval to follow.
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

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
COMMENT = 'Power BI: EmployeeParams (monthly FX rates and working days, current year)'
AS
SELECT
    'M' || LPAD(p.MONTH_NUMBER, 2, '0')                          AS "Month",
    p.MONTH_NUMBER                                               AS "MonthNo",
    COALESCE(sp.FX_RATE_NBC, 0)::FLOAT                           AS "FX_USD_KHR",
    COALESCE(sp.FX_RATE_NSSF, 0)::FLOAT                          AS "FX_NSSF_KHR",
    COALESCE(sp.WORKING_DAYS, NULLIF(p.WORKING_DAYS, 0), 0)::INT AS "Working_Days"
FROM CORE.T_D_PERIOD p
LEFT JOIN APP.T_D_SCENARIO s
       ON s.SCENARIO_TYPE = 'ACTUAL'
LEFT JOIN APP.T_F_SCENARIO_PERIOD sp
       ON sp.SCENARIO_ID = s.SCENARIO_ID AND sp.PERIOD_KEY = p.PERIOD_KEY
WHERE p.YEAR = YEAR(CURRENT_DATE());


/* -------------------------------------------------------------------------------------
   DimEmployee  ->  RPT.V_D_PBI_EMPLOYEE
   One row per employee (active and inactive, as Essbase listed all members).
   Employee_ID = the Resource ID (e.g. HR-FRA-001); Employee_Name = "First LAST".
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_D_PBI_EMPLOYEE (
    "Employee_ID"   COMMENT 'Resource ID shown to users, e.g. HR-FRA-001',
    "Employee_Name" COMMENT 'First name and last name, e.g. Martin BRISSON'
)
COMMENT = 'Power BI: DimEmployee (one row per employee)'
AS
SELECT
    e.RESOURCE_CODE                                                  AS "Employee_ID",
    TRIM(COALESCE(e.FIRST_NAME, '') || ' ' || COALESCE(e.LAST_NAME, '')) AS "Employee_Name"
FROM APP.T_D_EMPLOYEE e
WHERE NOT e.IS_PLANNED;


/* -------------------------------------------------------------------------------------
   Employee_Details  ->  RPT.V_D_PBI_EMPLOYEE_DETAILS
   Replaces the SharePoint list. Title = Resource ID (the join key used by Fct_Payroll).
   Residency and Position come from the contract version in force today (or the latest
   version for employees who have left). Non-residency dates are derived from the
   contract versions with tax status NON_RESIDENT: first day of the first such version,
   last day of the last one (NULL while still non-resident).
   Bank fields are sensitive: apply the masking policy (optional/mask_bank_details.sql)
   and give Power BI a role that only sees what the report needs.
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_D_PBI_EMPLOYEE_DETAILS (
    "Title"                    COMMENT 'Resource ID, e.g. HR-FRA-001 (join key to Fct_Payroll.Employee_ID)',
    "Start_Date"               COMMENT 'Employment start date',
    "End_Date"                 COMMENT 'Employment end date; NULL while employed',
    "Non_Residency_Start_Date" COMMENT 'First day of non-resident tax treatment; NULL if never non-resident',
    "Non_Residency_End_Date"   COMMENT 'Last day of non-resident tax treatment; NULL if never, or still, non-resident',
    "Residency"                COMMENT 'Current tax residency: Resident or Non-Resident',
    "Bank_Name"                COMMENT 'Disbursing bank (sensitive)',
    "Bank_Account_Name"        COMMENT 'Account holder name (sensitive)',
    "Bank_Account_Number"      COMMENT 'Bank account number (sensitive)',
    "Position"                 COMMENT 'Current job title'
)
COMMENT = 'Power BI: Employee_Details (replaces the SharePoint list)'
AS
WITH current_contract AS (
    SELECT c.*
    FROM APP.T_D_EMPLOYEE_CONTRACT c
    WHERE c.VALID_FROM_PERIOD_KEY <= TO_NUMBER(TO_CHAR(CURRENT_DATE(), 'YYYYMM'))
    QUALIFY ROW_NUMBER() OVER (PARTITION BY c.EMPLOYEE_ID ORDER BY c.VALID_FROM_PERIOD_KEY DESC) = 1
),
non_residency AS (
    SELECT c.EMPLOYEE_ID,
           MIN(pf.PERIOD_START_DATE)                                        AS NR_START,
           IFF(COUNT_IF(c.VALID_TO_PERIOD_KEY IS NULL) > 0, NULL, MAX(pt.PERIOD_END_DATE)) AS NR_END
    FROM APP.T_D_EMPLOYEE_CONTRACT c
    JOIN CORE.T_D_PERIOD pf      ON pf.PERIOD_KEY = c.VALID_FROM_PERIOD_KEY
    LEFT JOIN CORE.T_D_PERIOD pt ON pt.PERIOD_KEY = c.VALID_TO_PERIOD_KEY
    WHERE c.TAX_STATUS = 'NON_RESIDENT'
    GROUP BY c.EMPLOYEE_ID
)
SELECT
    e.RESOURCE_CODE                                        AS "Title",
    e.EMPLOYMENT_START_DATE::TIMESTAMP_NTZ                 AS "Start_Date",
    e.EMPLOYMENT_END_DATE::TIMESTAMP_NTZ                   AS "End_Date",
    nr.NR_START::TIMESTAMP_NTZ                             AS "Non_Residency_Start_Date",
    nr.NR_END::TIMESTAMP_NTZ                               AS "Non_Residency_End_Date",
    IFF(cc.TAX_STATUS = 'NON_RESIDENT', 'Non-Resident', 'Resident') AS "Residency",
    e.BANK_NAME                                            AS "Bank_Name",
    e.BANK_ACCOUNT_NAME                                    AS "Bank_Account_Name",
    e.BANK_ACCOUNT_NUMBER                                  AS "Bank_Account_Number",
    cc.POSITION                                            AS "Position"
FROM APP.T_D_EMPLOYEE e
LEFT JOIN current_contract cc ON cc.EMPLOYEE_ID = e.EMPLOYEE_ID
LEFT JOIN non_residency nr    ON nr.EMPLOYEE_ID = e.EMPLOYEE_ID
WHERE NOT e.IS_PLANNED;