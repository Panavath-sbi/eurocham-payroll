# CLAUDE.md – EuroCham Payroll on Snowflake

Read the root CLAUDE.md first. This file covers what is specific to this app.
Snowflake code in `repo/`, Power Apps YAML in `powerapps/`.
Last updated: 2026-10-19 (Snowflake code converted to the DLSync layout; every
screen renovated, clean-up remains).

**Nothing is run against Snowflake from here.** Objects reach Snowflake through
the GitHub deploy (DLSync, see Repository layout); the user runs tests, dummy data
and one-off scripts in Snowsight.

## What this is

Payroll, budget and forecast for two Cambodian chambers of commerce: **ECCC**
(EuroCham, cost center `CC_9999-Shared` in reports) and **CCIFC**. It replaces an
Oracle **Essbase** cube.

- Pay is contracted and paid in **USD**; statutory amounts (NSSF, salary tax) are
  calculated in **KHR** under Cambodian rules and converted back.
- Nothing calculated by Essbase is kept. History is recalculated in Snowflake
  from raw data.
- Databases: `DEV_PAYROLL_DB` (Dev) and `PROD_PAYROLL_DB` (Prod); scripts write
  `${DB}`, set per environment. Old model `DEV` schema: do not extend.
- The whole Essbase + SharePoint ecosystem is being discarded (decided): no
  screen may read or write it any more.

## Architecture (since V1.5.0: two schemas)

| Schema | Holds | Written by |
| --- | --- | --- |
| `APP` | Every table (20) and every procedure (25) | Power Apps only through `SP_` procedures; pay lines only by the calculation |
| `RPT` | Every view (27, nothing stored) | Nobody |

`CORE` no longer exists (an earlier model schema, merged into APP in V1.5.0). The
table scripts start from today's shape: the old V1.0.0–V1.8.0 history was dropped
when the repo moved to DLSync (2026-10-19). The app and Power BI read only from
`RPT`. The schemas `APP` and `RPT` themselves are not created by the scripts yet
(see open items).

- **Actual payroll, budget scenarios and forecast versions are all scenarios**
  (`APP.T_D_SCENARIO`, type ACTUAL / BUDGET / FORECAST). Same inputs,
  calculation and facts.
- **History is not a separate table.** A finalized month stays in
  `APP.T_F_PAYROLL_LINE`, locked by
  `APP.T_F_SCENARIO_PERIOD.PERIOD_STATUS = 'FINALIZED'`.
- **Grain of the main fact:** scenario × period × employee × pay component.
- **Effective dating by `PERIOD_KEY` (YYYYMM):** contracts (SCD2 in
  `APP.T_D_EMPLOYEE_CONTRACT`), statutory parameters, tax brackets, approval steps.
- Only one actual month is open at a time. Closed months are never edited.

## Tables (APP, 20)

- Calendar and reference: `T_D_PERIOD` (192 months 2020–2035; `WORKING_DAYS`,
  `BUDGET_WORKING_DAYS`, published `FX_RATE_NBC`, `FX_RATE_NSSF`), `T_D_ENTITY`,
  `T_D_FUND` (ECCC, CCIFC, EU_GATE), `T_D_DEPARTMENT` (7; no Default – see Cost
  Center), `T_D_PAY_COMPONENT`.
- Parameters: `T_P_STATUTORY_PARAMETER`, `T_P_TAX_BRACKET`, `T_P_APPROVAL_STEP`
  (`APPROVER_ROLE` = LEVEL_n for step n; `MANAGES_EMPLOYEE_CHECKS` = TRUE for
  step 2).
- People: `T_D_APP_USER` (`ROLE_CODE`: ADMIN / LEVEL_1 / LEVEL_2 / LEVEL_3, one
  per user; `SIGNATURE_IMAGE` Base64), `T_D_EMPLOYEE` (identity, bank,
  `IS_ACTIVE`, `IS_PLANNED`), `T_D_EMPLOYEE_CONTRACT` (incl. `NON_RESIDENT_FROM`,
  `NON_RESIDENT_TO`).
- Scenarios: `T_D_SCENARIO`, `T_F_SCENARIO_PERIOD` (status + applied working days
  and FX), `T_D_SCENARIO_EMPLOYEE` (per-scenario terms for budgets / forecasts).
- Monthly: `T_F_PAYROLL_INPUT` (inputs **and** the employee check: `CHECK_STATUS`,
  `CHECK_COMMENT`, `CHECKED_BY`), `T_F_FUND_ALLOCATION`,
  `T_F_DEPARTMENT_ALLOCATION` (percent, each totals 100; two tables on purpose).
- Approval: `T_F_APPROVAL` – one row per step, keyed SCENARIO_ID + PERIOD_KEY +
  STEP_ORDER (PERIOD_KEY **0 = a whole budget**); STEP_STATUS PENDING / APPROVED /
  REJECTED, LAST_ACTION, ACTED_BY, ACTED_AT, STEP_COMMENT.
- Audit: `T_F_CHANGE_LOG` (every procedure write; also the approval history).
- Fact: `T_F_PAYROLL_LINE`.

