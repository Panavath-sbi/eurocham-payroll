-- depends_on: T_F_PAYROLL_INPUT, T_D_EMPLOYEE
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_F_PAYROLL_INPUT - Monthly inputs per scenario, month and employee, with the employee check (actual payroll)
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
   Monthly inputs with names and the employee check: Monthly Inputs grid, Approval
   validation buttons, budget "Show Details"
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW {{ schema_rpt }}.V_F_PAYROLL_INPUT (
    SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, RESOURCE_CODE,
    FULL_NAME COMMENT 'First and last name',
    INCLUDE_IN_PAYROLL, ABSENCE_DAYS, OVERTIME_DAYS, OUTSTANDING_DAYS, BONUS_USD,
    SALARY_OVERRIDE_USD, FRINGE_BENEFIT_OVERRIDE_USD, NOTES,
    CHECK_STATUS, CHECK_COMMENT, CHECKED_BY,
    UPDATED_AT COMMENT 'When the row was last changed',
    UPDATED_BY COMMENT 'Who last changed the row'
)
COPY GRANTS
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
FROM {{ schema_app }}.T_F_PAYROLL_INPUT i
JOIN {{ schema_app }}.T_D_EMPLOYEE e ON e.EMPLOYEE_ID = i.EMPLOYEE_ID;
