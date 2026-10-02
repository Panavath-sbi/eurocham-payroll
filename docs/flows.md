# Payroll App – Page & Data Flow Documentation

## How the app talks to Snowflake

Every Power Apps page reads from views and writes through stored procedures; no page writes to a table directly. This document lists, page by page, which objects each action reads and writes. Procedure names are proposed and not yet built.

| Schema | Holds | Written by | Read by |
| --- | --- | --- | --- |
| APP | Business inputs and workflow: employees, contracts, scenarios, monthly inputs, allocations, approvals, change log | Power Apps, through SP_ procedures | Procedures, calculation |
| CORE | Shared dimensions, parameters and calculated facts | Setup scripts; admins through SP_ procedures; facts only by the calculation | Views, calculation |
| RPT | Reporting views only | Nobody | Power Apps pages |

Rules that apply on every page:

- Every save procedure receives the app user email from Power Apps, checks the user role in T_D_APP_USER_ROLE, sets INSERT_BY / UPDATE_BY to that email, and writes a row to T_F_CHANGE_LOG.
- Only the open actual period (PERIOD_STATUS = OPEN in T_F_SCENARIO_PERIOD) accepts payroll edits. Finalized periods are read-only.
- Any edit to an open period that already has approvals sets the approved steps back to PENDING in T_F_APPROVAL_STEP_STATE (LAST_ACTION = RESET, logged in T_F_CHANGE_LOG) and clears the changed employees' checks, so approvers review the changed numbers.
- After an input changes, the procedure calls SP_CALCULATE_PAYROLL, which rewrites that period's rows in T_F_PAYROLL_LINE and T_F_COST_ALLOCATION.
- Nothing is ever deleted from actual payroll. Employees are deactivated with IS_ACTIVE; closed months are corrected through T_F_PAYROLL_ADJUSTMENT.

## 1. Dashboard

Read-only. The page queries four views and writes nothing.

| Page element | Reads | Notes |
| --- | --- | --- |
| KPI cards (active employees, gross, NSSF, net to bank, ToS, split by ECCC / CCIFC) | RPT.V_F_DASHBOARD_KPI | Latest actual period; the ALL row gives totals, the entity rows give the split |
| FX rate card | APP.T_F_SCENARIO_PERIOD | NBC rate of the latest actual period |
| Payroll cost breakdown (donut) | RPT.V_F_DASHBOARD_KPI | Net, ToS, NSSF EE, NSSF ER from the ALL row |
| Approval status | RPT.V_F_APPROVAL_PROGRESS | Filter on the latest actual period; percent = approved steps / total steps |
| Monthly cost and headcount trend (6M / 12M) | RPT.V_F_SCENARIO_SUMMARY | Filter SCENARIO_TYPE = ACTUAL, last 6 or 12 periods, split by ENTITY_CODE |
| Monthly budget vs forecast | RPT.V_F_BUDGET_VS_ACTUAL | Filter on the selected fiscal year |

## 2. Employee Register

Manages who employees are (T_D_EMPLOYEE) and what they are paid (T_D_EMPLOYEE_CONTRACT). A pay change never overwrites; it closes the current contract version and adds a new one.

