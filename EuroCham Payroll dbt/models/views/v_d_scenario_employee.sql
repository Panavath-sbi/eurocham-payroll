-- depends_on: {{ ref('t_d_scenario_employee') }}, {{ ref('t_d_employee') }}, {{ ref('t_d_employee_contract') }}, {{ ref('t_f_scenario_period') }}, {{ ref('t_f_payroll_input') }}
/* =====================================================================================
   V_D_SCENARIO_EMPLOYEE - Employee terms per budget or forecast scenario, including planned hires
   =====================================================================================

   HISTORY
   -------
   2026-10-05  Initial version: V_D_PERIOD, V_F_SCENARIO_PERIOD, V_F_PAYROLL_INPUT,
               V_F_ALLOCATION, V_D_SCENARIO_EMPLOYEE, V_F_PAYROLL_LINE, V_D_LOOKUP,
               V_P_APPROVAL_STEP, V_D_APP_USER.
   2026-10-06  V_D_SCENARIO_EMPLOYEE: adds START_PERIOD_KEY / END_PERIOD_KEY (first and last
               month the employee is paid in the scenario) and BONUS_USD (the year's bonus
               inputs) for the Budget Input grid and the planned-hire dialog.
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
   Employee terms inside a budget or forecast: Budget Input grid, Forecast page
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_D_SCENARIO_EMPLOYEE (
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
COPY GRANTS
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
FROM T_D_SCENARIO_EMPLOYEE se
JOIN T_D_EMPLOYEE e ON e.EMPLOYEE_ID = se.EMPLOYEE_ID
LEFT JOIN (SELECT EMPLOYEE_ID, MAX(VALID_FROM_PERIOD_KEY) AS LAST_FROM
           FROM T_D_EMPLOYEE_CONTRACT GROUP BY EMPLOYEE_ID) lc
       ON lc.EMPLOYEE_ID = se.EMPLOYEE_ID
LEFT JOIN (SELECT x.SCENARIO_ID, se2.EMPLOYEE_ID,
                  MIN(IFF(COALESCE(i.INCLUDE_IN_PAYROLL, TRUE), x.PERIOD_KEY, NULL)) AS START_PK,
                  MAX(IFF(COALESCE(i.INCLUDE_IN_PAYROLL, TRUE), x.PERIOD_KEY, NULL)) AS END_PK,
                  SUM(COALESCE(i.BONUS_USD, 0))                                       AS BONUS
           FROM T_F_SCENARIO_PERIOD x
           JOIN T_D_SCENARIO_EMPLOYEE se2 ON se2.SCENARIO_ID = x.SCENARIO_ID
           LEFT JOIN T_F_PAYROLL_INPUT i
                  ON i.SCENARIO_ID = x.SCENARIO_ID AND i.PERIOD_KEY = x.PERIOD_KEY AND i.EMPLOYEE_ID = se2.EMPLOYEE_ID
           GROUP BY x.SCENARIO_ID, se2.EMPLOYEE_ID) pm
       ON pm.SCENARIO_ID = se.SCENARIO_ID AND pm.EMPLOYEE_ID = se.EMPLOYEE_ID;
