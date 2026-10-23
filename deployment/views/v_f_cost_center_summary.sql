-- depends_on: V_F_COST_ALLOCATION, T_D_PERIOD, T_D_FUND, T_D_DEPARTMENT
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_F_COST_CENTER_SUMMARY - Allocated cost per scenario, period, entity, fund and department
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-02  V1.5.0: base views and tables referenced in RPT / APP (CORE removed).
               V_F_COST_CENTER_SUMMARY reads RPT.V_F_COST_ALLOCATION. V_F_APPROVAL_PROGRESS
               reads APP.T_F_APPROVAL by scenario + period (no request id): REQUEST_ID and
               REQUEST_STATUS are replaced by SCENARIO_TYPE, APPROVAL_STATUS (the month's
               or the budget's status) and IS_IN_PROGRESS; ACTION_COMMENT is now STEP_COMMENT.
   2026-10-19  Own file for DLSync (was in R__views_rpt.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.
   ===================================================================================== */
CREATE OR REPLACE VIEW {{ schema_rpt }}.V_F_COST_CENTER_SUMMARY
COPY GRANTS
COMMENT = 'Allocated cost per scenario, period, entity, fund and department.'
AS
SELECT
    a.SCENARIO_ID,
    a.PERIOD_KEY,
    p.PERIOD_LABEL,
    a.ENTITY_CODE,
    a.FUND_CODE,
    fu.FUND_NAME,
    a.DEPARTMENT_CODE,
    d.DEPARTMENT_NAME,
    COUNT(DISTINCT a.EMPLOYEE_ID)      AS EMPLOYEE_COUNT,
    ROUND(SUM(a.GROSS_PAY_USD), 2)     AS GROSS_PAY_USD,
    ROUND(SUM(a.EMPLOYER_COST_USD), 2) AS EMPLOYER_COST_USD
FROM {{ schema_rpt }}.V_F_COST_ALLOCATION a
JOIN {{ schema_app }}.T_D_PERIOD p      ON p.PERIOD_KEY = a.PERIOD_KEY
JOIN {{ schema_app }}.T_D_FUND fu       ON fu.FUND_CODE = a.FUND_CODE
JOIN {{ schema_app }}.T_D_DEPARTMENT d  ON d.DEPARTMENT_CODE = a.DEPARTMENT_CODE
GROUP BY a.SCENARIO_ID, a.PERIOD_KEY, p.PERIOD_LABEL, a.ENTITY_CODE,
         a.FUND_CODE, fu.FUND_NAME, a.DEPARTMENT_CODE, d.DEPARTMENT_NAME;
