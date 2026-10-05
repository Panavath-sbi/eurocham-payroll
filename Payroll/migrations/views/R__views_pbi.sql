/* =====================================================================================
   R - POWER BI COMPATIBILITY VIEWS
   Views shaped exactly like the tables of the existing Power BI report (previously fed
   by Essbase and SharePoint), so the report keeps its tables, columns, relationships
   and measures. Each view replaces the Power Query of the same name.
   =====================================================================================

   HISTORY
   -------
   2026-09-30  Initial version: EmployeeParams, DimEmployee, Employee_Details.
   2026-09-30  Added Payroll_Approval (replaces the SharePoint approval list).
               Fct_Payroll to follow.
   2026-09-30  Added Fct_Payroll (RPT.V_F_PBI_PAYROLL).
   2026-10-02  V1.5.0: tables in APP, base views in RPT (CORE removed).
               Payroll_Approval reads approvals by scenario + period (no request) and the
               assigned approver from T_D_APP_USER.ROLE_CODE. Fct_Payroll reads
               RPT.V_F_COST_ALLOCATION; Tot_Allowance = outstanding-leave payouts only
               (payroll adjustments were removed). New RPT.V_D_PBI_SIGNATURE replaces the
               RPT.SIGNATURES table (same column names).
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
FROM APP.T_D_PERIOD p
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
    JOIN APP.T_D_PERIOD pf      ON pf.PERIOD_KEY = c.VALID_FROM_PERIOD_KEY
    LEFT JOIN APP.T_D_PERIOD pt ON pt.PERIOD_KEY = c.VALID_TO_PERIOD_KEY
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


/* -------------------------------------------------------------------------------------
   Payroll_Approval  ->  RPT.V_F_PBI_PAYROLL_APPROVAL
   Replaces the SharePoint approval list: one row per approval step per actual payroll
   month of the current year (only months that have been opened).
   Title = YYYYMM. Approved_By / Approval_Date are filled once the step is approved or
   rejected; a pending step shows them empty, as in the list. Comments shows the latest
   comment on the step (for a step sent back, the reason it was sent back).
   Assigned_To = the email of the user(s) holding the step's approver role today.
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_F_PBI_PAYROLL_APPROVAL (
    "Title"           COMMENT 'Payroll month as YYYYMM, e.g. 202609',
    "Approval_Step"   COMMENT 'Step title, e.g. HR Manager',
    "Approved_By"     COMMENT 'Name of the approver who approved or rejected the step; empty while pending',
    "Approval_Date"   COMMENT 'When the step was approved or rejected; empty while pending',
    "Approval_Status" COMMENT 'Approved or Rejected; empty while pending',
    "Comments"        COMMENT 'Latest comment on the step',
    "Step_Order"      COMMENT 'Step sequence, 1 = first',
    "Assigned_To"     COMMENT 'Email of the user assigned to the step',
    "Approval_Type"   COMMENT 'Always Actuals',
    "Year"            COMMENT 'Payroll year',
    "MonthNo"         COMMENT 'Payroll month number 1-12'
)
COMMENT = 'Power BI: Payroll_Approval (replaces the SharePoint approval list)'
AS
WITH assigned AS (         -- who holds each approver role today (one role per user)
    SELECT u.ROLE_CODE, LISTAGG(u.USER_EMAIL, '; ') WITHIN GROUP (ORDER BY u.USER_EMAIL) AS EMAILS
    FROM APP.T_D_APP_USER u
    WHERE u.IS_ACTIVE
    GROUP BY u.ROLE_CODE
)
SELECT
    pr.PERIOD_KEY::TEXT                                                   AS "Title",
    pr.STEP_TITLE                                                         AS "Approval_Step",
    IFF(pr.STEP_STATUS IN ('APPROVED', 'REJECTED'), COALESCE(u.DISPLAY_NAME, pr.ACTED_BY), NULL) AS "Approved_By",
    IFF(pr.STEP_STATUS IN ('APPROVED', 'REJECTED'), pr.ACTED_AT::TIMESTAMP_NTZ, NULL)            AS "Approval_Date",
    CASE pr.STEP_STATUS WHEN 'APPROVED' THEN 'Approved' WHEN 'REJECTED' THEN 'Rejected' END      AS "Approval_Status",
    pr.STEP_COMMENT                                                       AS "Comments",
    pr.STEP_ORDER::INT                                                    AS "Step_Order",
    a.EMAILS                                                              AS "Assigned_To",
    'Actuals'                                                             AS "Approval_Type",
    p.YEAR::INT                                                           AS "Year",
    p.MONTH_NUMBER::INT                                                   AS "MonthNo"
FROM RPT.V_F_APPROVAL_PROGRESS pr
JOIN APP.T_D_PERIOD p             ON p.PERIOD_KEY = pr.PERIOD_KEY
LEFT JOIN APP.T_D_APP_USER u      ON u.USER_EMAIL = pr.ACTED_BY
LEFT JOIN assigned a              ON a.ROLE_CODE = pr.APPROVER_ROLE
WHERE pr.SCENARIO_TYPE = 'ACTUAL'
  AND p.YEAR = YEAR(CURRENT_DATE());


/* -------------------------------------------------------------------------------------
   Fct_Payroll  ->  RPT.V_F_PBI_PAYROLL
   One row per employee x month x department, actual payroll of the current year
   (every calculated month: finalized months and the open month).

   * Totals use the same rules as RPT.V_F_PAYROLL_SUMMARY (by pay component CATEGORY):
     gross = EARNING, net = gross - EMPLOYEE_DEDUCTION, NSSF ER = EMPLOYER_CONTRIBUTION.
   * Tot_Allowance = OUTSTANDING_LEAVE payouts (payroll adjustments were removed).
   * CostCenter: ECCC -> 'CC_9999-Shared', CCIFC -> 'CCIFC'.
   * Department split: shares come from RPT.V_F_COST_ALLOCATION,
     normalised to 1 per employee and month. An unsplit employee gets one row with
     department 'Default' and share 1. Money columns are multiplied by the department
     share; days, rates, dependant count and percentages are not.
   * Fund columns = allocated gross x fund share. Any share without a fund goes to the
     employee's own entity fund (ECCC or CCIFC).
   * Position, residency and dependants: contract version in force in that month.
   * ToS_Rate = the rate of the tax bracket the taxable base (after dependant relief)
     falls in; 0.2 for non-residents.
   * Present_Working_Days = month's working days - absence (unpaid leave) days.
   * Unlike Essbase, KHR columns are all filled (Essbase left several at 0), and NSSF ER
     applies the 1,200,000 KHR cap to health and occupational risk too.
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_F_PBI_PAYROLL (
    "CostCenter"             COMMENT 'CC_9999-Shared for ECCC, CCIFC for CCIFC',
    "CostCenter_Department"  COMMENT 'Department name; Default when the employee is not split',
    "Employee_ID"            COMMENT 'Resource ID, e.g. HR-FRA-001',
    "Employee_Name"          COMMENT 'First name and last name',
    "Email"                  COMMENT 'Employee email',
    "TaxResidency_Name"      COMMENT 'Resident or Non-Resident, from the contract of the month',
    "Month"                  COMMENT 'Month code M01..M12',
    "Month_Full"             COMMENT 'Full month name, e.g. April',
    "Tot_Allowance"          COMMENT 'Outstanding leave payout, USD (department share)',
    "Present_Working_Days"   COMMENT 'Working days minus absence days (not split)',
    "Dep_Count"              COMMENT 'Number of dependants (children + spouse) (not split)',
    "Gross_Compensation"     COMMENT 'Gross pay USD = all earnings (department share)',
    "Base_Salary"            COMMENT 'Base salary USD (department share)',
    "ToS_Taxable_Base"       COMMENT 'Taxable base USD before dependant relief (department share)',
    "ToS_Rate"               COMMENT 'Tax bracket rate, e.g. 0.1; 0.2 for non-residents (not split)',
    "NSSF_EE_Total"          COMMENT 'Employee NSSF USD (department share)',
    "Annual_Bonus"           COMMENT 'Bonus USD (department share)',
    "NSSF_ER_Total"          COMMENT 'Employer NSSF USD: pension + health + occupational risk (department share)',
    "ToS_Withheld"           COMMENT 'Salary tax withheld USD (department share)',
    "Net_Salary_Bank"        COMMENT 'Net pay USD paid to the bank (department share)',
    "Overtime"               COMMENT 'Overtime USD (department share)',
    "Seniority_Pay"          COMMENT 'Seniority payment USD (department share)',
    "Unpaid_Leave"           COMMENT 'Unpaid leave USD, as stored by the calculation (department share)',
    "ECCC_Fund"              COMMENT 'Gross USD charged to the ECCC fund',
    "CCIFC_Fund"             COMMENT 'Gross USD charged to the CCIFC fund',
    "EU_Gate_Fund"           COMMENT 'Gross USD charged to the EU GATE fund',
    "Total_Fund"             COMMENT 'Gross USD of the row (sum of the three funds)',
    "ECCC_Pct"               COMMENT 'ECCC fund share, 0..1',
    "CCIFC_Pct"              COMMENT 'CCIFC fund share, 0..1',
    "EU_Gate_Pct"            COMMENT 'EU GATE fund share, 0..1',
    "Gross_Compensation_KHR" COMMENT 'Gross pay KHR (department share)',
    "Base_Salary_KHR"        COMMENT 'Base salary KHR (department share)',
    "ToS_Taxable_Base_KHR"   COMMENT 'Taxable base KHR (department share)',
    "NSSF_EE_Total_KHR"      COMMENT 'Employee NSSF KHR (department share)',
    "NSSF_ER_Total_KHR"      COMMENT 'Employer NSSF KHR (department share)',
    "Annual_Bonus_KHR"       COMMENT 'Bonus KHR (department share)',
    "ToS_Withheld_KHR"       COMMENT 'Salary tax KHR (department share)',
    "Net_Salary_Bank_KHR"    COMMENT 'Net pay KHR, informational (department share)',
    "Seniority_Pay_KHR"      COMMENT 'Seniority payment KHR (department share)',
    "ECCC_Fund_KHR"          COMMENT 'Gross KHR charged to the ECCC fund',
    "CCIFC_Fund_KHR"         COMMENT 'Gross KHR charged to the CCIFC fund',
    "EU_Gate_Fund_KHR"       COMMENT 'Gross KHR charged to the EU GATE fund',
    "Total_Fund_KHR"         COMMENT 'Gross KHR of the row',
    "ECCC_Pct_KHR"           COMMENT 'ECCC fund share, 0..1 (same as ECCC_Pct)',
    "CCIFC_Pct_KHR"          COMMENT 'CCIFC fund share, 0..1 (same as CCIFC_Pct)',
    "EU_Gate_Pct_KHR"        COMMENT 'EU GATE fund share, 0..1 (same as EU_Gate_Pct)',
    "Employee_Position"      COMMENT 'Job title from the contract of the month'
)
COMMENT = 'Power BI: Fct_Payroll (actual payroll, current year, employee x month x department)'
AS
WITH months AS (           -- actual payroll months of the current year
    SELECT sp.SCENARIO_ID, sp.PERIOD_KEY, sp.WORKING_DAYS, p.MONTH_NUMBER, p.PERIOD_START_DATE
    FROM APP.T_F_SCENARIO_PERIOD sp
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = sp.SCENARIO_ID AND s.SCENARIO_TYPE = 'ACTUAL'
    JOIN APP.T_D_PERIOD p  ON p.PERIOD_KEY = sp.PERIOD_KEY
    WHERE p.YEAR = YEAR(CURRENT_DATE())
),
amounts AS (               -- one row per employee and month, pay components pivoted
    SELECT
        l.SCENARIO_ID, l.PERIOD_KEY, l.EMPLOYEE_ID,
        MAX(l.ENTITY_CODE) AS ENTITY_CODE,
        -- USD
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'BASE_SALARY',     l.AMOUNT_USD, 0)), 2) AS BASE_SALARY_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'BONUS',           l.AMOUNT_USD, 0)), 2) AS BONUS_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'OVERTIME',        l.AMOUNT_USD, 0)), 2) AS OVERTIME_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'SENIORITY',       l.AMOUNT_USD, 0)), 2) AS SENIORITY_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'UNPAID_LEAVE',    l.AMOUNT_USD, 0)), 2) AS UNPAID_LEAVE_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'OUTSTANDING_LEAVE', l.AMOUNT_USD, 0)), 2) AS ALLOWANCE_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'TAXABLE_BASE',    l.AMOUNT_USD, 0)), 2) AS TAXABLE_BASE_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'NSSF_EE_PENSION', l.AMOUNT_USD, 0)), 2) AS NSSF_EE_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'SALARY_TAX',      l.AMOUNT_USD, 0)), 2) AS SALARY_TAX_USD,
        ROUND(SUM(IFF(pc.CATEGORY = 'EARNING',                  l.AMOUNT_USD, 0)), 2) AS GROSS_USD,
        ROUND(SUM(IFF(pc.CATEGORY = 'EMPLOYEE_DEDUCTION',       l.AMOUNT_USD, 0)), 2) AS DEDUCTIONS_USD,
        ROUND(SUM(IFF(pc.CATEGORY = 'EMPLOYER_CONTRIBUTION',    l.AMOUNT_USD, 0)), 2) AS NSSF_ER_USD,
        -- KHR
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'BASE_SALARY',     l.AMOUNT_KHR, 0)), 0) AS BASE_SALARY_KHR,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'BONUS',           l.AMOUNT_KHR, 0)), 0) AS BONUS_KHR,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'SENIORITY',       l.AMOUNT_KHR, 0)), 0) AS SENIORITY_KHR,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'TAXABLE_BASE',    l.AMOUNT_KHR, 0)), 0) AS TAXABLE_BASE_KHR,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'NSSF_EE_PENSION', l.AMOUNT_KHR, 0)), 0) AS NSSF_EE_KHR,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'SALARY_TAX',      l.AMOUNT_KHR, 0)), 0) AS SALARY_TAX_KHR,
        ROUND(SUM(IFF(pc.CATEGORY = 'EARNING',                  l.AMOUNT_KHR, 0)), 0) AS GROSS_KHR,
        ROUND(SUM(IFF(pc.CATEGORY = 'EMPLOYEE_DEDUCTION',       l.AMOUNT_KHR, 0)), 0) AS DEDUCTIONS_KHR,
        ROUND(SUM(IFF(pc.CATEGORY = 'EMPLOYER_CONTRIBUTION',    l.AMOUNT_KHR, 0)), 0) AS NSSF_ER_KHR,
        SUM(IFF(l.PAY_COMPONENT_CODE = 'TAX_CALC_BASE',         l.AMOUNT_KHR, 0))     AS TAX_CALC_BASE_KHR
    FROM APP.T_F_PAYROLL_LINE l
    JOIN APP.T_D_PAY_COMPONENT pc ON pc.PAY_COMPONENT_CODE = l.PAY_COMPONENT_CODE
    JOIN months m                  ON m.SCENARIO_ID = l.SCENARIO_ID AND m.PERIOD_KEY = l.PERIOD_KEY
    GROUP BY l.SCENARIO_ID, l.PERIOD_KEY, l.EMPLOYEE_ID
),
alloc AS (                 -- calculated fund x department shares, normalised to 1
    SELECT ca.SCENARIO_ID, ca.PERIOD_KEY, ca.EMPLOYEE_ID, ca.FUND_CODE, ca.DEPARTMENT_CODE,
           ca.ALLOCATION_SHARE
             / NULLIF(SUM(ca.ALLOCATION_SHARE) OVER (PARTITION BY ca.SCENARIO_ID, ca.PERIOD_KEY, ca.EMPLOYEE_ID), 0) AS SHARE
    FROM RPT.V_F_COST_ALLOCATION ca
    JOIN months m ON m.SCENARIO_ID = ca.SCENARIO_ID AND m.PERIOD_KEY = ca.PERIOD_KEY
),
dept_share AS (            -- one row per department the employee is split over
    SELECT SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, DEPARTMENT_CODE, SUM(SHARE) AS DEPT_SHARE
    FROM alloc
    GROUP BY SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, DEPARTMENT_CODE
),
fund_raw AS (              -- shares per fund; 0 when no allocation rows
    SELECT am.SCENARIO_ID, am.PERIOD_KEY, am.EMPLOYEE_ID, am.ENTITY_CODE,
           COALESCE(SUM(IFF(al.FUND_CODE = 'ECCC',    al.SHARE, 0)), 0) AS ECCC_RAW,
           COALESCE(SUM(IFF(al.FUND_CODE = 'CCIFC',   al.SHARE, 0)), 0) AS CCIFC_RAW,
           COALESCE(SUM(IFF(al.FUND_CODE = 'EU_GATE', al.SHARE, 0)), 0) AS EU_GATE_RAW
    FROM amounts am
    LEFT JOIN alloc al ON al.SCENARIO_ID = am.SCENARIO_ID AND al.PERIOD_KEY = am.PERIOD_KEY
                      AND al.EMPLOYEE_ID = am.EMPLOYEE_ID
    GROUP BY am.SCENARIO_ID, am.PERIOD_KEY, am.EMPLOYEE_ID, am.ENTITY_CODE
),
fund_share AS (            -- any share without a fund goes to the employee's entity fund
    SELECT f.SCENARIO_ID, f.PERIOD_KEY, f.EMPLOYEE_ID,
           f.ECCC_RAW    + IFF(f.ENTITY_CODE = 'ECCC',  GREATEST(1 - f.ECCC_RAW - f.CCIFC_RAW - f.EU_GATE_RAW, 0), 0) AS ECCC_SHARE,
           f.CCIFC_RAW   + IFF(f.ENTITY_CODE = 'CCIFC', GREATEST(1 - f.ECCC_RAW - f.CCIFC_RAW - f.EU_GATE_RAW, 0), 0) AS CCIFC_SHARE,
           f.EU_GATE_RAW                                                                                               AS EU_GATE_SHARE
    FROM fund_raw f
),
month_contract AS (        -- contract version in force in the payroll month
    SELECT am.SCENARIO_ID, am.PERIOD_KEY, am.EMPLOYEE_ID, c.POSITION, c.TAX_STATUS,
           COALESCE(c.DEPENDANT_CHILDREN, 0) + COALESCE(c.DEPENDANT_SPOUSE::INT, 0) AS DEP_COUNT
    FROM amounts am
    JOIN APP.T_D_EMPLOYEE_CONTRACT c
      ON c.EMPLOYEE_ID = am.EMPLOYEE_ID
     AND c.VALID_FROM_PERIOD_KEY <= am.PERIOD_KEY
     AND (c.VALID_TO_PERIOD_KEY IS NULL OR c.VALID_TO_PERIOD_KEY >= am.PERIOD_KEY)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY am.SCENARIO_ID, am.PERIOD_KEY, am.EMPLOYEE_ID
                               ORDER BY c.VALID_FROM_PERIOD_KEY DESC) = 1
),
tax_rate AS (              -- highest bracket whose lower bound the taxable base exceeds
    SELECT am.SCENARIO_ID, am.PERIOD_KEY, am.EMPLOYEE_ID, tb.TAX_RATE
    FROM amounts am
    JOIN APP.T_P_TAX_BRACKET tb
      ON tb.VALID_FROM_PERIOD_KEY <= am.PERIOD_KEY
     AND (tb.VALID_TO_PERIOD_KEY IS NULL OR tb.VALID_TO_PERIOD_KEY >= am.PERIOD_KEY)
     AND am.TAX_CALC_BASE_KHR > tb.LOWER_BOUND_KHR
    QUALIFY ROW_NUMBER() OVER (PARTITION BY am.SCENARIO_ID, am.PERIOD_KEY, am.EMPLOYEE_ID
                               ORDER BY tb.BRACKET_NUMBER DESC) = 1
)
SELECT
    IFF(am.ENTITY_CODE = 'ECCC', 'CC_9999-Shared', am.ENTITY_CODE)                  AS "CostCenter",
    COALESCE(dep.DEPARTMENT_NAME, d.DEPARTMENT_CODE, 'Default')                     AS "CostCenter_Department",
    e.RESOURCE_CODE                                                                 AS "Employee_ID",
    TRIM(COALESCE(e.FIRST_NAME, '') || ' ' || COALESCE(e.LAST_NAME, ''))            AS "Employee_Name",
    e.EMAIL                                                                         AS "Email",
    IFF(mc.TAX_STATUS = 'NON_RESIDENT', 'Non-Resident', 'Resident')                 AS "TaxResidency_Name",
    'M' || LPAD(m.MONTH_NUMBER, 2, '0')                                             AS "Month",
    TO_CHAR(m.PERIOD_START_DATE, 'MMMM')                                            AS "Month_Full",
    (am.ALLOWANCE_USD * ds.S)::FLOAT                                                AS "Tot_Allowance",
    (COALESCE(m.WORKING_DAYS, 0) - COALESCE(pi.ABSENCE_DAYS, 0))::FLOAT             AS "Present_Working_Days",
    COALESCE(mc.DEP_COUNT, 0)::INT                                                  AS "Dep_Count",
    (am.GROSS_USD * ds.S)::FLOAT                                                    AS "Gross_Compensation",
    (am.BASE_SALARY_USD * ds.S)::FLOAT                                              AS "Base_Salary",
    (am.TAXABLE_BASE_USD * ds.S)::FLOAT                                             AS "ToS_Taxable_Base",
    IFF(mc.TAX_STATUS = 'NON_RESIDENT', 0.2, COALESCE(tr.TAX_RATE, 0))::FLOAT       AS "ToS_Rate",
    (am.NSSF_EE_USD * ds.S)::FLOAT                                                  AS "NSSF_EE_Total",
    (am.BONUS_USD * ds.S)::FLOAT                                                    AS "Annual_Bonus",
    (am.NSSF_ER_USD * ds.S)::FLOAT                                                  AS "NSSF_ER_Total",
    (am.SALARY_TAX_USD * ds.S)::FLOAT                                               AS "ToS_Withheld",
    ((am.GROSS_USD - am.DEDUCTIONS_USD) * ds.S)::FLOAT                              AS "Net_Salary_Bank",
    (am.OVERTIME_USD * ds.S)::FLOAT                                                 AS "Overtime",
    (am.SENIORITY_USD * ds.S)::FLOAT                                                AS "Seniority_Pay",
    (am.UNPAID_LEAVE_USD * ds.S)::FLOAT                                             AS "Unpaid_Leave",
    (am.GROSS_USD * ds.S * fs.ECCC_SHARE)::FLOAT                                    AS "ECCC_Fund",
    (am.GROSS_USD * ds.S * fs.CCIFC_SHARE)::FLOAT                                   AS "CCIFC_Fund",
    (am.GROSS_USD * ds.S * fs.EU_GATE_SHARE)::FLOAT                                 AS "EU_Gate_Fund",
    (am.GROSS_USD * ds.S)::FLOAT                                                    AS "Total_Fund",
    fs.ECCC_SHARE::FLOAT                                                            AS "ECCC_Pct",
    fs.CCIFC_SHARE::FLOAT                                                           AS "CCIFC_Pct",
    fs.EU_GATE_SHARE::FLOAT                                                         AS "EU_Gate_Pct",
    (am.GROSS_KHR * ds.S)::FLOAT                                                    AS "Gross_Compensation_KHR",
    (am.BASE_SALARY_KHR * ds.S)::FLOAT                                              AS "Base_Salary_KHR",
    (am.TAXABLE_BASE_KHR * ds.S)::FLOAT                                             AS "ToS_Taxable_Base_KHR",
    (am.NSSF_EE_KHR * ds.S)::FLOAT                                                  AS "NSSF_EE_Total_KHR",
    (am.NSSF_ER_KHR * ds.S)::FLOAT                                                  AS "NSSF_ER_Total_KHR",
    (am.BONUS_KHR * ds.S)::FLOAT                                                    AS "Annual_Bonus_KHR",
    (am.SALARY_TAX_KHR * ds.S)::FLOAT                                               AS "ToS_Withheld_KHR",
    ((am.GROSS_KHR - am.DEDUCTIONS_KHR) * ds.S)::FLOAT                              AS "Net_Salary_Bank_KHR",
    (am.SENIORITY_KHR * ds.S)::FLOAT                                                AS "Seniority_Pay_KHR",
    (am.GROSS_KHR * ds.S * fs.ECCC_SHARE)::FLOAT                                    AS "ECCC_Fund_KHR",
    (am.GROSS_KHR * ds.S * fs.CCIFC_SHARE)::FLOAT                                   AS "CCIFC_Fund_KHR",
    (am.GROSS_KHR * ds.S * fs.EU_GATE_SHARE)::FLOAT                                 AS "EU_Gate_Fund_KHR",
    (am.GROSS_KHR * ds.S)::FLOAT                                                    AS "Total_Fund_KHR",
    fs.ECCC_SHARE::FLOAT                                                            AS "ECCC_Pct_KHR",
    fs.CCIFC_SHARE::FLOAT                                                           AS "CCIFC_Pct_KHR",
    fs.EU_GATE_SHARE::FLOAT                                                         AS "EU_Gate_Pct_KHR",
    mc.POSITION                                                                     AS "Employee_Position"
FROM amounts am
JOIN months m              ON m.SCENARIO_ID = am.SCENARIO_ID AND m.PERIOD_KEY = am.PERIOD_KEY
JOIN APP.T_D_EMPLOYEE e    ON e.EMPLOYEE_ID = am.EMPLOYEE_ID AND NOT e.IS_PLANNED
JOIN fund_share fs         ON fs.SCENARIO_ID = am.SCENARIO_ID AND fs.PERIOD_KEY = am.PERIOD_KEY
                          AND fs.EMPLOYEE_ID = am.EMPLOYEE_ID
LEFT JOIN dept_share d     ON d.SCENARIO_ID = am.SCENARIO_ID AND d.PERIOD_KEY = am.PERIOD_KEY
                          AND d.EMPLOYEE_ID = am.EMPLOYEE_ID
LEFT JOIN APP.T_D_DEPARTMENT dep ON dep.DEPARTMENT_CODE = d.DEPARTMENT_CODE
LEFT JOIN month_contract mc ON mc.SCENARIO_ID = am.SCENARIO_ID AND mc.PERIOD_KEY = am.PERIOD_KEY
                          AND mc.EMPLOYEE_ID = am.EMPLOYEE_ID
LEFT JOIN tax_rate tr      ON tr.SCENARIO_ID = am.SCENARIO_ID AND tr.PERIOD_KEY = am.PERIOD_KEY
                          AND tr.EMPLOYEE_ID = am.EMPLOYEE_ID
LEFT JOIN APP.T_F_PAYROLL_INPUT pi ON pi.SCENARIO_ID = am.SCENARIO_ID AND pi.PERIOD_KEY = am.PERIOD_KEY
                          AND pi.EMPLOYEE_ID = am.EMPLOYEE_ID
CROSS JOIN LATERAL (SELECT COALESCE(d.DEPT_SHARE, 1) AS S) ds;


/* -------------------------------------------------------------------------------------
   eSignature  ->  RPT.V_D_PBI_SIGNATURE
   One row per app user with a signature. Same column names as the former RPT.SIGNATURES
   table, so the Power BI query only needs its source changed to this view.
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_D_PBI_SIGNATURE (
    APPROVER_EMAIL COMMENT 'Email of the approver (app user)',
    IMAGE_BASE64   COMMENT 'E-signature image in Base64'
)
COMMENT = 'Power BI: approver e-signatures (from APP.T_D_APP_USER.SIGNATURE_IMAGE)'
AS
SELECT USER_EMAIL, SIGNATURE_IMAGE
FROM APP.T_D_APP_USER
WHERE SIGNATURE_IMAGE IS NOT NULL;