| Action | Reads | Writes | Procedure |
| --- | --- | --- | --- |
| Load the list | CORE.V_D_EMPLOYEE (IS_CURRENT_VERSION = TRUE, IS_PLANNED = FALSE) | – | – |
| Open Edit Employee Info | CORE.V_D_EMPLOYEE; APP.T_D_EMPLOYEE for bank details (masked unless admin) | – | – |
| Create employee | CORE.T_D_ENTITY for the Chambers dropdown | New row in APP.T_D_EMPLOYEE; first row in APP.T_D_EMPLOYEE_CONTRACT (VALID_FROM = open period, VALID_TO = NULL); T_F_CHANGE_LOG | SP_SAVE_EMPLOYEE |
| Edit identity fields (name, email, phone, nationality, bank, start/end date) | – | Update APP.T_D_EMPLOYEE in place; T_F_CHANGE_LOG | SP_SAVE_EMPLOYEE |
| Edit pay fields (salary, chamber, employment type, position, contract type, residency, dependants, insurance, visa, work permit) | – | Close current contract (VALID_TO = period before the effective month); insert new contract version; T_F_CHANGE_LOG | SP_SAVE_EMPLOYEE_CONTRACT |
| Pay Adjustments field (e.g. +350) | – | Power Apps adds it to the base salary (4,650 + 350 = 5,000) and sends 5,000 as the new salary; stored as a new contract version, same as above | SP_SAVE_EMPLOYEE_CONTRACT |
| Deactivate (Active toggle off) | – | APP.T_D_EMPLOYEE.IS_ACTIVE = FALSE; T_F_CHANGE_LOG | SP_SET_EMPLOYEE_ACTIVE |

Notes:

- The effective month of a pay change defaults to the open period. If the change hits the open period, the procedure also re-runs SP_CALCULATE_PAYROLL and resets its approvals.
- If the edit is only a correction of the current version (a typo, not a real change), the procedure may update that version in place, but only while no finalized period uses it.
- Deactivated employees stay in history; SP_OPEN_PAYROLL_PERIOD skips them from the next month on.
- Employees are never deleted. Planned hires (IS_PLANNED = TRUE) never appear here.

## 3. Cost Center

Sets how each employee's cost is split across funds and departments for the open period. Both splits are stored as percentages and must total 100%.

| Action | Reads | Writes | Procedure |
| --- | --- | --- | --- |
| Employee list | CORE.V_D_EMPLOYEE (current versions, active) | – | – |
| Department cost distribution (bars) | RPT.V_F_COST_CENTER_SUMMARY, open period, grouped by department | – | – |
| Information summary (salary, insurance, visa, work permit, avg. daily cost) | CORE.V_D_EMPLOYEE; CORE.V_F_PAYROLL_SUMMARY for the open period | – | – |
| Working days panel (ECCC / CCIFC / EU Gate days) | APP.T_F_FUND_ALLOCATION; working days from APP.T_F_SCENARIO_PERIOD | – | – |
| Save fund split | – | Replace the employee's rows in APP.T_F_FUND_ALLOCATION; T_F_CHANGE_LOG | SP_SAVE_FUND_ALLOCATION |
| Cost center distribution panel | APP.T_F_DEPARTMENT_ALLOCATION | – | – |
| Save department split | – | Replace the employee's rows in APP.T_F_DEPARTMENT_ALLOCATION; T_F_CHANGE_LOG | SP_SAVE_DEPARTMENT_ALLOCATION |

Notes:

- The page enters funds as days. The procedure converts days to a percentage (days ÷ working days × 100) and the page converts back for display.
- Both save procedures reject a split that does not total 100%. There is no Default department.
- After a save, SP_CALCULATE_PAYROLL rewrites CORE.T_F_COST_ALLOCATION for that employee, and approvals reset if they had started.
- When a new month opens, SP_OPEN_PAYROLL_PERIOD copies each employee's splits from the previous month.

## 4. Monthly Inputs

The payroll admin works the open month here: variable inputs, exchange rates, opening the next month, and the first approval step.

