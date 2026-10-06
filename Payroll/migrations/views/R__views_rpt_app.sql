/* =====================================================================================
   R - RPT VIEWS FOR THE POWER APPS PAGES
   What the app reads (through the "Payroll - Read" flow) that the other RPT views do not
   already cover. The app never reads an APP table directly.
   Runs after R__views_core.sql (file name order: core, pbi, rpt, rpt_app).
   =====================================================================================

   HISTORY
   -------
   2026-10-05  Initial version: V_D_PERIOD, V_F_SCENARIO_PERIOD, V_F_PAYROLL_INPUT,
               V_F_ALLOCATION, V_D_SCENARIO_EMPLOYEE, V_F_PAYROLL_LINE, V_D_LOOKUP,
               V_P_APPROVAL_STEP, V_D_APP_USER.
   2026-10-05  V_F_DASHBOARD_MONTH added (everything the Dashboard shows, one row per month).
   2026-10-05  V_F_PAYROLL_MONTH added (one row per employee per month with the totals
               and the main components; replaces the app's Essbase transaction queries).
   2026-10-06  V_D_SCENARIO_EMPLOYEE: adds START_PERIOD_KEY / END_PERIOD_KEY (first and last
               month the employee is paid in the scenario) and BONUS_USD (the year's bonus
               inputs) for the Budget Input grid and the planned-hire dialog.
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

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
CREATE OR REPLACE VIEW RPT.V_D_PERIOD
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
FROM APP.T_D_PERIOD;

/* -------------------------------------------------------------------------------------
   Months of a scenario: period dropdown, FX card, open-month logic
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_F_SCENARIO_PERIOD (
    SCENARIO_ID, SCENARIO_TYPE, SCENARIO_NAME, PERIOD_KEY, PERIOD_LABEL, YEAR, MONTH_NUMBER,
    PERIOD_STATUS,
    IS_OPEN COMMENT 'TRUE for the actual month that can still be edited or approved (OPEN or IN_APPROVAL)',
    WORKING_DAYS, FX_RATE_NBC, FX_RATE_NSSF, FINALIZED_AT, FINALIZED_BY
)
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
FROM APP.T_F_SCENARIO_PERIOD sp
JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = sp.SCENARIO_ID
JOIN APP.T_D_PERIOD p   ON p.PERIOD_KEY = sp.PERIOD_KEY;

/* -------------------------------------------------------------------------------------
   Monthly inputs with names and the employee check: Monthly Inputs grid, Approval
   validation buttons, budget "Show Details"
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_F_PAYROLL_INPUT (
    SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, RESOURCE_CODE,
    FULL_NAME COMMENT 'First and last name',
    INCLUDE_IN_PAYROLL, ABSENCE_DAYS, OVERTIME_DAYS, OUTSTANDING_DAYS, BONUS_USD,
    SALARY_OVERRIDE_USD, FRINGE_BENEFIT_OVERRIDE_USD, NOTES,
    CHECK_STATUS, CHECK_COMMENT, CHECKED_BY,
    UPDATED_AT COMMENT 'When the row was last changed',
    UPDATED_BY COMMENT 'Who last changed the row'
)
COMMENT = 'Monthly inputs per scenario, month and employee, with the employee check (actual payroll). Budget months only have rows where something was entered.'
AS
SELECT
    i.SCENARIO_ID,
    i.PERIOD_KEY,
    i.EMPLOYEE_ID,
    e.RESOURCE_CODE,
    TRIM(COALESCE(e.FIRST_NAME, '') || ' ' || COALESCE(e.LAST_NAME, '')),
    i.INCLUDE_IN_PAYROLL,
    i.ABSENCE_DAYS,
    i.OVERTIME_DAYS,
    i.OUTSTANDING_DAYS,
    i.BONUS_USD,
    i.SALARY_OVERRIDE_USD,
    i.FRINGE_BENEFIT_OVERRIDE_USD,
    i.NOTES,
    COALESCE(i.CHECK_STATUS, 'PENDING'),
    i.CHECK_COMMENT,
    i.CHECKED_BY,
    i.UPDATE_DATE,
    i.UPDATE_BY
FROM APP.T_F_PAYROLL_INPUT i
JOIN APP.T_D_EMPLOYEE e ON e.EMPLOYEE_ID = i.EMPLOYEE_ID;

/* -------------------------------------------------------------------------------------
   Fund and department splits in one list (reading only; they stay two tables):
   Cost Center page
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_F_ALLOCATION (
    SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID,
    ALLOCATION_TYPE COMMENT 'FUND or DEPARTMENT',
    ALLOCATION_CODE COMMENT 'Fund code or department code',
    ALLOCATION_NAME COMMENT 'Fund or department name',
    SHARE_PCT
)
COMMENT = 'Fund and department splits per scenario, month and employee (percent, each type totals 100).'
AS
SELECT f.SCENARIO_ID, f.PERIOD_KEY, f.EMPLOYEE_ID, 'FUND', f.FUND_CODE, fu.FUND_NAME, f.SHARE_PCT
FROM APP.T_F_FUND_ALLOCATION f
JOIN APP.T_D_FUND fu ON fu.FUND_CODE = f.FUND_CODE
UNION ALL
SELECT d.SCENARIO_ID, d.PERIOD_KEY, d.EMPLOYEE_ID, 'DEPARTMENT', d.DEPARTMENT_CODE, de.DEPARTMENT_NAME, d.SHARE_PCT
FROM APP.T_F_DEPARTMENT_ALLOCATION d
JOIN APP.T_D_DEPARTMENT de ON de.DEPARTMENT_CODE = d.DEPARTMENT_CODE;

/* -------------------------------------------------------------------------------------
   Employee terms inside a budget or forecast: Budget Input grid, Forecast page
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_D_SCENARIO_EMPLOYEE (
    SCENARIO_ID, EMPLOYEE_ID, RESOURCE_CODE,
    FULL_NAME COMMENT 'First and last name',
    IS_PLANNED, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
    MONTHLY_SALARY_USD, RAISE_PCT, REVALUATION_PERIOD_KEY, FINAL_SALARY_USD,
    TAX_STATUS, DEPENDANT_CHILDREN, DEPENDANT_SPOUSE,
    INSURANCE_USD, VISA_USD, WORK_PERMIT_USD, FRINGE_BENEFIT_USD,
    LAST_CONTRACT_CHANGE_PERIOD_KEY COMMENT 'First month of the employee''s latest actual contract version (shown as the latest raise date); NULL for planned hires',
    START_PERIOD_KEY COMMENT 'First month of the scenario in which the employee is paid (a month without an input row counts as paid)',
    END_PERIOD_KEY COMMENT 'Last month of the scenario in which the employee is paid',
    BONUS_USD COMMENT 'Sum of the bonus inputs of the employee over the scenario''s months (budget: entered in March)'
)
COMMENT = 'Employee terms per budget or forecast scenario, including planned hires.'
AS
SELECT
    se.SCENARIO_ID,
    se.EMPLOYEE_ID,
    e.RESOURCE_CODE,
    TRIM(COALESCE(e.FIRST_NAME, '') || ' ' || COALESCE(e.LAST_NAME, '')),
    e.IS_PLANNED,
    se.POSITION,
    se.EMPLOYMENT_TYPE,
    se.CONTRACT_TYPE,
    se.ENTITY_CODE,
    se.MONTHLY_SALARY_USD,
    se.RAISE_PCT,
    se.REVALUATION_PERIOD_KEY,
    se.FINAL_SALARY_USD,
    se.TAX_STATUS,
    se.DEPENDANT_CHILDREN,
    se.DEPENDANT_SPOUSE,
    se.INSURANCE_USD,
    se.VISA_USD,
    se.WORK_PERMIT_USD,
    se.FRINGE_BENEFIT_USD,
    lc.LAST_FROM,
    pm.START_PK,
    pm.END_PK,
    COALESCE(pm.BONUS, 0)
FROM APP.T_D_SCENARIO_EMPLOYEE se
JOIN APP.T_D_EMPLOYEE e ON e.EMPLOYEE_ID = se.EMPLOYEE_ID
LEFT JOIN (SELECT EMPLOYEE_ID, MAX(VALID_FROM_PERIOD_KEY) AS LAST_FROM
           FROM APP.T_D_EMPLOYEE_CONTRACT GROUP BY EMPLOYEE_ID) lc
       ON lc.EMPLOYEE_ID = se.EMPLOYEE_ID
LEFT JOIN (SELECT x.SCENARIO_ID, se2.EMPLOYEE_ID,
                  MIN(IFF(COALESCE(i.INCLUDE_IN_PAYROLL, TRUE), x.PERIOD_KEY, NULL)) AS START_PK,
                  MAX(IFF(COALESCE(i.INCLUDE_IN_PAYROLL, TRUE), x.PERIOD_KEY, NULL)) AS END_PK,
                  SUM(COALESCE(i.BONUS_USD, 0))                                       AS BONUS
           FROM APP.T_F_SCENARIO_PERIOD x
           JOIN APP.T_D_SCENARIO_EMPLOYEE se2 ON se2.SCENARIO_ID = x.SCENARIO_ID
           LEFT JOIN APP.T_F_PAYROLL_INPUT i
                  ON i.SCENARIO_ID = x.SCENARIO_ID AND i.PERIOD_KEY = x.PERIOD_KEY AND i.EMPLOYEE_ID = se2.EMPLOYEE_ID
           GROUP BY x.SCENARIO_ID, se2.EMPLOYEE_ID) pm
       ON pm.SCENARIO_ID = se.SCENARIO_ID AND pm.EMPLOYEE_ID = se.EMPLOYEE_ID;

/* -------------------------------------------------------------------------------------
   Pay lines by component: cards that need one component (bonus, seniority, ToS ...)
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_F_PAYROLL_LINE (
    SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, PAY_COMPONENT_CODE, PAY_COMPONENT_NAME, CATEGORY,
    DISPLAY_ORDER, ENTITY_CODE, QUANTITY, RATE, AMOUNT_USD, AMOUNT_KHR, FX_RATE_APPLIED
)
COMMENT = 'Calculated pay lines (scenario x month x employee x pay component) with the component name and category.'
AS
SELECT
    l.SCENARIO_ID,
    l.PERIOD_KEY,
    l.EMPLOYEE_ID,
    l.PAY_COMPONENT_CODE,
    pc.PAY_COMPONENT_NAME,
    pc.CATEGORY,
    pc.DISPLAY_ORDER,
    l.ENTITY_CODE,
    l.QUANTITY,
    l.RATE,
    l.AMOUNT_USD,
    l.AMOUNT_KHR,
    l.FX_RATE_APPLIED
FROM APP.T_F_PAYROLL_LINE l
JOIN APP.T_D_PAY_COMPONENT pc ON pc.PAY_COMPONENT_CODE = l.PAY_COMPONENT_CODE;

/* -------------------------------------------------------------------------------------
   Dropdown lists in one read: entities (chambers), funds, departments
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_D_LOOKUP (
    LOOKUP_TYPE COMMENT 'ENTITY, FUND or DEPARTMENT',
    CODE, NAME, IS_ACTIVE,
    DISPLAY_ORDER COMMENT 'Sort order (departments); NULL otherwise'
)
COMMENT = 'Values for the app dropdowns: entities, funds and departments.'
AS
SELECT 'ENTITY', ENTITY_CODE, ENTITY_NAME, IS_ACTIVE, NULL FROM APP.T_D_ENTITY
UNION ALL
SELECT 'FUND', FUND_CODE, FUND_NAME, IS_ACTIVE, NULL FROM APP.T_D_FUND
UNION ALL
SELECT 'DEPARTMENT', DEPARTMENT_CODE, DEPARTMENT_NAME, IS_ACTIVE, DISPLAY_ORDER FROM APP.T_D_DEPARTMENT;

/* -------------------------------------------------------------------------------------
   Approval steps in force this month, with their approver: Settings page
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_P_APPROVAL_STEP (
    STEP_ORDER, STEP_TITLE, APPROVER_ROLE, APPLIES_TO, MANAGES_EMPLOYEE_CHECKS, VALID_FROM_PERIOD_KEY,
    APPROVER_EMAIL COMMENT 'Active user holding the step''s role (several separated by ; if the data allows it)',
    APPROVER_NAME  COMMENT 'Display name of that user'
)
COMMENT = 'The approval chain as it applies in the current calendar month, with the assigned approver.'
AS
SELECT
    st.STEP_ORDER,
    st.STEP_TITLE,
    st.APPROVER_ROLE,
    st.APPLIES_TO,
    COALESCE(st.MANAGES_EMPLOYEE_CHECKS, FALSE),
    st.VALID_FROM_PERIOD_KEY,
    LISTAGG(u.USER_EMAIL, '; ')   WITHIN GROUP (ORDER BY u.USER_EMAIL),
    LISTAGG(u.DISPLAY_NAME, '; ') WITHIN GROUP (ORDER BY u.USER_EMAIL)
FROM APP.T_P_APPROVAL_STEP st
LEFT JOIN APP.T_D_APP_USER u ON u.ROLE_CODE = st.APPROVER_ROLE AND u.IS_ACTIVE
WHERE st.IS_ACTIVE
  AND TO_NUMBER(TO_CHAR(CURRENT_DATE(), 'YYYYMM'))
      BETWEEN st.VALID_FROM_PERIOD_KEY AND COALESCE(st.VALID_TO_PERIOD_KEY, 999912)
GROUP BY st.STEP_ORDER, st.STEP_TITLE, st.APPROVER_ROLE, st.APPLIES_TO,
         st.MANAGES_EMPLOYEE_CHECKS, st.VALID_FROM_PERIOD_KEY;

/* -------------------------------------------------------------------------------------
   App users and their role (no signature image): Settings, showing names
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_D_APP_USER (
    USER_EMAIL, DISPLAY_NAME, ROLE_CODE, IS_ACTIVE,
    HAS_SIGNATURE COMMENT 'TRUE when an e-signature image is stored for the user'
)
COMMENT = 'Users of the payroll app with their one role. The signature image itself is not shown.'
AS
SELECT USER_EMAIL, DISPLAY_NAME, ROLE_CODE, IS_ACTIVE, SIGNATURE_IMAGE IS NOT NULL
FROM APP.T_D_APP_USER;

/* -------------------------------------------------------------------------------------
   One row per employee per month with names, totals and the main pay components:
   Dashboard, Approval and Cost Center figures (replaces the Essbase transaction queries)
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_F_PAYROLL_MONTH (
    SCENARIO_ID, PERIOD_KEY, YEAR, MONTH_NUMBER, EMPLOYEE_ID, RESOURCE_CODE,
    FULL_NAME COMMENT 'First and last name',
    EMPLOYMENT_TYPE COMMENT 'Employment type of the contract version used that month',
    ENTITY_CODE, GROSS_PAY_USD, NSSF_EE_USD, NSSF_ER_USD, SALARY_TAX_USD, NET_PAY_USD,
    EMPLOYER_COST_USD,
    BONUS_USD             COMMENT 'BONUS pay line',
    SENIORITY_USD         COMMENT 'SENIORITY pay line',
    OVERTIME_USD          COMMENT 'OVERTIME pay line',
    UNPAID_LEAVE_USD      COMMENT 'UNPAID_LEAVE pay line (negative)',
    OUTSTANDING_LEAVE_USD COMMENT 'OUTSTANDING_LEAVE payout pay line',
    WORKING_DAYS          COMMENT 'Working days applied to the month',
    AVG_DAILY_COST_USD    COMMENT 'Gross pay / working days of the month'
)
COMMENT = 'Payroll per scenario x month x employee: V_F_PAYROLL_SUMMARY totals plus the main components, with names.'
AS
SELECT
    s.SCENARIO_ID,
    s.PERIOD_KEY,
    p.YEAR,
    p.MONTH_NUMBER,
    s.EMPLOYEE_ID,
    e.RESOURCE_CODE,
    TRIM(COALESCE(e.FIRST_NAME, '') || ' ' || COALESCE(e.LAST_NAME, '')),
    c.EMPLOYMENT_TYPE,
    s.ENTITY_CODE,
    s.GROSS_PAY_USD,
    s.NSSF_EE_USD,
    s.NSSF_ER_USD,
    s.SALARY_TAX_USD,
    s.NET_PAY_USD,
    s.EMPLOYER_COST_USD,
    COALESCE(k.BONUS, 0),
    COALESCE(k.SENIORITY, 0),
    COALESCE(k.OVERTIME, 0),
    COALESCE(k.UNPAID, 0),
    COALESCE(k.OUTSTANDING, 0),
    sp.WORKING_DAYS,
    ROUND(s.GROSS_PAY_USD / NULLIF(sp.WORKING_DAYS, 0), 2)
FROM RPT.V_F_PAYROLL_SUMMARY s
JOIN APP.T_D_EMPLOYEE e ON e.EMPLOYEE_ID = s.EMPLOYEE_ID
JOIN APP.T_D_PERIOD p   ON p.PERIOD_KEY = s.PERIOD_KEY
LEFT JOIN APP.T_D_EMPLOYEE_CONTRACT c ON c.CONTRACT_ID = s.EMPLOYEE_VERSION_KEY
LEFT JOIN APP.T_F_SCENARIO_PERIOD sp  ON sp.SCENARIO_ID = s.SCENARIO_ID AND sp.PERIOD_KEY = s.PERIOD_KEY
LEFT JOIN (
    SELECT SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID,
           ROUND(SUM(IFF(PAY_COMPONENT_CODE = 'BONUS',             AMOUNT_USD, 0)), 2) AS BONUS,
           ROUND(SUM(IFF(PAY_COMPONENT_CODE = 'SENIORITY',         AMOUNT_USD, 0)), 2) AS SENIORITY,
           ROUND(SUM(IFF(PAY_COMPONENT_CODE = 'OVERTIME',          AMOUNT_USD, 0)), 2) AS OVERTIME,
           ROUND(SUM(IFF(PAY_COMPONENT_CODE = 'UNPAID_LEAVE',      AMOUNT_USD, 0)), 2) AS UNPAID,
           ROUND(SUM(IFF(PAY_COMPONENT_CODE = 'OUTSTANDING_LEAVE', AMOUNT_USD, 0)), 2) AS OUTSTANDING
    FROM APP.T_F_PAYROLL_LINE
    GROUP BY SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID
) k ON k.SCENARIO_ID = s.SCENARIO_ID AND k.PERIOD_KEY = s.PERIOD_KEY AND k.EMPLOYEE_ID = s.EMPLOYEE_ID;

/* -------------------------------------------------------------------------------------
   Dashboard: one row per calendar month with the actual payroll totals (total and per
   chamber), the applied NBC rate and the official budget / latest forecast gross pay.
   Every month exists (zeros when nothing was paid), so a 12-month chart always has 12
   points. Chamber = the entity of the employee's contract that month.
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_F_DASHBOARD_MONTH (
    PERIOD_KEY, YEAR, MONTH_NUMBER, PERIOD_LABEL,
    SHORT_LABEL        COMMENT 'Chart label, e.g. Oct''26',
    HEADCOUNT          COMMENT 'Employees paid in the actual payroll that month',
    HEADCOUNT_ECCC, HEADCOUNT_CCIFC,
    GROSS_USD, GROSS_ECCC_USD, GROSS_CCIFC_USD,
    NSSF_EE_USD        COMMENT 'Employee NSSF (pension)',
    NSSF_ER_USD        COMMENT 'Employer NSSF (pension, healthcare, occupational risk)',
    NSSF_USD           COMMENT 'Employee + employer NSSF',
    NSSF_ECCC_USD, NSSF_CCIFC_USD,
    NET_USD            COMMENT 'Net pay to bank',
    NET_ECCC_USD, NET_CCIFC_USD,
    TOS_USD            COMMENT 'Salary tax withheld, USD',
    TOS_KHR            COMMENT 'Salary tax withheld, KHR (as calculated)',
    TOS_ECCC_KHR, TOS_CCIFC_KHR,
    FX_RATE_NBC        COMMENT 'NBC rate applied to the actual month (else the published rate)',
    BUDGET_GROSS_USD   COMMENT 'Gross pay of the official budget of that year',
    FORECAST_GROSS_USD COMMENT 'Gross pay of the latest forecast of that year'
)
COMMENT = 'Dashboard figures per calendar month: actual totals (total and per chamber), applied NBC rate, official budget and latest forecast gross pay.'
AS
WITH act AS (
    SELECT s.PERIOD_KEY,
           COUNT(DISTINCT s.EMPLOYEE_ID)                                        AS HC,
           COUNT(DISTINCT IFF(s.ENTITY_CODE = 'ECCC',  s.EMPLOYEE_ID, NULL))    AS HC_E,
           COUNT(DISTINCT IFF(s.ENTITY_CODE = 'CCIFC', s.EMPLOYEE_ID, NULL))    AS HC_C,
           SUM(s.GROSS_PAY_USD)                                                 AS GROSS,
           SUM(IFF(s.ENTITY_CODE = 'ECCC',  s.GROSS_PAY_USD, 0))                AS GROSS_E,
           SUM(IFF(s.ENTITY_CODE = 'CCIFC', s.GROSS_PAY_USD, 0))                AS GROSS_C,
           SUM(s.NSSF_EE_USD)                                                   AS EE,
           SUM(s.NSSF_ER_USD)                                                   AS ER,
           SUM(IFF(s.ENTITY_CODE = 'ECCC',  s.NSSF_EE_USD + s.NSSF_ER_USD, 0))  AS NSSF_E,
           SUM(IFF(s.ENTITY_CODE = 'CCIFC', s.NSSF_EE_USD + s.NSSF_ER_USD, 0))  AS NSSF_C,
           SUM(s.NET_PAY_USD)                                                   AS NET,
           SUM(IFF(s.ENTITY_CODE = 'ECCC',  s.NET_PAY_USD, 0))                  AS NET_E,
           SUM(IFF(s.ENTITY_CODE = 'CCIFC', s.NET_PAY_USD, 0))                  AS NET_C,
           SUM(s.SALARY_TAX_USD)                                                AS TOS_U,
           SUM(s.SALARY_TAX_KHR)                                                AS TOS_K,
           SUM(IFF(s.ENTITY_CODE = 'ECCC',  s.SALARY_TAX_KHR, 0))               AS TOS_E,
           SUM(IFF(s.ENTITY_CODE = 'CCIFC', s.SALARY_TAX_KHR, 0))               AS TOS_C
    FROM RPT.V_F_PAYROLL_SUMMARY s
    JOIN APP.T_D_SCENARIO sc ON sc.SCENARIO_ID = s.SCENARIO_ID AND sc.SCENARIO_TYPE = 'ACTUAL'
    GROUP BY s.PERIOD_KEY
),
plan AS (
    SELECT PERIOD_KEY,
           SUM(BUDGET_GROSS_PAY_USD)   AS BUD,
           SUM(FORECAST_GROSS_PAY_USD) AS FCST
    FROM RPT.V_F_BUDGET_VS_ACTUAL
    GROUP BY PERIOD_KEY
),
actual_scenario AS (
    SELECT MIN(SCENARIO_ID) AS SCENARIO_ID FROM APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'ACTUAL'
)
SELECT
    p.PERIOD_KEY,
    p.YEAR,
    p.MONTH_NUMBER,
    p.PERIOD_LABEL,
    LEFT(p.MONTH_NAME, 3) || '''' || RIGHT(p.YEAR::TEXT, 2),
    COALESCE(a.HC, 0), COALESCE(a.HC_E, 0), COALESCE(a.HC_C, 0),
    ROUND(COALESCE(a.GROSS, 0), 2), ROUND(COALESCE(a.GROSS_E, 0), 2), ROUND(COALESCE(a.GROSS_C, 0), 2),
    ROUND(COALESCE(a.EE, 0), 2), ROUND(COALESCE(a.ER, 0), 2), ROUND(COALESCE(a.EE + a.ER, 0), 2),
    ROUND(COALESCE(a.NSSF_E, 0), 2), ROUND(COALESCE(a.NSSF_C, 0), 2),
    ROUND(COALESCE(a.NET, 0), 2), ROUND(COALESCE(a.NET_E, 0), 2), ROUND(COALESCE(a.NET_C, 0), 2),
    ROUND(COALESCE(a.TOS_U, 0), 2), ROUND(COALESCE(a.TOS_K, 0), 0),
    ROUND(COALESCE(a.TOS_E, 0), 0), ROUND(COALESCE(a.TOS_C, 0), 0),
    COALESCE(sp.FX_RATE_NBC, p.FX_RATE_NBC),
    ROUND(COALESCE(pl.BUD, 0), 2), ROUND(COALESCE(pl.FCST, 0), 2)
FROM APP.T_D_PERIOD p
CROSS JOIN actual_scenario x
LEFT JOIN act a   ON a.PERIOD_KEY = p.PERIOD_KEY
LEFT JOIN plan pl ON pl.PERIOD_KEY = p.PERIOD_KEY
LEFT JOIN APP.T_F_SCENARIO_PERIOD sp ON sp.SCENARIO_ID = x.SCENARIO_ID AND sp.PERIOD_KEY = p.PERIOD_KEY;