CREATE OR REPLACE VIEW RPT.V_F_PAYROLL_INPUT 
(
    SCENARIO_ID, 
    PERIOD_KEY, 
    EMPLOYEE_ID, 
    RESOURCE_CODE,
    FULL_NAME COMMENT 'First and last name',
    INCLUDE_IN_PAYROLL, 
    ABSENCE_DAYS, 
    OVERTIME_DAYS, 
    OUTSTANDING_DAYS, 
    BONUS_USD,
    SALARY_OVERRIDE_USD, 
    FRINGE_BENEFIT_OVERRIDE_USD, 
    NOTES,
    CHECK_STATUS, 
    CHECK_COMMENT, 
    CHECKED_BY,
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
JOIN APP.T_D_EMPLOYEE e 
    ON e.EMPLOYEE_ID = i.EMPLOYEE_ID;