Removed (V1.4.0–V1.5.0): CORE schema, T_F_APPROVAL_ACTION, T_F_APPROVAL_REQUEST,
T_F_APPROVAL_STEP_STATE, T_F_APPROVAL_EMPLOYEE_CHECK, T_D_APP_USER_ROLE,
T_P_FX_RATE, RPT.SIGNATURES, T_F_PAYROLL_ADJUSTMENT (and the ADJUSTMENT pay
component), T_F_COST_ALLOCATION (now the view RPT.V_F_COST_ALLOCATION). Roles
removed in V1.7.0: PAYROLL_ADMIN, BUDGET_EDITOR, VIEWER, HR_MANAGER, TREASURER,
DIRECTOR.

## Views (RPT, 27)

One file per view in `db_scripts/main/PAYROLL_DB/RPT/VIEWS/`.

- Base: V_D_EMPLOYEE (SCD2, incl. bank details),
  V_D_SCENARIO, V_F_PAYROLL_SUMMARY, V_F_COST_ALLOCATION, V_F_APPROVAL_EVENT
  (from the change log).
- Reporting: V_F_DASHBOARD_KPI, V_F_SCENARIO_SUMMARY,
  V_F_BUDGET_VS_ACTUAL, V_F_COST_CENTER_SUMMARY, V_F_APPROVAL_PROGRESS
  (APPROVAL_STATUS, IS_IN_PROGRESS, IS_NEXT_STEP, MANAGES_EMPLOYEE_CHECKS).
- App: V_D_PERIOD, V_F_SCENARIO_PERIOD,
  V_F_PAYROLL_INPUT, V_F_ALLOCATION, V_D_SCENARIO_EMPLOYEE (since 2026-10-06 also
  START_PERIOD_KEY / END_PERIOD_KEY = first / last month paid in the scenario, and
  BONUS_USD = the scenario's bonus inputs), V_F_PAYROLL_LINE, V_D_LOOKUP,
  V_P_APPROVAL_STEP, V_D_APP_USER, V_F_PAYROLL_MONTH (employee × month totals +
  components), V_F_DASHBOARD_MONTH (every calendar month: actual totals and
  chamber splits, NBC rate, official budget and latest forecast gross).
- Power BI: V_F_PBI_PAYROLL, V_P_PBI_EMPLOYEE_PARAMS,
  V_D_PBI_EMPLOYEE, V_D_PBI_EMPLOYEE_DETAILS, V_F_PBI_PAYROLL_APPROVAL,
  V_D_PBI_SIGNATURE. Not granted to the app.

Bank details reach the app with the employee list (V_D_EMPLOYEE ->
`LoadEmployees()`): every app user may see them. `SP_GET_EMPLOYEE_BANK` was
retired on 2026-10-19 (procedure and grant removed from the repo).

The app may run any SELECT on the granted views through the flow, including
aggregates, joins between granted views and pivots
(e.g. `SUM(IFF(MONTH_NUMBER = 1, …))`).

## Calculation rules (SP_CALC_PERIOD)

- Earnings in USD, converted to KHR at the NBC rate from the unrounded USD.
- Daily rate = salary / working days; unpaid leave, overtime
  (× OVERTIME_MULTIPLIER), outstanding leave (days) use it.
- Seniority in June and December: half-year average (salary + bonus) /
  working days × 7.5.
- NSSF: base = (salary + seniority) × NSSF rate, between floor and cap 1,200,000
  KHR; the cap applies to pension, healthcare and occupational risk (Essbase
  wrongly left health / ORC uncapped).
- Salary tax (KHR): residents progressive brackets after dependant relief
  (150,000 per dependant); non-residents flat 20%, no relief. Taxable base =
  taxable earnings − seniority exemption − employee NSSF.
- Currency of record: USD. Net pay USD = gross − NSSF EE − tax (each rounded to
  the cent).
- Scenario salary: MONTHLY_SALARY_USD before REVALUATION_PERIOD_KEY,
  FINAL_SALARY_USD (= salary × (1 + RAISE_PCT/100)) from that month on.
- Gross pay = what the employee earns (salary, bonus, seniority, overtime…);
  employer cost = gross + employer NSSF + other employer costs (insurance, visa,
  work permit). They differ.
- No adjustment line (removed). Known limits: no seniority eligibility check; no
  fringe benefit tax.

## Business rules decided

- **Approvals:** 3 sequential steps (HR Manager → Treasurer → Director). Only
  **step 2** checks employees one by one (one check per employee per month, on the
  input row); steps 1 and 3 are a plain approve. Step 2 can only be approved when
  every employee is CHECKED. Budgets have no employee checks.
- **Reject = send back one step:** step N → REJECTED, step N−1 → PENDING
  (SEND_BACK). Rejecting step 1: payroll month back to OPEN; budget → REJECTED and
  is resubmitted (submission replaces its approval rows).
- Any change to an open month's numbers resets approved steps and the changed
  employees' checks (comment cleared). Finalizing does not recalculate.
- **Roles only limit approvals (V1.7.0).** Four roles, one per user
  (`T_D_APP_USER.ROLE_CODE`): LEVEL_1 / LEVEL_2 / LEVEL_3 approve step 1 / 2 / 3
  (step 2 incl. the employee checks); ADMIN approves every step and is for
  developers / testing, set in Snowflake only (never from the app; keep it out of
  production). Every active user may use every other function; every procedure
  still refuses unknown or inactive users. Several people can share a level.
  Assigning an approver in Settings gives them the step's level (their old role
  goes; other holders keep theirs); anyone may assign anyone, themselves included;
  one person cannot be on two steps. The preparer can approve their own level. To
  stop someone approving, deactivate them in Snowflake (there is no "no approval"
  role). A repeated approve / reject / undo call is refused ("already approved",
  etc.), so retries are harmless.
