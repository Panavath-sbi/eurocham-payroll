/* =====================================================================================
   TESTS 03 - READS OF THE "PAYROLL - READ" FLOW
   Runs every read of flows/read_catalog.json with dummy values, so each one can be
   checked in Snowsight before the flow exists. Run after the rebuild (tests 01 and 02
   are not needed). Each query should return rows without an error.
   =====================================================================================

   HISTORY
   -------
   2026-10-05  Initial version (generated from the same list as flows/read_catalog.json).
   ===================================================================================== */

-- {S} = scenario id, {P} = month YYYYMM (or a year where noted), {E} = employee id
SET S = (SELECT SCENARIO_ID FROM APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'ACTUAL');
SET P = 202610;
SET Y = 2026;
SET E = (SELECT EMPLOYEE_ID FROM APP.T_D_EMPLOYEE WHERE RESOURCE_CODE = 'HR-KH-001');

-- Lookups  (filters: -) - Dropdowns (chambers, funds, departments)
SELECT * FROM RPT.V_D_LOOKUP WHERE IS_ACTIVE ORDER BY LOOKUP_TYPE, DISPLAY_ORDER, NAME;

-- Scenarios  (filters: -) - Scenario / quarter dropdowns; the actual scenario id
SELECT * FROM RPT.V_D_SCENARIO ORDER BY SCENARIO_TYPE, FISCAL_YEAR DESC, SCENARIO_NAME;

-- ScenarioPeriods  (filters: S) - Period dropdown, FX card, which month is open
SELECT * FROM RPT.V_F_SCENARIO_PERIOD WHERE SCENARIO_ID = $S ORDER BY PERIOD_KEY;

-- Calendar  (filters: P = year) - Settings: working days; next month's rates
SELECT * FROM RPT.V_D_PERIOD WHERE YEAR = $Y ORDER BY PERIOD_KEY;

-- Employees  (filters: -) - Employee Register, Cost Center list
SELECT * FROM RPT.V_D_EMPLOYEE WHERE IS_CURRENT_VERSION AND NOT IS_PLANNED ORDER BY FULL_NAME;

-- EmployeeHistory  (filters: E) - Edit Employee: contract versions
SELECT * FROM RPT.V_D_EMPLOYEE WHERE EMPLOYEE_ID = $E ORDER BY VALID_FROM_PERIOD_KEY;

-- MonthlyInputs  (filters: S, P) - Monthly Inputs grid; Approval validation buttons
SELECT * FROM RPT.V_F_PAYROLL_INPUT WHERE SCENARIO_ID = $S AND PERIOD_KEY = $P ORDER BY FULL_NAME;

-- ScenarioInputs  (filters: S) - Budget / Forecast Show Details
SELECT * FROM RPT.V_F_PAYROLL_INPUT WHERE SCENARIO_ID = $S ORDER BY FULL_NAME, PERIOD_KEY;

-- Allocations  (filters: S, P) - Cost Center: fund and department panels
SELECT * FROM RPT.V_F_ALLOCATION WHERE SCENARIO_ID = $S AND PERIOD_KEY = $P ORDER BY EMPLOYEE_ID, ALLOCATION_TYPE, ALLOCATION_CODE;

-- PayrollSummary  (filters: S, P) - Approval grid, Cost Center summary
SELECT * FROM RPT.V_F_PAYROLL_SUMMARY WHERE SCENARIO_ID = $S AND PERIOD_KEY = $P;

-- ScenarioPayroll  (filters: S) - Previous month / 6-month average; Budget Approval and Forecast grids
SELECT * FROM RPT.V_F_PAYROLL_SUMMARY WHERE SCENARIO_ID = $S ORDER BY PERIOD_KEY, EMPLOYEE_ID;

-- PayrollLines  (filters: S, P) - Cards by component (bonus, seniority, ToS)
SELECT * FROM RPT.V_F_PAYROLL_LINE WHERE SCENARIO_ID = $S AND PERIOD_KEY = $P ORDER BY EMPLOYEE_ID, DISPLAY_ORDER;

-- ScenarioPayrollLines  (filters: S) - Budget Approval / Forecast cards by component
SELECT * FROM RPT.V_F_PAYROLL_LINE WHERE SCENARIO_ID = $S ORDER BY PERIOD_KEY, EMPLOYEE_ID, DISPLAY_ORDER;

-- CostCenterSummary  (filters: S, P) - Cost Center: department bars
SELECT * FROM RPT.V_F_COST_CENTER_SUMMARY WHERE SCENARIO_ID = $S AND PERIOD_KEY = $P ORDER BY DEPARTMENT_CODE, FUND_CODE;

-- ScenarioSummary  (filters: S) - Dashboard trend; Budget and Forecast KPI cards
SELECT * FROM RPT.V_F_SCENARIO_SUMMARY WHERE SCENARIO_ID = $S ORDER BY PERIOD_KEY, ENTITY_CODE;

-- DashboardKpi  (filters: -) - Dashboard cards
SELECT * FROM RPT.V_F_DASHBOARD_KPI ORDER BY ENTITY_CODE;

-- BudgetVsActual  (filters: P = year) - Dashboard budget vs forecast; Approval budget/forecast
SELECT * FROM RPT.V_F_BUDGET_VS_ACTUAL WHERE YEAR = $Y ORDER BY PERIOD_KEY, ENTITY_CODE;

-- ApprovalProgress  (filters: S, P (0 for a budget)) - Approval chain on every approval page
SELECT * FROM RPT.V_F_APPROVAL_PROGRESS WHERE SCENARIO_ID = $S AND PERIOD_KEY = $P ORDER BY STEP_ORDER;

-- ScenarioEmployees  (filters: S) - Budget Input grid, Forecast
SELECT * FROM RPT.V_D_SCENARIO_EMPLOYEE WHERE SCENARIO_ID = $S ORDER BY FULL_NAME;

-- ApprovalSteps  (filters: -) - Settings: approval steps and approvers
SELECT * FROM RPT.V_P_APPROVAL_STEP ORDER BY STEP_ORDER;

-- Users  (filters: -) - Settings; showing names
SELECT * FROM RPT.V_D_APP_USER ORDER BY DISPLAY_NAME;
