-- depends_on: {{ ref('t_d_employee') }}, {{ ref('t_d_employee_contract') }}
/* =====================================================================================
   V_D_EMPLOYEE - Employee dimension, SCD Type 2: one row per contract version
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-05  V_D_EMPLOYEE: NON_RESIDENT_FROM and NON_RESIDENT_TO added.
   2026-10-05  V_D_EMPLOYEE: PHONE added (shown and edited on the Employee Register).
   2026-10-06  V_D_EMPLOYEE: BANK_NAME, BANK_ACCOUNT_NAME, BANK_ACCOUNT_NUMBER added; every app
               user may see them, so the Employee Register reads them with the employee list.
   2026-10-07  V_D_EMPLOYEE: IS_CURRENT_VERSION now marks exactly one version per employee,
               based on the calendar month: the version in force this month; else the latest
               version already started (contract ended: the employee stays on the Employee
               Register); else the earliest upcoming one (future start). Before, it was the
               version without an end month, so employees whose contract had ended had no
               current row and disappeared from the register.
   2026-10-19  Own file for DLSync (was in R__views_core.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.
   ===================================================================================== */
/* IS_CURRENT_VERSION (one TRUE row per employee), with M = the current calendar month:
   1. the version with VALID_FROM <= M <= VALID_TO (in force this month);
   2. if none: the version that started last before M (the contract has ended);
   3. if none has started: the version that starts first (future start).
   Versions never overlap, so among the versions already started the latest one is the
   version in force when there is one: rules 1 and 2 are the same ordering. */
CREATE OR REPLACE VIEW {{ rpt() }}.V_D_EMPLOYEE
COPY GRANTS
COMMENT = 'Employee dimension, SCD Type 2: one row per contract version. IS_CURRENT_VERSION marks one version per employee (in force this calendar month, else the latest started, else the first upcoming). Includes the employee''s bank details.'
AS
SELECT
    c.CONTRACT_ID                                           AS EMPLOYEE_VERSION_KEY,
    e.EMPLOYEE_ID,
    e.RESOURCE_CODE,
    e.FIRST_NAME,
    e.LAST_NAME,
    TRIM(COALESCE(e.FIRST_NAME, '') || ' ' || COALESCE(e.LAST_NAME, '')) AS FULL_NAME,
    e.EMAIL,
    e.PHONE,
    e.BANK_NAME,
    e.BANK_ACCOUNT_NAME,
    e.BANK_ACCOUNT_NUMBER,
    e.NATIONALITY,
    e.EMPLOYMENT_START_DATE,
    e.EMPLOYMENT_END_DATE,
    e.IS_ACTIVE                                             AS IS_ACTIVE_EMPLOYEE,
    e.IS_PLANNED,
    e.PLANNED_SCENARIO_ID,
    c.VALID_FROM_PERIOD_KEY,
    COALESCE(c.VALID_TO_PERIOD_KEY, 999912)                 AS VALID_TO_PERIOD_KEY,
    (ROW_NUMBER() OVER (
        PARTITION BY c.EMPLOYEE_ID
        ORDER BY
            -- versions already started first ...
            IFF(c.VALID_FROM_PERIOD_KEY <= TO_NUMBER(TO_CHAR(CURRENT_DATE(), 'YYYYMM')), 0, 1),
            -- ... the latest started one; if none has started, the first upcoming one
            IFF(c.VALID_FROM_PERIOD_KEY <= TO_NUMBER(TO_CHAR(CURRENT_DATE(), 'YYYYMM')),
                -c.VALID_FROM_PERIOD_KEY, c.VALID_FROM_PERIOD_KEY),
            c.CONTRACT_ID DESC
     ) = 1)                                                 AS IS_CURRENT_VERSION,
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
    c.DEPENDANT_CHILDREN + c.DEPENDANT_SPOUSE               AS TOTAL_DEPENDANTS,
    c.INSURANCE_USD,
    c.VISA_USD,
    c.WORK_PERMIT_USD,
    c.FRINGE_BENEFIT_USD
FROM {{ app() }}.T_D_EMPLOYEE e
JOIN {{ app() }}.T_D_EMPLOYEE_CONTRACT c ON c.EMPLOYEE_ID = e.EMPLOYEE_ID;
