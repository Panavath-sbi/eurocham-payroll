-- depends_on: V_F_PAYROLL_SUMMARY, T_F_FUND_ALLOCATION, T_F_DEPARTMENT_ALLOCATION
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_F_COST_ALLOCATION - Grain: one row per scenario x period x employee x fund x department
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-02  V1.5.0: the views move from CORE to RPT (CORE is removed; tables are in APP).
               New V_F_COST_ALLOCATION replaces the dropped T_F_COST_ALLOCATION table.
               V_F_APPROVAL_EVENT reads the change-log rows of APP.T_F_APPROVAL (by
               scenario + period; actions logged before V1.5.0 used a request id and are
               no longer listed).
   2026-10-19  Own file for DLSync (was in R__views_core.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.
   ===================================================================================== */
CREATE OR REPLACE VIEW {{ schema_rpt }}.V_F_COST_ALLOCATION
COPY GRANTS
COMMENT = 'Grain: one row per scenario x period x employee x fund x department. Employee gross pay and employer cost (V_F_PAYROLL_SUMMARY) x fund share x department share. Employees without both a fund and a department split have no rows. Replaces the T_F_COST_ALLOCATION table.'
AS
SELECT
    s.SCENARIO_ID,
    s.PERIOD_KEY,
    s.EMPLOYEE_ID,
    f.FUND_CODE,
    d.DEPARTMENT_CODE,
    s.ENTITY_CODE,
    (f.SHARE_PCT / 100) * (d.SHARE_PCT / 100)                                     AS ALLOCATION_SHARE,
    ROUND(s.GROSS_PAY_USD     * (f.SHARE_PCT / 100) * (d.SHARE_PCT / 100), 2)     AS GROSS_PAY_USD,
    ROUND(s.EMPLOYER_COST_USD * (f.SHARE_PCT / 100) * (d.SHARE_PCT / 100), 2)     AS EMPLOYER_COST_USD
FROM {{ schema_rpt }}.V_F_PAYROLL_SUMMARY s
JOIN {{ schema_app }}.T_F_FUND_ALLOCATION f
  ON f.SCENARIO_ID = s.SCENARIO_ID AND f.PERIOD_KEY = s.PERIOD_KEY AND f.EMPLOYEE_ID = s.EMPLOYEE_ID
JOIN {{ schema_app }}.T_F_DEPARTMENT_ALLOCATION d
  ON d.SCENARIO_ID = s.SCENARIO_ID AND d.PERIOD_KEY = s.PERIOD_KEY AND d.EMPLOYEE_ID = s.EMPLOYEE_ID;
