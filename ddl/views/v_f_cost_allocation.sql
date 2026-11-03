
CREATE OR REPLACE VIEW RPT.V_F_COST_ALLOCATION
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
FROM RPT.V_F_PAYROLL_SUMMARY s
JOIN APP.T_F_FUND_ALLOCATION f
  ON f.SCENARIO_ID = s.SCENARIO_ID AND f.PERIOD_KEY = s.PERIOD_KEY AND f.EMPLOYEE_ID = s.EMPLOYEE_ID
JOIN APP.T_F_DEPARTMENT_ALLOCATION d
  ON d.SCENARIO_ID = s.SCENARIO_ID AND d.PERIOD_KEY = s.PERIOD_KEY AND d.EMPLOYEE_ID = s.EMPLOYEE_ID;
