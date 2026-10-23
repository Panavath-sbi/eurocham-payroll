-- depends_on: T_F_PAYROLL_LINE, T_D_PAY_COMPONENT
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_F_PAYROLL_SUMMARY - Grain: one row per scenario x period x employee
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-19  Own file for DLSync (was in R__views_core.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.
   ===================================================================================== */
CREATE OR REPLACE VIEW {{ schema_rpt }}.V_F_PAYROLL_SUMMARY
COPY GRANTS
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
FROM {{ schema_app }}.T_F_PAYROLL_LINE l
JOIN {{ schema_app }}.T_D_PAY_COMPONENT pc ON pc.PAY_COMPONENT_CODE = l.PAY_COMPONENT_CODE
GROUP BY l.SCENARIO_ID, l.PERIOD_KEY, l.EMPLOYEE_ID;
