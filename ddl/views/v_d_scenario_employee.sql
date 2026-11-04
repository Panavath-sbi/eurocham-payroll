CREATE OR REPLACE VIEW RPT.V_D_SCENARIO_EMPLOYEE 
(
    SCENARIO_ID, 
    EMPLOYEE_ID, 
    RESOURCE_CODE,
    FULL_NAME      COMMENT 'First and last name',
    IS_PLANNED, 
    POSITION, 
    EMPLOYMENT_TYPE, 
    CONTRACT_TYPE, 
    ENTITY_CODE,
    MONTHLY_SALARY_USD, 
    RAISE_PCT, 
    REVALUATION_PERIOD_KEY, 
    FINAL_SALARY_USD,
    TAX_STATUS, 
    DEPENDANT_CHILDREN, 
    DEPENDANT_SPOUSE,
    INSURANCE_USD, 
    VISA_USD, 
    WORK_PERMIT_USD, 
    FRINGE_BENEFIT_USD,
    LAST_CONTRACT_CHANGE_PERIOD_KEY COMMENT 'First month of the employee''s latest actual contract version (shown as the latest raise date); NULL for planned hires',
    START_PERIOD_KEY                COMMENT 'First month of the scenario in which the employee is paid (a month without an input row counts as paid)',
    END_PERIOD_KEY                  COMMENT 'Last month of the scenario in which the employee is paid',
    BONUS_USD                       COMMENT 'Sum of the bonus inputs of the employee over the scenario''s months (budget: entered in March)'
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
LEFT JOIN 
        (
            SELECT 
                EMPLOYEE_ID, 
                MAX(VALID_FROM_PERIOD_KEY) AS LAST_FROM
            FROM APP.T_D_EMPLOYEE_CONTRACT 
            GROUP BY EMPLOYEE_ID
        ) lc
ON lc.EMPLOYEE_ID = se.EMPLOYEE_ID
LEFT JOIN (
            SELECT 
                x.SCENARIO_ID, 
                se2.EMPLOYEE_ID,
                MIN(IFF(COALESCE(i.INCLUDE_IN_PAYROLL, TRUE), x.PERIOD_KEY, NULL)) AS START_PK,
                MAX(IFF(COALESCE(i.INCLUDE_IN_PAYROLL, TRUE), x.PERIOD_KEY, NULL)) AS END_PK,
                SUM(COALESCE(i.BONUS_USD, 0))                                       AS BONUS
            FROM APP.T_F_SCENARIO_PERIOD x
            JOIN APP.T_D_SCENARIO_EMPLOYEE se2 
                ON se2.SCENARIO_ID = x.SCENARIO_ID
            LEFT JOIN APP.T_F_PAYROLL_INPUT i
                  ON i.SCENARIO_ID = x.SCENARIO_ID 
                  AND i.PERIOD_KEY = x.PERIOD_KEY 
                  AND i.EMPLOYEE_ID = se2.EMPLOYEE_ID
           GROUP BY x.SCENARIO_ID, se2.EMPLOYEE_ID) pm
       ON pm.SCENARIO_ID = se.SCENARIO_ID 
       AND pm.EMPLOYEE_ID = se.EMPLOYEE_ID;