| Action | Reads | Writes | Procedure |
| --- | --- | --- | --- |
| Period dropdown | APP.T_F_SCENARIO_PERIOD (actual scenario), labels from CORE.T_D_PERIOD | – | – |
| Input grid (overtime days, unpaid leave days, outstanding days, bonus) | APP.T_F_PAYROLL_INPUT joined to CORE.V_D_EMPLOYEE | – | – |
| Edit an employee's inputs | – | Update APP.T_F_PAYROLL_INPUT; T_F_CHANGE_LOG; RESET approvals if started; recalculate | SP_SAVE_MONTHLY_INPUT |
| Exchange rates panel | APP.T_F_SCENARIO_PERIOD (FX_RATE_NBC, FX_RATE_NSSF) | – | – |
| Save exchange rates | – | Upsert CORE.T_P_FX_RATE (published rate) and update APP.T_F_SCENARIO_PERIOD (applied rate); T_F_CHANGE_LOG; recalculate | SP_SAVE_EXCHANGE_RATE |
| Create next month's payroll | CORE.T_D_PERIOD (working days), CORE.T_P_FX_RATE, APP.T_D_EMPLOYEE (IS_ACTIVE) | New row in APP.T_F_SCENARIO_PERIOD (OPEN); one empty row per active employee in APP.T_F_PAYROLL_INPUT; allocations copied into APP.T_F_FUND_ALLOCATION and APP.T_F_DEPARTMENT_ALLOCATION; new APP.T_F_APPROVAL_REQUEST with one PENDING row per step in APP.T_F_APPROVAL_STEP_STATE; first calculation | SP_OPEN_PAYROLL_PERIOD |
| View Rejected Only | APP.T_F_APPROVAL_EMPLOYEE_CHECK (CHECK_STATUS = REJECTED) | – | – |
| Approval chain | RPT.V_F_APPROVAL_PROGRESS, sorted by STEP_ORDER | – | – |
| Approve (step 1) | RPT.V_F_APPROVAL_PROGRESS (no employee checks needed) | Step 1 to APPROVED in APP.T_F_APPROVAL_STEP_STATE (with comment); T_F_SCENARIO_PERIOD to IN_APPROVAL; T_F_CHANGE_LOG | SP_APPROVE_STEP |
| Undo approval | – | Step back to PENDING in APP.T_F_APPROVAL_STEP_STATE (LAST_ACTION = UNDO); T_F_CHANGE_LOG | SP_UNDO_APPROVAL |
| Treasurer / Director comment boxes | RPT.V_F_APPROVAL_PROGRESS.ACTION_COMMENT for steps 2 and 3 | – | – |
| Add a correction for a closed month | – | Row in APP.T_F_PAYROLL_ADJUSTMENT; recalculate | SP_SAVE_PAYROLL_ADJUSTMENT |

Notes:

- Create next month's payroll only runs when the previous month is FINALIZED and the new month has working days set.
- Salary, dependants and other contract terms are not copied: the calculation reads them from T_D_EMPLOYEE_CONTRACT for that month, so nothing needs re-entering.
- Monthly inputs start at zero each month; allocations carry over.

## 5. Approval (payroll)

The second approver (the step flagged MANAGES_EMPLOYEE_CHECKS) checks or rejects each employee, then approves the step; it can only be approved once every employee is CHECKED. There is one check per employee per month. The third approver simply approves.

