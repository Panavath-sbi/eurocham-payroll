CREATE OR REPLACE VIEW RPT.V_D_EMPLOYEE
COMMENT = 'Employee dimension, SCD Type 2: one row per contract version. IS_CURRENT_VERSION marks one version per employee (in force this calendar month, else the latest started, else the first upcoming). Includes the employee''s bank details.'
AS
SELECT
    c.CONTRACT_ID                       AS EMPLOYEE_VERSION_KEY,
    e.EMPLOYEE_ID,
    e.RESOURCE_CODE,
    e.FIRST_NAME,
    e.LAST_NAME,
    TRIM(COALESCE(e.FIRST_NAME, '') || ' ' || COALESCE(e.LAST_NAME, '')) 
                                        AS FULL_NAME,
    e.EMAIL,
    e.PHONE,
    e.BANK_NAME,
    e.BANK_ACCOUNT_NAME,
    e.BANK_ACCOUNT_NUMBER,
    e.NATIONALITY,
    e.EMPLOYMENT_START_DATE,
    e.EMPLOYMENT_END_DATE,
    e.IS_ACTIVE                         AS IS_ACTIVE_EMPLOYEE,
    e.IS_PLANNED,
    e.PLANNED_SCENARIO_ID,
    c.VALID_FROM_PERIOD_KEY,
    COALESCE(c.VALID_TO_PERIOD_KEY, 999912) AS VALID_TO_PERIOD_KEY,
    (ROW_NUMBER() OVER (
        PARTITION BY c.EMPLOYEE_ID
        ORDER BY
            -- versions already started first ...
            IFF(c.VALID_FROM_PERIOD_KEY <= TO_NUMBER(TO_CHAR(CURRENT_DATE(), 'YYYYMM')), 0, 1),
            -- ... the latest started one; if none has started, the first upcoming one
            IFF(c.VALID_FROM_PERIOD_KEY <= TO_NUMBER(TO_CHAR(CURRENT_DATE(), 'YYYYMM')),
                -c.VALID_FROM_PERIOD_KEY, c.VALID_FROM_PERIOD_KEY),
            c.CONTRACT_ID DESC
     ) = 1)                               AS IS_CURRENT_VERSION,
    c.POSITION,
    c.EMPLOYMENT_TYPE,
    c.CONTRACT_TYPE,
    c.ENTITY_CODE,
    c.MONTHLY_SALARY_USD,
    c.TAX_STATUS,
    c.NON_RESIDENT_FROM,
    c.NON_RESIDENT_TO,
    c.DEPENDANT_CHILDREN,
    c.DEPENDANT_SPOUSE,
    c.DEPENDANT_CHILDREN + c.DEPENDANT_SPOUSE AS TOTAL_DEPENDANTS,
    c.INSURANCE_USD,
    c.VISA_USD,
    c.WORK_PERMIT_USD,
    c.FRINGE_BENEFIT_USD
FROM APP.T_D_EMPLOYEE e
JOIN APP.T_D_EMPLOYEE_CONTRACT c 
ON c.EMPLOYEE_ID = e.EMPLOYEE_ID;
