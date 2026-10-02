/* =====================================================================================
   R - CORE VIEWS
   V_D_EMPLOYEE, V_D_SCENARIO, V_F_PAYROLL_SUMMARY, V_F_APPROVAL_EVENT.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-02  V_F_APPROVAL_EVENT reads the approval history from APP.T_F_CHANGE_LOG
               (APP.T_F_APPROVAL_ACTION was dropped in V1.4.0).
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).
   ===================================================================================== */

/* =====================================================================================
   5. CORE - DIMENSION AND FACT VIEWS (V_D_ / V_F_)
   ===================================================================================== */

CREATE OR REPLACE VIEW CORE.V_D_EMPLOYEE
COMMENT = 'Employee dimension, SCD Type 2: one row per contract version. Bank details are deliberately excluded.'
AS
SELECT
    c.CONTRACT_ID                                           AS EMPLOYEE_VERSION_KEY,
    e.EMPLOYEE_ID,
    e.RESOURCE_CODE,
    e.FIRST_NAME,
    e.LAST_NAME,
    TRIM(COALESCE(e.FIRST_NAME, '') || ' ' || COALESCE(e.LAST_NAME, '')) AS FULL_NAME,
    e.EMAIL,
    e.NATIONALITY,
    e.EMPLOYMENT_START_DATE,
    e.EMPLOYMENT_END_DATE,
    e.IS_ACTIVE                                             AS IS_ACTIVE_EMPLOYEE,
    e.IS_PLANNED,
    e.PLANNED_SCENARIO_ID,
    c.VALID_FROM_PERIOD_KEY,
    COALESCE(c.VALID_TO_PERIOD_KEY, 999912)                 AS VALID_TO_PERIOD_KEY,
    (c.VALID_TO_PERIOD_KEY IS NULL)                         AS IS_CURRENT_VERSION,
    c.POSITION,
    c.EMPLOYMENT_TYPE,
    c.CONTRACT_TYPE,
    c.ENTITY_CODE,
    c.MONTHLY_SALARY_USD,
    c.TAX_STATUS,
    c.DEPENDANT_CHILDREN,
    c.DEPENDANT_SPOUSE,
    c.DEPENDANT_CHILDREN + c.DEPENDANT_SPOUSE               AS TOTAL_DEPENDANTS,
    c.INSURANCE_USD,
    c.VISA_USD,
    c.WORK_PERMIT_USD,
    c.FRINGE_BENEFIT_USD
FROM APP.T_D_EMPLOYEE e
JOIN APP.T_D_EMPLOYEE_CONTRACT c ON c.EMPLOYEE_ID = e.EMPLOYEE_ID;

CREATE OR REPLACE VIEW CORE.V_D_SCENARIO
COMMENT = 'Scenario dimension for reporting: actual payroll, budget scenarios and forecast versions.'
AS
SELECT
    SCENARIO_ID,
    SCENARIO_TYPE,
    SCENARIO_NAME,
    FISCAL_YEAR,
    SCENARIO_STATUS,
    IS_OFFICIAL,
    BASE_SCENARIO_ID,
    FORECAST_AS_OF_PERIOD_KEY,
    DESCRIPTION
FROM APP.T_D_SCENARIO;

CREATE OR REPLACE VIEW CORE.V_F_PAYROLL_SUMMARY
COMMENT = 'Grain: one row per scenario x period x employee. Totals aggregated from T_F_PAYROLL_LINE by pay component category.'
AS
SELECT
    l.SCENARIO_ID,
    l.PERIOD_KEY,
    l.EMPLOYEE_ID,
    MAX(l.EMPLOYEE_VERSION_KEY)                                                     AS EMPLOYEE_VERSION_KEY,
    MAX(l.ENTITY_CODE)                                                              AS ENTITY_CODE,
    ROUND(SUM(IFF(pc.CATEGORY = 'EARNING', l.AMOUNT_USD, 0)), 2)                    AS GROSS_PAY_USD,
    ROUND(SUM(IFF(pc.CATEGORY = 'EARNING', l.AMOUNT_KHR, 0)), 0)                    AS GROSS_PAY_KHR,
    ROUND(SUM(IFF(pc.PAY_COMPONENT_CODE = 'NSSF_EE_PENSION', l.AMOUNT_USD, 0)), 2)  AS NSSF_EE_USD,
    ROUND(SUM(IFF(pc.PAY_COMPONENT_CODE = 'SALARY_TAX', l.AMOUNT_USD, 0)), 2)       AS SALARY_TAX_USD,
    ROUND(SUM(IFF(pc.PAY_COMPONENT_CODE = 'SALARY_TAX', l.AMOUNT_KHR, 0)), 0)       AS SALARY_TAX_KHR,
    ROUND(SUM(IFF(pc.CATEGORY = 'EMPLOYEE_DEDUCTION', l.AMOUNT_USD, 0)), 2)         AS TOTAL_DEDUCTIONS_USD,
    ROUND(SUM(IFF(pc.CATEGORY = 'EMPLOYEE_DEDUCTION', l.AMOUNT_KHR, 0)), 0)         AS TOTAL_DEDUCTIONS_KHR,
    ROUND(GROSS_PAY_USD - TOTAL_DEDUCTIONS_USD, 2)                                  AS NET_PAY_USD,
    ROUND(GROSS_PAY_KHR - TOTAL_DEDUCTIONS_KHR, 0)                                  AS NET_PAY_KHR,
    ROUND(SUM(IFF(pc.CATEGORY = 'EMPLOYER_CONTRIBUTION', l.AMOUNT_USD, 0)), 2)      AS NSSF_ER_USD,
    ROUND(SUM(IFF(pc.CATEGORY = 'EMPLOYER_COST', l.AMOUNT_USD, 0)), 2)              AS OTHER_EMPLOYER_COST_USD,
    ROUND(GROSS_PAY_USD + NSSF_ER_USD + OTHER_EMPLOYER_COST_USD, 2)                 AS EMPLOYER_COST_USD,
    MAX(l.INSERT_DATE)                                                              AS CALCULATED_AT
FROM CORE.T_F_PAYROLL_LINE l
JOIN CORE.T_D_PAY_COMPONENT pc ON pc.PAY_COMPONENT_CODE = l.PAY_COMPONENT_CODE
GROUP BY l.SCENARIO_ID, l.PERIOD_KEY, l.EMPLOYEE_ID;

CREATE OR REPLACE VIEW CORE.V_F_APPROVAL_EVENT
COMMENT = 'Grain: one row per approval action (approve, reject, send back, undo, reset), read from the change log, with the scenario and period it relates to.'
AS
SELECT
    c.CHANGE_ID                      AS ACTION_ID,
    c.RECORD_KEY:REQUEST_ID::INT     AS REQUEST_ID,
    r.SCENARIO_ID,
    r.PERIOD_KEY,
    c.RECORD_KEY:STEP_ORDER::INT     AS STEP_ORDER,
    c.NEW_VALUES:ACTION_TYPE::TEXT   AS ACTION_TYPE,
    c.CHANGED_BY                     AS ACTED_BY,
    c.INSERT_DATE                    AS ACTED_AT,
    c.NEW_VALUES:COMMENT::TEXT       AS ACTION_COMMENT
FROM APP.T_F_CHANGE_LOG c
JOIN APP.T_F_APPROVAL_REQUEST r ON r.REQUEST_ID = c.RECORD_KEY:REQUEST_ID::INT
WHERE c.TABLE_NAME = 'APP.T_F_APPROVAL_STEP_STATE';