| Action | Reads | Writes | Procedure |
| --- | --- | --- | --- |
| Gross compensation summary (current, previous month, 6-month average, budget, forecast) | CORE.V_F_PAYROLL_SUMMARY (actual periods); RPT.V_F_BUDGET_VS_ACTUAL | – | – |
| KPI and payment summary cards (headcount, bonus + seniority, NSSF, net to bank per chamber, ToS in KHR, FX vs previous month) | CORE.V_F_PAYROLL_SUMMARY; CORE.T_F_PAYROLL_LINE for BONUS and SENIORITY; APP.T_F_SCENARIO_PERIOD for FX | – | – |
| Employee grid (gross, avg daily cost, bonus + seniority, net, ToS, % vs previous month) | CORE.V_F_PAYROLL_SUMMARY for this and the previous period; CORE.V_D_EMPLOYEE | – | – |
| Validation buttons per employee (step 2 only) | APP.T_F_APPROVAL_EMPLOYEE_CHECK for the month's request | – | – |
| Check an employee (✓) | – | Upsert APP.T_F_APPROVAL_EMPLOYEE_CHECK (CHECKED); T_F_CHANGE_LOG | SP_SET_EMPLOYEE_CHECK |
| Reject an employee (✗) with a comment | – | Upsert APP.T_F_APPROVAL_EMPLOYEE_CHECK (REJECTED, CHECK_COMMENT); T_F_CHANGE_LOG | SP_SET_EMPLOYEE_CHECK |
| Approve All (step 2) | – | Sets every PENDING employee check to CHECKED | SP_SET_EMPLOYEE_CHECK (bulk) |
| Approval chain | RPT.V_F_APPROVAL_PROGRESS | – | – |
| Approve step | APP.T_F_APPROVAL_EMPLOYEE_CHECK (all CHECKED? step 2 only) | Step to APPROVED in APP.T_F_APPROVAL_STEP_STATE (comment); T_F_CHANGE_LOG | SP_APPROVE_STEP |
| Reject step | – | Step to REJECTED and the previous step back to PENDING (LAST_ACTION = SEND_BACK) in APP.T_F_APPROVAL_STEP_STATE; rejecting step 1 puts T_F_SCENARIO_PERIOD back to OPEN (same request); T_F_CHANGE_LOG | SP_REJECT_STEP |
| Undo approval | – | Step back to PENDING in APP.T_F_APPROVAL_STEP_STATE (LAST_ACTION = UNDO); T_F_CHANGE_LOG | SP_UNDO_APPROVAL |
| HR / Treasurer comments | RPT.V_F_APPROVAL_PROGRESS.ACTION_COMMENT | – | – |
| Process (finalize) | RPT.V_F_APPROVAL_PROGRESS (all steps APPROVED?) | Final SP_CALCULATE_PAYROLL; T_F_SCENARIO_PERIOD to FINALIZED (FINALIZED_AT / BY); T_F_APPROVAL_REQUEST to APPROVED | SP_FINALIZE_PAYROLL |

Notes:

- SP_APPROVE_STEP checks that the user holds the step's APPROVER_ROLE in T_D_APP_USER_ROLE and that the previous step is approved.
- Nothing is copied at finalization. The month's rows stay in T_F_PAYROLL_LINE and become read-only because the period is FINALIZED.
- The chain is sorted by STEP_ORDER from V_F_APPROVAL_PROGRESS, which fixes the First / Third / Second display order seen on the current Monthly Inputs page.

## 6. Budget Input

Each budget scenario is an independent copy of next year's payroll. Edits to one scenario never touch another scenario or the real contracts.

| Action | Reads | Writes | Procedure |
| --- | --- | --- | --- |
| Scenario dropdown | APP.T_D_SCENARIO (SCENARIO_TYPE = BUDGET) | – | – |
| KPI cards (headcount + new hires, annual budget, monthly average, bonus, fringe) | RPT.V_F_SCENARIO_SUMMARY; APP.T_D_SCENARIO_EMPLOYEE; APP.T_F_PAYROLL_INPUT | – | – |
| Grid (latest raise date, revaluation month, monthly salary, raise, final salary, bonus, fringe) | APP.T_D_SCENARIO_EMPLOYEE; latest raise date from APP.T_D_EMPLOYEE_CONTRACT history | – | – |
| Create scenario | CORE.V_D_EMPLOYEE (active, current versions); CORE.T_D_PERIOD (BUDGET_WORKING_DAYS) | New row in APP.T_D_SCENARIO (DRAFT); 12 rows in APP.T_F_SCENARIO_PERIOD; one row per employee in APP.T_D_SCENARIO_EMPLOYEE copied from contracts; empty monthly rows in APP.T_F_PAYROLL_INPUT; calculation | SP_CREATE_SCENARIO |
| Copy an existing scenario | The source scenario's rows | Same as create, but copied from the source scenario; BASE_SCENARIO_ID set | SP_CREATE_SCENARIO (with source) |
| Edit raise, revaluation month, salary or fringe | – | Update APP.T_D_SCENARIO_EMPLOYEE (FINAL_SALARY_USD recomputed); T_F_CHANGE_LOG | SP_SAVE_SCENARIO_EMPLOYEE |
| Show Details (month-level edits: bonus, one-month salary or fringe) | APP.T_F_PAYROLL_INPUT for the scenario | Update APP.T_F_PAYROLL_INPUT (BONUS_USD, SALARY_OVERRIDE_USD, FRINGE_BENEFIT_OVERRIDE_USD) | SP_SAVE_MONTHLY_INPUT |
| Save | – | Runs the calculation for the scenario: CORE.T_F_PAYROLL_LINE and CORE.T_F_COST_ALLOCATION | SP_CALCULATE_PAYROLL |
| Add New Hire | – | New APP.T_D_EMPLOYEE (IS_PLANNED = TRUE, PLANNED_SCENARIO_ID); row in APP.T_D_SCENARIO_EMPLOYEE; monthly inputs (INCLUDE_IN_PAYROLL = FALSE before the start month) | SP_SAVE_PLANNED_HIRE |
| Remove a new hire | – | Deletes the planned employee's rows in this scenario only | SP_DELETE_PLANNED_HIRE |
| Delete Budget | – | Deletes the scenario's inputs, scenario employees, planned hires, periods, pay lines and approval rows, then the scenario | SP_DELETE_SCENARIO |

