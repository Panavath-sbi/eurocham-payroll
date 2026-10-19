/* =====================================================================================
   V_D_PBI_EMPLOYEE_DETAILS - Power BI: Employee_Details (replaces the SharePoint list)
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
   Employee_Details  ->  RPT.V_D_PBI_EMPLOYEE_DETAILS
   Replaces the SharePoint list. Title = Resource ID (the join key used by Fct_Payroll).
   Residency and Position come from the contract version in force today (or the latest
   version for employees who have left). Non-residency dates are derived from the
   contract versions with tax status NON_RESIDENT: first day of the first such version,
   last day of the last one (NULL while still non-resident).
   Bank fields are sensitive: apply the masking policy (optional/mask_bank_details.sql)
   and give Power BI a role that only sees what the report needs.
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW ${DB}.RPT.V_D_PBI_EMPLOYEE_DETAILS (
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
COPY GRANTS
COMMENT = 'Power BI: Employee_Details (replaces the SharePoint list)'
AS
WITH current_contract AS (
    SELECT c.*
    FROM ${DB}.APP.T_D_EMPLOYEE_CONTRACT c
    WHERE c.VALID_FROM_PERIOD_KEY <= TO_NUMBER(TO_CHAR(CURRENT_DATE(), 'YYYYMM'))
    QUALIFY ROW_NUMBER() OVER (PARTITION BY c.EMPLOYEE_ID ORDER BY c.VALID_FROM_PERIOD_KEY DESC) = 1
),
non_residency AS (
    SELECT c.EMPLOYEE_ID,
           MIN(pf.PERIOD_START_DATE)                                        AS NR_START,
           IFF(COUNT_IF(c.VALID_TO_PERIOD_KEY IS NULL) > 0, NULL, MAX(pt.PERIOD_END_DATE)) AS NR_END
    FROM ${DB}.APP.T_D_EMPLOYEE_CONTRACT c
    JOIN ${DB}.APP.T_D_PERIOD pf      ON pf.PERIOD_KEY = c.VALID_FROM_PERIOD_KEY
    LEFT JOIN ${DB}.APP.T_D_PERIOD pt ON pt.PERIOD_KEY = c.VALID_TO_PERIOD_KEY
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
FROM ${DB}.APP.T_D_EMPLOYEE e
LEFT JOIN current_contract cc ON cc.EMPLOYEE_ID = e.EMPLOYEE_ID
LEFT JOIN non_residency nr    ON nr.EMPLOYEE_ID = e.EMPLOYEE_ID
WHERE NOT e.IS_PLANNED;