- **Budgets** are approved as a whole (PERIOD_KEY 0); final approval makes the
  scenario the official budget of its year. Forecasts are not approved.
  - Names are typed by the user as "year + name" (e.g. "2027 Scenario 1"); a name
    must be unique (checked in the app and by Snowflake). No limit per year.
  - The bonus is entered once a year and stored in **March**
    (`SP_SAVE_MONTHLY_INPUT`, period YYYY03).
  - One exchange-rate field when creating a budget, used as both NBC and NSSF rate
    of all 12 months (`SP_CREATE_SCENARIO` P_FX_RATE); prefilled with the latest
    actual NBC rate.
  - **On final approval the app deletes every other budget of that year** (those
    still in approval are kept; the previous official budget loses its flag in
    Snowflake and is deleted).
  - Annual Budget figure = **employer cost** (total spend), on Budget Input and
    Budget Approval.
- **Forecasts:** one forecast per year (the current one = the latest as-of
  quarter). Created from the actuals of Q1, Q2 or Q3 (month must be FINALIZED; no
  Q4). Creating or recreating a quarter's forecast deletes the year's other
  forecasts; recreating drops its manual changes. Months up to the as-of month are
  actuals, later months the forecast. Salary changes apply from a forecast month
  (salary 0 = no longer paid); only planned hires can be removed. Headline figure
  = **gross** (employer cost shown in the card's small text).
- **Cost center:** no "Default" department (it only existed because Essbase could
  not leave a member empty). A department split totals exactly 100 % across the 7
  departments; an employee without a split is "Not allocated" (screen) / "Default"
  (Power BI, unsplit). A split can be changed, not removed. Fund split in working
  days, ECCC = remaining days. Amounts shown on **gross pay** (as Power BI). Only
  the open month can be changed.
- **Deactivating an employee is immediate** (open month and later). Employees are
  never deleted.
- **Non-residency:** the contract keeps NON_RESIDENT_FROM / NON_RESIDENT_TO
  (information only; tax uses only TAX_STATUS). When a payroll month opens after
  NON_RESIDENT_TO, SP_OPEN_PAYROLL_PERIOD makes the employee RESIDENT from that
  month (new contract version, logged). Actual payroll only.
- **No payroll adjustments.** A correction for a closed month goes into the open
  month (bonus field, reason in the notes).
- "Pay Adjustments" on the Employee Register is a Power Apps helper that adds to
  the salary, saved as a normal contract change.
- Renamed approval steps apply from the current calendar month.
- **Working days:** finalized actual months cannot be changed; changing the open
  month's working days resets its approvals.

## Repository layout (`repo/`)

```
db_scripts/
  config.yml                         DLSync settings
  parameter-dev.properties           DB=DEV_PAYROLL_DB
  parameter-prod.properties          DB=PROD_PAYROLL_DB
  main/PAYROLL_DB/APP/TABLES/        20 files, one per table (migration scripts)
  main/PAYROLL_DB/APP/PROCEDURES/    25 files, one per procedure
  main/PAYROLL_DB/RPT/VIEWS/         27 files, one per view
grants/grants.sql       rights of the app role; run after every deploy
dev_data/               load_dummy_data.sql (dev only) with check queries;
                        snapshot_save / snapshot_restore / snapshot_drop
tests/                  test_01_payroll_cycle, test_02_remaining_procedures, test_03_reads
flows/                  README.md (the Power Automate flow and how the app calls it),
                        read_catalog.json
optional/               mask_bank_details.sql (Enterprise Edition)
docs/                   flows.md
setup_payroll_db.sql    database and role set-up (run once, by IT / admin)
```

The `PAYROLL_DB` folder is only a folder name; the real database comes from `${DB}`.

**DLSync rules** (replace the old V / R / A files, `USE DATABASE`, the all-in-one
rebuild file and schemachange):

- One object per file, named after the object in capitals (`T_D_ENTITY.SQL`). Every
  object name is `${DB}.APP.<name>` or `${DB}.RPT.<name>`, also inside procedure
  bodies and `CALL`s. No `USE DATABASE`. String literals that are data (e.g. the
  table name written to `T_F_CHANGE_LOG`) stay `'APP.T_…'`.
- **Tables:** migration format. `---version: 0, author: …` creates the table (plain
  `CREATE TABLE`, never `OR REPLACE`); every later change is a new `---version: n`
  (`ALTER TABLE …`). A deployed version is never edited. Each version has a one-line
  `---rollback:` and `---verify:`. Reference data are later versions of the table
  they fill (T_D_PERIOD, T_D_ENTITY, T_D_FUND, T_D_DEPARTMENT, T_D_PAY_COMPONENT,
  T_P_STATUTORY_PARAMETER, T_P_TAX_BRACKET, T_P_APPROVAL_STEP: version 1).
- **Views and procedures:** `CREATE OR REPLACE … COPY GRANTS`, edited in place (for a
  procedure `COPY GRANTS` follows the parameter list; `COMMENT` still goes before
  `EXECUTE AS`). A procedure whose parameter types change leaves the old signature
  behind in Snowflake (a second version): ask how to drop it before changing types.
  Optional parameters use `DEFAULT NULL` so older calls keep working.
- DLSync orders the scripts by dependency itself; file names do not matter for order.
- `grants/grants.sql` still names every granted procedure with its full signature,
  and is run after every deploy (a new procedure or view needs its line).
- Every file keeps its History header (tables: a dated `--` comment per version).
- Deployment (GitHub Actions, workflows not added yet): pull request → plan; merge to
  `develop` → Dev (`DEV_PAYROLL_DB`); merge to `main` → Prod (`PROD_PAYROLL_DB`).
- Git: GitHub repository Solution-BI/HR_PAYROLL_SBI_APAC, working branch `dev`
  (the old Snowsight Workspace link is no longer how changes are deployed).

## Procedures (APP, 25)

| Area | Procedures |
| --- | --- |
| Internal (not granted to the app) | `SP_CALC_PERIOD`, `SP_RESET_APPROVALS` |
| Payroll cycle | `SP_CALCULATE_PAYROLL`, `SP_OPEN_PAYROLL_PERIOD`, `SP_SAVE_MONTHLY_INPUT`, `SP_FINALIZE_PAYROLL` |
| Approvals (role-checked: step's level or ADMIN) | `SP_APPROVE_STEP` / `SP_REJECT_STEP` (email, scenario, month, step, comment), `SP_UNDO_APPROVAL` (email, scenario, month, step), `SP_SET_EMPLOYEE_CHECK` (email, month, step, employees, status, comment); month 0 or NULL for a budget |
| Employees | `SP_SAVE_EMPLOYEE`, `SP_SAVE_EMPLOYEE_CONTRACT`, `SP_SET_EMPLOYEE_ACTIVE` |
| Cost center | `SP_SAVE_FUND_ALLOCATION` (days or %), `SP_SAVE_DEPARTMENT_ALLOCATION` (must total 100) |
| Settings | `SP_SAVE_EXCHANGE_RATE`, `SP_SAVE_WORKING_DAYS` ('ACTUAL' / 'BUDGET'), `SP_SAVE_APPROVAL_STEPS` |
| Budget / forecast | `SP_CREATE_SCENARIO` (email, name, year, source id, description, FX rate DEFAULT NULL), `SP_SAVE_SCENARIO_EMPLOYEE`, `SP_SAVE_PLANNED_HIRE`, `SP_DELETE_PLANNED_HIRE`, `SP_SUBMIT_SCENARIO`, `SP_DELETE_SCENARIO`, `SP_CREATE_FORECAST` (email, year, quarter 1–3, name) |

Each file's header documents its parameters (JSON payloads) and rules.

## Snowflake environment facts

- Development / deployment role: `SF_APA_PAYROLL-DBA` (owns the objects). The
  flow's role: `SF_APA_PAYROLL-ETL` (the only app role; name has a hyphen, so
  write it in double quotes).
- The user cannot grant on the database itself (IT manages it); `grants/grants.sql`
  grants only on the APP / RPT schemas and objects: SELECT on 21 app views, USAGE
  on 23 procedures (grant lines name the full signature, e.g.
  `SP_CREATE_SCENARIO(TEXT, TEXT, INT, INT, TEXT, FLOAT)`). Optional section 4
  (revoke the role's direct APP table rights) is still off until confirmed nothing
  else needs them.
- The account runs on US Pacific time (timestamps 14 h behind Phnom Penh); IT
  could set TIMEZONE = 'Asia/Phnom_Penh' for the account or the connection user.

## Power Apps

- Flow: **EuroCham-Snowflake** (in the app: `'EuroCham-Snowflake'.Run(sql)`), one
  Text input; runs SELECTs and CALLs of allow-listed procedures; returns `status`,
  `message`, `rows`. Details and Power Fx patterns in `repo/flows/README.md`.
- The app sends `User().Email` in CALLs (accepted risk; senior management only).
- Data loading: behaviour user-defined functions in `App.Formulas`:
  - Session and shared: `LoadSession()` (role, actual scenario
    `varActualScenarioId`, colActualPeriods, `varOpenPeriod`, colExchangeRates,
    colLookups, colECCC), `LoadEmployees()`, `LoadDashboard()`. Still present for
    clean-up: `LoadTransactions()`, `LoadApproval()` (no renovated screen reads
    them).
  - Monthly Inputs / Approval: `LoadMonthlyInputs(MonthKey)` -> `colMonthInputs`;
    `LoadMonthApproval(MonthKey)` -> `colMonthApproval`;
    `LoadApprovalSummary(MonthKey)` -> `colApprSummary`, `varApprCur`,
    `varApprPrev`, `varApprAvgGross` (fields: EmployeeKey, EmployeeId,
    EmployeeName, …, CheckStatus, CheckComment / StepOrder, StepTitle, StepStatus,
    IsNext, IsInProgress, ActedByName, ActedAt, Comment).
  - Budgets: `LoadBudgets()` -> `colBudgets` (ScenarioId, Name, Year, Status
    DRAFT / IN_APPROVAL / REJECTED / APPROVED, IsOfficial, Description).
    `LoadBudget(ScenarioId)` -> `colBudgetGrid` (one row per employee of a budget
    **or forecast**: EmployeeKey, ResourceCode, Name, Position, IsPlanned,
    EntityCode, EmploymentType, EmployeeType, ContractType, Salary, RaisePct
    (5 = 5 %), RevalMonth (0 = none), FinalSalary, Insurance, WorkPermit, Visa,
    Bonus, LastRaiseKey, StartKey, EndKey, Dirty, BonusDirty), `colBudgetApproval`
    (steps, PERIOD_KEY 0), `varBiGrossUsd`, `varBiCostUsd`, `varBiFx`.
    `LoadBudget(0)` empties everything. `LoadBudgetReview(ScenarioId)` ->
    `colBudgetReview` (per employee for the year: Gross, Bonus, Seniority, Net,
    Tax, NssfEe, NssfEr, Cost, EntityCode, IsPlanned) and `varBaTaxKhr`; call
    after LoadBudget.
  - Forecasts: `LoadForecasts()` -> `colFcList` (ScenarioId, Name, Year, AsOfKey,
    Quarter); `LoadForecast(ScenarioId, AsOfKey)` -> `colFcGrid` (M01–M12 gross,
    actual months up to AsOfKey + forecast months after; Gross, Bonus, Seniority,
    Tax, Cost, IsPlanned) and `varFcTaxKhr`; call after LoadBudget(ScenarioId).
  - Cost center: `LoadCostCenter(MonthKey)` -> `colCcEmp` (Gross, AvgDaily,
    HasDept, HasFund, CcifcPct, EuPct), `colCcAlloc` (EmployeeKey, Kind
    DEPARTMENT / FUND, Code, Pct), `colCcDept` (gross per department).
  - Settings: `LoadWorkingDays()` -> `colWorkingDaysActuals` /
    `colWorkingDaysBudget` (calendar year and the next two; PeriodKey, WorkingDays,
    Orig, IsLocked = finalized actual month, plus the old fields Month,
    MonthNumber, MonthName, MonthLabel, FiscalYear, Phase); `LoadApprovalSteps()`
    -> `colApprovalSteps` (StepOrder, Title, OrigTitle, Role, ApproverNames,
    ApproverEmails, NewEmail).
  `App.OnStart` = page state + colMonths + LoadSession + loaders.
  `colEmployees` includes BankName, BankAccountName, BankAccountNumber.
- The app shows the **open payroll month** (`varOpenPeriod`), not the calendar
  month.

### Screens

MainPage no longer exists (split 2026-10-06 into one screen per page).
App.StartScreen = DashboardScreen. Every screen has its own `Side_Navbar` copy
(same properties on every copy; `Forecast: '=Forecast '`).

| Screen | Page (`varCurrentPage`) | Suffix | Dialogs on the screen |
| --- | --- | --- | --- |
| DashboardScreen | Dashboard (`dashboard`) | `_DS` | – |
| EmployeeScreen | Employee Register (`resource`) | `_ER` | Res_EditScreen_ER, Res_AddScreen_ER |
| InputsScreen | Monthly Inputs (`payroll`) | `_MI` | ApprovalComment_MI, PR_EditScreen_MI, PR_CreateScreen_MI |
| ApprovalScreen | Approval (`treasurer`) | `_AP` | ApprovalComment_AP, cntValidationScreen_AP; month dropdown PrPeriodDrp_1_AP in the header |
| BudgetScreen | Budget Input | `_BI` | NbDlg_BI (new budget), HrDlg_BI (planned hire) |
| BudgetApproval | Budget Approval | `_BA` | ApDlg_BA (approve / reject) |
| `Forecast ` (trailing space) | Forecast | `_FC` | AdjDlg_FC (adjust salary), HrDlg_FC (planned hire) |
| CostCenter | Cost Center | `_CC` | – |
| SettingsScreen | Settings (`setting`) | `_ST` | – |

File names in `powerapps/screens/` match the screen name;
`Forecast ` is stored as `Forecast.yaml` (a file name cannot end in a space).

- Every renovated screen has: background image, its Side_Navbar copy, AppHeader
  (title = varCurrentLabel, refresh button), body container, Loading overlay.
- Month / scenario selection: each screen keeps its own selection in a context
  variable (`locPeriodKey` for months, `locScenarioId` for budgets, `locFcId` /
  `locFcQ` for the forecast), first visit = the open month / newest item,
  remembered afterwards. InputsScreen still sets `varPrPeriod`, but nothing reads
  it any more.
- Navigation: component `Side_Navbar` (final). Screen inputs Dashboard, Employees,
  Inputs, Approval, Settings, CC, BudgetInput, BudgetApproval, Forecast, each
  defaulting to its screen; also CurrentPage and the event OnNavSelect(Page,
  Label). On every screen the copy's OnNavSelect only sets varCurrentPage /
  varCurrentLabel; the screen you land on loads its own data. A leftover filter
  `Page <> "a" || userId = GUID(...)` in the menu Items does nothing and can be
  removed.

#### Monthly Inputs (InputsScreen)

- Reads `colMonthInputs` / `colMonthApproval` for `locPeriodKey`. The grid is
  editable only when the month's `IsOpen` (OPEN or IN_APPROVAL), whatever the
  calendar date.
- Grid (`PrList_MI`): flexible containers. Columns Name (name, ID, red
  "Rejected: …" line), Overtime / Unpaid leave / Outstanding (shown
  "days | USD"; input in days), Bonus (USD), Seniority (June and December only),
  Status icon (rejected / checked / not checked).
- Edit dialog -> `SP_SAVE_MONTHLY_INPUT` (days + bonus USD; no notes field:
  decided). A red banner shows the Treasurer's rejection comment; an amber banner
  shows when an approval step is already approved, and the button reads "Save and
  reset approvals".
- Exchange rates panel -> `SP_SAVE_EXCHANGE_RATE` (open month only).
- "Create <Month>'s Payroll" (only when no month is open) -> dialog prefilled from
  V_D_PERIOD -> `SP_SAVE_EXCHANGE_RATE` then `SP_OPEN_PAYROLL_PERIOD`.
- Step 1 only: Approve (`SP_APPROVE_STEP`, step 1) and Undo (`SP_UNDO_APPROVAL`,
  step 1). No reject on this screen. Approve / Undo are not hidden by role (the
  procedure refuses).

#### Approval (ApprovalScreen)

- Reads the three month loaders for its own `locPeriodKey`.
- Employee checks (step 2 only, while step 2 is the next step): the green check
  toggles CHECKED <-> PENDING; the red button opens the reject dialog (reason
  required, prefilled); "Approve All" checks every employee still PENDING
  (rejected ones stay rejected: decided). All through `SP_SET_EMPLOYEE_CHECK`.
- "Process" opens the dialog for step 2 or 3: Approve (`SP_APPROVE_STEP`; step 2
  disabled until every employee is CHECKED) or Reject (`SP_REJECT_STEP`, comment
  required, sends back one step). Step 1 is approved on Monthly Inputs.
- When all steps are approved the button becomes "Finalize month" (confirm) ->
  `SP_FINALIZE_PAYROLL`.
- "Undo Approval" undoes the last approved step if it is step 2 or 3.
- KPIs and payment summary from V_F_DASHBOARD_MONTH (selected month vs the month
  before).
- ApprovalTimeline component fed from `colMonthApproval`: status "Approved" /
  "Pending" (IsNext) / "Waiting"; approver and date only when APPROVED or REJECTED.

#### Budget Input (BudgetScreen)

- Toolbar: budget dropdown (`colBudgets`, "2027 Base · Draft"), New Budget, Delete
  Budget (not in approval / official; `SP_DELETE_SCENARIO`), Submit for approval
  (Draft / Rejected; `SP_SUBMIT_SCENARIO`). KPIs: Annual Budget (employer cost),
  monthly (÷ 12), bonus, fringe (per month), headcount (+ new hires). Status
  banner (draft / waiting for step N / rejected by … with comment / approved –
  official) + the budget's exchange rate.
- Grid (flexible containers, `colBudgetGrid`): editable only when DRAFT or
  REJECTED; edits are held on screen (rows tinted) and **Save** sends one
  `SP_SAVE_SCENARIO_EMPLOYEE` call (changed rows: salary, raise %, revaluation
  month, insurance, work permit, visa) and one `SP_SAVE_MONTHLY_INPUT` call
  (bonuses, March). Discard reloads. While unsaved changes exist, the dropdown and
  the other actions are disabled. "Latest Raise" is read-only.
- New Budget dialog: year (this + 2), name prefilled "YYYY ", start from current
  employees or a copy of a budget of that year, exchange rate, description;
  refuses an existing name and a year without budget working days ->
  `SP_CREATE_SCENARIO(…, P_FX_RATE)`.
- Planned hire dialog (add / edit): position (= name), category, contract,
  chamber, salary, first / last month -> `SP_SAVE_PLANNED_HIRE`; delete icon ->
  `SP_DELETE_PLANNED_HIRE`. No nationality (not used by the calculation).

#### Budget Approval (BudgetApproval)

- Dropdown lists every budget (opens on the first in approval, else the newest).
- KPI row as Budget Input; summary strip: ECCC / CCIFC annual employer cost, ToS
  in KHR, NSSF (EE + ER), bonus, seniority. Grid (`colBudgetReview`): chamber,
  gross, bonus + seniority, net, tax, employer cost, totals row.
- ApprovalTimeline fed like ApprovalScreen from `colBudgetApproval`; Undo (last
  approved step while in approval); approval comments panel.
- Process dialog: Approve / Reject (comment required) with `SP_APPROVE_STEP` /
  `SP_REJECT_STEP` (month 0). Final step: "Approve (final)", amber box lists what
  becomes official and which budgets of the year are deleted; after success the
  app calls `SP_DELETE_SCENARIO` for each other budget of that year not in
  approval.

#### Forecast (`Forecast `)

- Quarter dropdown Q1–Q3 of the open payroll year (state: forecast / not created /
  not available); Create / Recreate (confirm) -> delete the same quarter's
  forecast if any, `SP_CREATE_FORECAST`, then delete the year's other forecasts.
- Grid (`colFcGrid`): Jan–Dec gross (actual months blue) + total; KPIs headcount,
  annual gross (employer cost in small text), average monthly; summary ECCC /
  CCIFC gross, ToS KHR, seniority, bonus.
- Click an employee -> Adjust salary dialog (salary + increase %, from a forecast
  month) -> `SP_SAVE_SCENARIO_EMPLOYEE` (current salary kept before the month,
  raise % computed, revaluation month). Click a new hire -> hire dialog (edit /
  Remove). Add New Hire -> `SP_SAVE_PLANNED_HIRE` (forecast months only). Changes
  save immediately.

#### Cost Center (CostCenter)

- Kept the original layout on purpose (user request): Employee List left; right
  column month dropdown, HTML "Department Cost Distribution" chart, then a card
  with INFORMATION SUMMARY, Working Days / funds and Cost Center Distribution
  panels, and a **footer bar** across the card with the pending-changes summary,
  Discard and **Save changes** (one save for both splits; placed outside the
  panels so it clearly saves both).
- Department inputs for the 7 departments (`colCcEdit`), total must be 100; fund
  inputs in days (CCIFC, EU Gate; ECCC = remaining). Save sends only what changed:
  `SP_SAVE_DEPARTMENT_ALLOCATION` and / or `SP_SAVE_FUND_ALLOCATION` (the fund
  split is also saved when an employee gets a department split but had no fund
  split).
- Closed months read-only; "Save changes and reset approvals" when a step is
  approved.

#### Settings (SettingsScreen)

- Original layout kept. Working days: ACTUAL and BUDGET grids (calendar year + 2);
  changed months tinted, finalized actual months grey ("closed", read-only); Save
  sends only changed months -> `SP_SAVE_WORKING_DAYS` ('ACTUAL' then 'BUDGET');
  amber note when the open month changes (approvals reset).
- Approval Settings: cards from `colApprovalSteps` (title, "Assign to" email,
  "Current:" holders); Save -> `SP_SAVE_APPROVAL_STEPS` with changed steps only. A
  new email **adds** an approver (name = part before "@"); current holders keep
  their level; removing someone = deactivate in Snowflake.

### UI conventions (Power Apps)

- Grids: flexible (auto-layout) containers. The header row owns the column widths
  (`FillPortions`); gallery row cells and the totals row take `FillPortions`, gap
  and padding from the header. A hidden column (Visible false in header, row and
  total) collapses. Fixed-width end columns copy the header's Width. Cells inside
  a container in a gallery select the row with `Select(GalleryName)` (not
  `Select(Parent)`). Reference: the Budget Input grid (GridHdr_BI / Gallery_BI /
  GridTot_BI).
- Dialogs (style of the original approval dialog): backdrop RGBA(0,0,0,0.2) that
  closes on click; card with a 0.5 border RGBA(0,0,0,0.25), no shadow, radius 16;
  grey header band (RGBA 245) with a round tinted icon (green check for approvals,
  blue for the rest), 14 semibold title, 12 grey description and a line under it;
  body with 14 semibold section labels, bordered light boxes (RGBA 250, border
  RGBA(214,221,224)) and inputs with that border and radius 16; grey footer band
  (74 high, line on top) with rounded buttons (radius 16) on the right: Cancel
  outlined, main action filled (green Approve, blue otherwise). Card height
  follows its content.
- Status banners: blue = info / draft, amber = approvals will be reset / in
  approval, red = rejected / error, green = approved, grey = read-only.
- When the user asks to keep an old screen's design, rebuild it on the old layout
  and change only what the data or a decision requires (done for Cost Center and
  Settings).
- Classic `Label@2.5.1` has no Radius properties (use a container around it for
  corners).

## Power BI

Each table reads one RPT view (Import mode): Fct_Payroll → V_F_PBI_PAYROLL,
EmployeeParams → V_P_PBI_EMPLOYEE_PARAMS, DimEmployee → V_D_PBI_EMPLOYEE,
Employee_Details → V_D_PBI_EMPLOYEE_DETAILS, Payroll_Approval →
V_F_PBI_PAYROLL_APPROVAL, signatures → V_D_PBI_SIGNATURE. Sign-in with Microsoft
account (SSO) as the user's own Snowflake user; scheduled refresh would run under
that account (consider a service account before go-live). `Tot_Allowance` =
outstanding-leave payouts.

## Status and open items

- Snowflake model, procedures, tests (01–03) pass on dummy data; the flow works.
  Every screen reads RPT views and writes through APP procedures.
- To verify: Settings greys finalized months with
  `colActualPeriods.Status = "FINALIZED"`; adjust if LoadSession names the field
  differently.
- Clean-up:
  - ApprovalTimeline component: replace the `StepOne` / `StepTwo` / `StepThree`
    defaults (still `LookUp(Payroll_Approval, …)`) with `="Step 1"` etc., in place.
    Optional: a red "Rejected" state.
  - Search the app (and the other components: KPI Card, LoadingScreen,
    ValueComparison, Side_Navbar) for Payroll_Approval, Payroll_Budget,
    EuroCham_Payrolls, Essbase.
  - Retire `LoadTransactions()`, `LoadApproval()` and the compatibility
    collections (colAllTransactions, Transactions, TransactionsPrev, colKpiData,
    colPayroll, colValidationRecords, varApprovalData, varHR…, colYearOptions)
    from App.Formulas and App.OnStart once nothing reads them.
  - Remove the Essbase flows (EssbaseRead_V2, EssbaseWrite, EssbaseDimBuild_V2,
    Essbase_BOE, Essbase_Variable, Essbase_RunJob, Essbase_Budget_Scenario) and
    the SharePoint lists / connections (Payroll_Approval, Payroll_Budget,
    Payroll_Drafts, Treasurer_Validation_Records, Employee_Record,
    EuroCham_Payrolls, FX_Audit).
  - SP_GET_EMPLOYEE_BANK: procedure and grant are gone from the repo (2026-10-19);
    still to remove it from the flow's `Allowed` list in Power Automate, and drop it
    from the existing Dev database (the DLSync deploy does not drop objects).
  - Update docs/flows.md (roles V1.7.0, bank in V_D_EMPLOYEE, new screens,
    `grants/grants.sql`); the README was rewritten on 2026-10-19.
- DLSync roll-out (the repo is converted; nothing is deployed yet):
  - GitHub workflows (`.github/workflows`: validate on pull request, deploy on
    push to `develop` / `main`), with the `dev` / `prod` environments, secrets and
    `${DB}` substitution in `grants/grants.sql`.
  - `tools/check.py` (named in the root CLAUDE.md, never written) for the new layout:
    file name = object name, one statement per file, `${DB}`, grants vs signatures,
    `CALL APP.SP_…` in the app.
  - Snowflake set-up by IT: service user (key pair) with `SF_APA_PAYROLL-DBA`, a
    `DLSYNC` schema per database, and the `APP` / `RPT` schemas (the scripts do not
    create them; either add schema scripts under `db_scripts/main/ACCOUNT/SCHEMAS/`
    or create them by hand).
  - First deploy to an empty Dev; load `dev_data/load_dummy_data.sql`; run tests
    01–03; compare the tables with the old Dev. Existing Dev can instead be
    registered with `dlsync deploy --only-hashes`.
  - Approver signatures: the old V1.3.0 file (real signature images, later moved to
    `T_D_APP_USER.SIGNATURE_IMAGE`) is deliberately not in `db_scripts/`: decide
    where it lives (e.g. a one-off script in `optional/`). `dev_data/load_dummy_data.sql`
    still refers to users that V1.5.0 had created from it.
  - Stale wording kept as it was: the comments of `T_F_SCENARIO_PERIOD.FX_RATE_NBC`
    / `FX_RATE_NSSF` mention the dropped `T_P_FX_RATE`.
  - Not verified against DLSync yet (first run will tell): the History comment above
    `CREATE` in view / procedure files, `COPY GRANTS`, the `--` comment lines inside
    table versions, the self-referencing foreign key of `T_D_SCENARIO`.
  - Remove leftover `_AP_1` dialogs (old SharePoint logic) if they still exist;
    set the empty `Employees` input of Side_Navbar_MI to `=EmployeeScreen`;
    restyle ApprovalScreen's two dialogs like the Monthly Inputs ones (optional).
- Data migration from Essbase raw data (Jan–Sep 2026) – recalculate, Essbase net
  pay only as a one-time check; verify statutory values (NSSF floor, pension rate
  increase); FLOAT vs NUMBER for money; timezone; optional table-rights revoke for
  the ETL role; nationality list for new nationalities
  (today built from existing employees, code taken from their Resource IDs).