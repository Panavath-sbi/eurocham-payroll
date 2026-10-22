# HR_PAYROLL_SBI_APAC – EuroCham payroll on Snowflake

Database objects for the EuroCham payroll, budget and forecast app (ECCC and CCIFC):
tables, views and stored procedures. Power Apps reads the views and writes only by
calling the procedures. The objects are deployed by a dbt project on Snowflake, run from
GitHub Actions (`.github/workflows/dbt-uat.yml`).

## Layout

| Folder | Contents | Deployed to |
| --- | --- | --- |
| `EuroCham Payroll dbt/models/tables/` | One file per table (`CREATE TABLE IF NOT EXISTS` + reference rows inserted once) | APP schema, by dbt |
| `EuroCham Payroll dbt/models/procedures/` | One file per stored procedure (`CREATE OR REPLACE`) | APP schema, by dbt |
| `EuroCham Payroll dbt/models/views/` | One file per view (`CREATE OR REPLACE`) | RPT schema, by dbt |
| `EuroCham Payroll dbt/profiles.yml` | Targets: `dev` (`DEV_PAYROLL_DB.APP/RPT`), `uat` (`DEV_PAYROLL_DB.APP_UAT/RPT_UAT`, default), `prod` (`PROD_PAYROLL_DB.APP/RPT`) | – |
| `snowflake/config/` | `01_database`, `02_schema`, `03_roles` (incl. the app role's grants: run after every deploy), `04_warehouse` | Run by hand |
| `dev_data/` | Dummy data, check queries, snapshot save / restore | Dev only, run by hand |
| `tests/` | Test calls for the procedures, each with its expected result | Dev only, run by hand |
| `flows/` | The Power Automate flow (SF_EuroCham) and how the app calls it | Built by hand in Power Automate |
| `optional/` | Extras that need a decision first (bank-detail masking, Enterprise Edition) and dev-only extras (`load_dummy_signatures.sql`: dummy approver signatures for Power BI) | Run by hand when agreed |
| `docs/` | Documentation |  |

## Script rules

- One object per file; the file name is the object name in lower case (`t_d_entity.sql`).
- Every name is written `{{ app() }}.<name>` (tables, procedures) or `{{ rpt() }}.<name>` (views):
  `APP` / `RPT`, or `APP_UAT` / `RPT_UAT` on the uat target, `APP_PROD` / `RPT_PROD` on prod; the database comes from the target. No `USE DATABASE`.
- The first line lists the objects the file uses: `-- depends_on: {{ ref('t_d_period') }}, …` (build order).
- **Tables** are never replaced: a new column is an `ALTER TABLE {{ app() }}.<name> ADD COLUMN IF NOT EXISTS …`
  line added to the table's file. Renames and drops are written by hand.
- **Views and procedures** are edited in place. They carry `COPY GRANTS`, so the app's
  rights survive a redeploy. Procedures keep `COMMENT` before `EXECUTE AS OWNER`.
- Every file keeps its **History** header with a dated line per change.
- A new procedure or view for the app also needs a line in `snowflake/config/03_roles.sql` (section 10).

## How a change reaches Snowflake

1. Edit the file on the `eurocham-uat` branch and push.
2. GitHub Actions deploys the project (`snow dbt deploy`) and runs `dbt build` on the `uat` target
   (`DEV_PAYROLL_DB.APP_UAT` / `RPT_UAT`).
3. Prod is deployed by hand from `main` (manual workflow, approval required): see [docs/DEPLOY_PROD.md](docs/DEPLOY_PROD.md).

## Stored procedures (APP, 25)

| Area | Procedures |
| --- | --- |
| Calculation (internal) | `SP_CALC_PERIOD`, `SP_RESET_APPROVALS` |
| Payroll cycle | `SP_CALCULATE_PAYROLL`, `SP_OPEN_PAYROLL_PERIOD`, `SP_SAVE_MONTHLY_INPUT`, `SP_FINALIZE_PAYROLL` |
| Approvals | `SP_SET_EMPLOYEE_CHECK`, `SP_APPROVE_STEP`, `SP_REJECT_STEP`, `SP_UNDO_APPROVAL` |
| Employees | `SP_SAVE_EMPLOYEE`, `SP_SAVE_EMPLOYEE_CONTRACT`, `SP_SET_EMPLOYEE_ACTIVE` |
| Cost center | `SP_SAVE_FUND_ALLOCATION`, `SP_SAVE_DEPARTMENT_ALLOCATION` |
| Settings | `SP_SAVE_EXCHANGE_RATE`, `SP_SAVE_WORKING_DAYS`, `SP_SAVE_APPROVAL_STEPS` |
| Budgets and forecasts | `SP_CREATE_SCENARIO`, `SP_SAVE_SCENARIO_EMPLOYEE`, `SP_SAVE_PLANNED_HIRE`, `SP_DELETE_PLANNED_HIRE`, `SP_SUBMIT_SCENARIO`, `SP_DELETE_SCENARIO`, `SP_CREATE_FORECAST` |

Each file's header describes its parameters, rules and the page that calls it.

## Setting up a dev database

1. Run `snowflake/config/02_schema.sql`, `dbt build --target dev`, then section 10 of `snowflake/config/03_roles.sql`.
2. Run `dev_data/load_dummy_data.sql` and review the checks at its end. Optional:
   `optional/load_dummy_signatures.sql` (dummy signatures for Power BI).
3. Run `tests/test_01_payroll_cycle.sql`, then `tests/test_02_remaining_procedures.sql`,
   top to bottom, comparing each result with its expected value.

## Conventions

- Tables `T_D_` (dimension), `T_F_` (fact), `T_P_` (parameter); views `V_D_` / `V_F_` / `V_P_`;
  procedures `SP_`.
- Standard technical columns on every table: `INSERT_DATE`, `UPDATE_DATE`, `INSERT_BY`, `UPDATE_BY`.
- Every column has a `COMMENT`.
- Power Apps writes only through `SP_` procedures, called by Power Automate with the
  user's email. Procedures return `{"status": "OK" | "ERROR", "message": "..."}`.
