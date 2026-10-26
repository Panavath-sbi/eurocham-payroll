-- depends_on: V_F_PAYROLL_SUMMARY, T_D_EMPLOYEE, T_D_PERIOD, T_D_EMPLOYEE_CONTRACT, T_F_SCENARIO_PERIOD, T_F_PAYROLL_LINE
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_F_PAYROLL_MONTH - Payroll per scenario x month x employee: V_F_PAYROLL_SUMMARY totals plus the main components, with names
   =====================================================================================

   HISTORY
   -------
   2026-10-05  Initial version: V_D_PERIOD, V_F_SCENARIO_PERIOD, V_F_PAYROLL_INPUT,
               V_F_ALLOCATION, V_D_SCENARIO_EMPLOYEE, V_F_PAYROLL_LINE, V_D_LOOKUP,
               V_P_APPROVAL_STEP, V_D_APP_USER.
   2026-10-05  V_F_PAYROLL_MONTH added (one row per employee per month with the totals
               and the main components; replaces the app's Essbase transaction queries).
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
COPY GRANTS
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
