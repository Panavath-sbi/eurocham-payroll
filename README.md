# HR_PAYROLL_SBI_APAC – EuroCham payroll on Snowflake

Database objects for the EuroCham payroll, budget and forecast app (ECCC and CCIFC):
tables, views and stored procedures. Power Apps reads the views and writes only by
calling the procedures. The objects are deployed with
[DLSync](https://github.com/Snowflake-Labs/dlsync) from GitHub Actions.

## Layout

| Folder | Contents | Deployed to |
| --- | --- | --- |
| `db_scripts/main/PAYROLL_DB/APP/TABLES/` | One file per table (migration scripts: numbered versions) | Dev and Prod, by DLSync |
| `db_scripts/main/PAYROLL_DB/APP/PROCEDURES/` | One file per stored procedure (`CREATE OR REPLACE`) | Dev and Prod, by DLSync |
| `db_scripts/main/PAYROLL_DB/RPT/VIEWS/` | One file per view (`CREATE OR REPLACE`) | Dev and Prod, by DLSync |
| `db_scripts/parameter-dev.properties`, `parameter-prod.properties` | The value of `${DB}` per environment (`DEV_PAYROLL_DB`, `PROD_PAYROLL_DB`) | – |
| `grants/grants.sql` | Rights of the app's role; run after every deploy | Dev and Prod |
| `dev_data/` | Dummy data, check queries, snapshot save / restore | Dev only, run by hand |
| `tests/` | Test calls for the procedures, each with its expected result | Dev only, run by hand |
| `flows/` | The Power Automate flow (EuroCham-Snowflake) and how the app calls it | Built by hand in Power Automate |
| `optional/` | Extras that need a decision first (bank-detail masking, Enterprise Edition) and dev-only extras (`load_dummy_signatures.sql`: dummy approver signatures for Power BI) | Run by hand when agreed |
| `docs/` | Documentation |  |

The `PAYROLL_DB` folder name is only a folder: the real database comes from `${DB}`.

## Script rules

- One object per file; the file name is the object name in capitals (`T_D_ENTITY.SQL`).
- Every object name is written `${DB}.APP.<name>` or `${DB}.RPT.<name>`. No `USE DATABASE`.
- **Tables** use versions: `---version: 0` creates the table, later changes are added as
  `---version: 1`, `2`, … (`ALTER TABLE …`). Never edit a version that has been deployed.
  Each version has a one-line `---rollback:` and `---verify:`.
- **Views and procedures** are edited in place. They carry `COPY GRANTS`, so the app's
  rights survive a redeploy. Procedures keep `COMMENT` before `EXECUTE AS OWNER`.
- Every file keeps its **History** header with a dated line per change.
- A new procedure or view for the app also needs a line in `grants/grants.sql`.

## How a change reaches Snowflake

1. Edit the file on a branch.
2. Open a pull request: the plan (what DLSync would change) is posted on it.
3. Merge into `develop`: deployed to Dev (`DEV_PAYROLL_DB`).
4. Merge `develop` into `main`: deployed to Prod (`PROD_PAYROLL_DB`).

(The GitHub workflows are added in a later step.)

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

1. Deploy `db_scripts/` to Dev, then run `grants/grants.sql`.
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