Notes:

- SP_DELETE_PLANNED_HIRE refuses any employee with IS_PLANNED = FALSE, so actual employees cannot be removed from a budget.
- SP_DELETE_SCENARIO refuses a scenario that is IN_APPROVAL or official.
- Edits are allowed only while the scenario is DRAFT or REJECTED.

## 7. Budget Approval

The same three-step chain as payroll, applied to a whole scenario. When the third step approves, that scenario becomes the official budget for its year.

| Action | Reads | Writes | Procedure |
| --- | --- | --- | --- |
| Scenario dropdown | APP.T_D_SCENARIO (BUDGET, status IN_APPROVAL or APPROVED) | – | – |
| KPI and payment cards (headcount, annual and monthly budget, bonus, fringe, net per chamber, ToS, NSSF, seniority) | RPT.V_F_SCENARIO_SUMMARY; CORE.T_F_PAYROLL_LINE for BONUS, SENIORITY, FRINGE_BENEFIT | – | – |
| Employee grid (gross, bonus + seniority, net, ToS) | CORE.V_F_PAYROLL_SUMMARY summed over the scenario's 12 months; CORE.V_D_EMPLOYEE and APP.T_D_SCENARIO_EMPLOYEE for names | – | – |
| Submit for approval (from Budget Input) | – | New APP.T_F_APPROVAL_REQUEST (PERIOD_KEY = NULL); T_D_SCENARIO to IN_APPROVAL | SP_SUBMIT_SCENARIO |
| Approval chain | RPT.V_F_APPROVAL_PROGRESS | – | – |
| Approve step | – | Step to APPROVED in APP.T_F_APPROVAL_STEP_STATE | SP_APPROVE_STEP |
| Final approval (step 3) | – | T_F_APPROVAL_REQUEST to APPROVED; T_D_SCENARIO to APPROVED and IS_OFFICIAL = TRUE; the previous official scenario for that year set to FALSE; periods LOCKED | SP_APPROVE_STEP |
| Reject / undo | – | Step to REJECTED or back to PENDING in APP.T_F_APPROVAL_STEP_STATE; on reject T_D_SCENARIO back to REJECTED so it can be edited | SP_REJECT_STEP / SP_UNDO_APPROVAL |

Notes:

- The official budget is what RPT.V_F_BUDGET_VS_ACTUAL and the Approval page compare against.
- Every scenario runs through the same calculation as actual payroll, so net pay and ToS are filled in (they show $0.00 on the current page).
- The grain of V_F_PAYROLL_SUMMARY is one row per employee per month, so an employee cannot appear twice (the current page lists one employee twice).

## 8. Forecast

