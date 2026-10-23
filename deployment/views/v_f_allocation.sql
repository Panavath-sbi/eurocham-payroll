-- depends_on: T_F_FUND_ALLOCATION, T_D_FUND, T_F_DEPARTMENT_ALLOCATION, T_D_DEPARTMENT
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_F_ALLOCATION - Fund and department splits per scenario, month and employee (percent, each type totals 100)
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
COPY GRANTS
COMMENT = 'Fund and department splits per scenario, month and employee (percent, each type totals 100).'
AS
SELECT f.SCENARIO_ID, f.PERIOD_KEY, f.EMPLOYEE_ID, 'FUND', f.FUND_CODE, fu.FUND_NAME, f.SHARE_PCT
FROM APP.T_F_FUND_ALLOCATION f
JOIN APP.T_D_FUND fu ON fu.FUND_CODE = f.FUND_CODE
UNION ALL
SELECT d.SCENARIO_ID, d.PERIOD_KEY, d.EMPLOYEE_ID, 'DEPARTMENT', d.DEPARTMENT_CODE, de.DEPARTMENT_NAME, d.SHARE_PCT
FROM APP.T_F_DEPARTMENT_ALLOCATION d
JOIN APP.T_D_DEPARTMENT de ON de.DEPARTMENT_CODE = d.DEPARTMENT_CODE;