A forecast takes actuals up to the end of the chosen quarter and rolls the last month forward to December. Choosing Q2 uses Jan–Jun actuals and projects Jul–Dec from June.

| Action | Reads | Writes | Procedure |
| --- | --- | --- | --- |
| Quarter dropdown | APP.T_D_SCENARIO (SCENARIO_TYPE = FORECAST) | – | – |
| Generate forecast for a quarter | Actual periods up to the quarter end: APP.T_F_SCENARIO_PERIOD (FINALIZED), CORE.T_F_PAYROLL_LINE; contract terms valid in the last month | New APP.T_D_SCENARIO (FORECAST_AS_OF_PERIOD_KEY = quarter end, e.g. 202606); APP.T_F_SCENARIO_PERIOD for the remaining months; APP.T_D_SCENARIO_EMPLOYEE copied from the last month's terms; empty APP.T_F_PAYROLL_INPUT rows; calculation for projected months | SP_CREATE_FORECAST |
| Grid (Jan–Dec per employee, subtotals) | Months up to the as-of: actual rows of CORE.V_F_PAYROLL_SUMMARY; later months: forecast rows | – | – |
| KPI cards (headcount, annual gross, monthly average, net per chamber, ToS, seniority, bonus) | RPT.V_F_SCENARIO_SUMMARY for both sources; CORE.T_F_PAYROLL_LINE for SENIORITY and BONUS | – | – |
| Edit a raise from a month (e.g. +10% from Sep) | – | Update APP.T_D_SCENARIO_EMPLOYEE (RAISE_PCT, REVALUATION_PERIOD_KEY, FINAL_SALARY_USD); recalculate | SP_SAVE_SCENARIO_EMPLOYEE |
| Edit a single month | – | Update APP.T_F_PAYROLL_INPUT (SALARY_OVERRIDE_USD, BONUS_USD, …); recalculate | SP_SAVE_MONTHLY_INPUT |
| Add New Hire | – | New planned APP.T_D_EMPLOYEE tied to the forecast; APP.T_D_SCENARIO_EMPLOYEE; inputs | SP_SAVE_PLANNED_HIRE |
| Regenerate or delete a forecast | – | Rebuild or remove the forecast scenario's rows | SP_CREATE_FORECAST / SP_DELETE_SCENARIO |

Notes:

- Actual months are never copied into the forecast; the grid and the views read them from the actual scenario, so they always match the real payroll.
- Only projected months (after FORECAST_AS_OF_PERIOD_KEY) can be edited.
- RPT.V_F_BUDGET_VS_ACTUAL uses the latest non-archived forecast per year.

## 9. Settings

Admins manage the working-day calendars and who approves each step.

| Action | Reads | Writes | Procedure |
| --- | --- | --- | --- |
| Actual working days grid | CORE.T_D_PERIOD.WORKING_DAYS | – | – |
| Budget working days grid | CORE.T_D_PERIOD.BUDGET_WORKING_DAYS | – | – |
| Save working days | – | Update CORE.T_D_PERIOD (WORKING_DAYS or BUDGET_WORKING_DAYS); T_F_CHANGE_LOG | SP_SAVE_WORKING_DAYS |
| Approval settings (step titles) | CORE.T_P_APPROVAL_STEP (active, current version) | – | – |
| Rename a step | – | Close the current step version and add a new one in CORE.T_P_APPROVAL_STEP | SP_SAVE_APPROVAL_STEPS |
| Assign an approver by email | APP.T_D_APP_USER; APP.T_D_APP_USER_ROLE | Add the user to APP.T_D_APP_USER if new; grant the step's APPROVER_ROLE in APP.T_D_APP_USER_ROLE and remove it from the previous approver | SP_SAVE_APPROVAL_STEPS |

Notes:

- SP_SAVE_WORKING_DAYS refuses changes to a month that is FINALIZED. The open month's value is copied into T_F_SCENARIO_PERIOD and triggers a recalculation.
- Budget scenarios take BUDGET_WORKING_DAYS when their periods are created.
- Statutory parameters and tax brackets have no page yet; they are maintained by script in CORE.T_P_STATUTORY_PARAMETER and CORE.T_P_TAX_BRACKET.

## Stored procedure inventory

24 procedures cover every write in the app. None are built yet.

| Procedure | Called from | Writes |
| --- | --- | --- |
| SP_SAVE_EMPLOYEE | Employee Register | T_D_EMPLOYEE, first T_D_EMPLOYEE_CONTRACT |
| SP_SAVE_EMPLOYEE_CONTRACT | Employee Register | T_D_EMPLOYEE_CONTRACT (new version) |
| SP_SET_EMPLOYEE_ACTIVE | Employee Register | T_D_EMPLOYEE.IS_ACTIVE |
| SP_SAVE_FUND_ALLOCATION | Cost Center | T_F_FUND_ALLOCATION |
| SP_SAVE_DEPARTMENT_ALLOCATION | Cost Center | T_F_DEPARTMENT_ALLOCATION |
| SP_SAVE_MONTHLY_INPUT | Monthly Inputs, Budget Input, Forecast | T_F_PAYROLL_INPUT |
| SP_SAVE_EXCHANGE_RATE | Monthly Inputs | T_P_FX_RATE, T_F_SCENARIO_PERIOD |
| SP_SAVE_PAYROLL_ADJUSTMENT | Monthly Inputs | T_F_PAYROLL_ADJUSTMENT |
| SP_OPEN_PAYROLL_PERIOD | Monthly Inputs | T_F_SCENARIO_PERIOD, T_F_PAYROLL_INPUT, allocations, T_F_APPROVAL_REQUEST |
| SP_CALCULATE_PAYROLL | Called by other procedures, Budget Save | T_F_PAYROLL_LINE, T_F_COST_ALLOCATION |
| SP_FINALIZE_PAYROLL | Approval (Process) | T_F_SCENARIO_PERIOD, T_F_APPROVAL_REQUEST |
| SP_SET_EMPLOYEE_CHECK | Approval | T_F_APPROVAL_EMPLOYEE_CHECK |
| SP_APPROVE_STEP | Monthly Inputs, Approval, Budget Approval | T_F_APPROVAL_STEP_STATE (+ official budget on final step) |
| SP_REJECT_STEP | Approval, Budget Approval | T_F_APPROVAL_STEP_STATE, request and period / scenario status |
| SP_UNDO_APPROVAL | Monthly Inputs, Approval, Budget Approval | T_F_APPROVAL_STEP_STATE |
| SP_CREATE_SCENARIO | Budget Input | T_D_SCENARIO, T_F_SCENARIO_PERIOD, T_D_SCENARIO_EMPLOYEE, T_F_PAYROLL_INPUT |
| SP_SAVE_SCENARIO_EMPLOYEE | Budget Input, Forecast | T_D_SCENARIO_EMPLOYEE |
| SP_SAVE_PLANNED_HIRE / SP_DELETE_PLANNED_HIRE | Budget Input, Forecast | T_D_EMPLOYEE (planned), T_D_SCENARIO_EMPLOYEE, T_F_PAYROLL_INPUT |
| SP_SUBMIT_SCENARIO | Budget Input | T_F_APPROVAL_REQUEST, T_D_SCENARIO |
| SP_DELETE_SCENARIO | Budget Input, Forecast | All rows of the scenario |
| SP_CREATE_FORECAST | Forecast | T_D_SCENARIO, T_F_SCENARIO_PERIOD, T_D_SCENARIO_EMPLOYEE, T_F_PAYROLL_INPUT |
| SP_SAVE_WORKING_DAYS | Settings | T_D_PERIOD |
| SP_SAVE_APPROVAL_STEPS | Settings | T_P_APPROVAL_STEP, T_D_APP_USER, T_D_APP_USER_ROLE |

Every procedure also writes T_F_CHANGE_LOG and returns a status and message to Power Apps.