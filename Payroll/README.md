# Payroll – Snowflake

Database objects for the Power Apps payroll application: schemas, tables, views and
stored procedures, deployed with [schemachange](https://github.com/Snowflake-Labs/schemachange).

## Layout

| Folder | Contents | Deployed to |
| --- | --- | --- |
| `migrations/tables/` | Schemas and tables (`V` files) | Every environment (dev, test, prod) |
| `migrations/data/` | Reference data: periods, pay components, tax and NSSF values (`V` files) | Every environment |
| `migrations/views/` | Views (`R` files) | Every environment |
| `migrations/procedures/` | Stored procedures, one per file (`R` files) | Every environment |
| `dev_data/` | Dummy employees, scenarios, payroll rows and check queries | Dev / test only, run by hand |
| `tests/` | Test calls for the procedures, each with its expected result | Dev / test only, run by hand |
| `flows/` | The Power Automate flows: how to build them and the list of reads (`read_catalog.json`) | Built by hand in Power Automate |
| `optional/` | Extras that need a decision first (bank-detail masking, Enterprise Edition) | Run by hand when agreed |

## File naming

| Prefix | Meaning | When it runs |
| --- | --- | --- |
| `V<version>__<name>.sql` | Versioned change (tables, data) | Once, in version order |
| `R__<name>.sql` | Repeatable object (views, procedures) | Whenever the file changes |

Two underscores after the prefix. Repeatable files run after all versioned files, in
alphabetical order.

Rules:

- Never edit a `V` file after it has been deployed. Add a new one, for example
  `V1.2.0__add_payment_method_to_contract.sql`, containing the `ALTER` statements.
- Views and procedures are edited in place in their `R__` file.
- Files contain no `USE DATABASE`; the target database is set per environment by the
  deployment.
- Every file keeps its **History** header, updated with a dated line for each change
  (team guideline).

## Deployment order

1. `tables/V1.0.0__create_schemas.sql` – APP, CORE, RPT (CORE is removed again by V1.5.0)
2. `tables/V1.0.1__create_tables_core_dims_params.sql` – dimensions and parameters
3. `tables/V1.0.2__create_tables_app.sql` – operational tables
4. `tables/V1.0.3__create_tables_core_facts.sql` – fact tables
5. `data/V1.1.0__load_reference_data.sql` – periods, pay components, tax and NSSF parameters, approval chain
6. `tables/V1.2.0__approval_action_send_back.sql` – column comments for the step-back approval flow
7. `tables/V1.3.0__create_signature_table.sql` – signature images for Power BI
8. `tables/V1.4.0__approval_step_state.sql` – one state row per approval step (replaces the action log); one employee check per employee (step 2)
9. `tables/V1.5.0__two_schemas_fewer_tables.sql` – CORE merged into APP (views in RPT); FX rates on the period, role and signature on the user, checks on the monthly input, one approval table; adjustments and the stored cost allocation removed
10. `views/R__views_core.sql` (base views, now in RPT), then `views/R__views_rpt.sql`, `views/R__views_pbi.sql` and `views/R__views_rpt_app.sql` (views read by the Power Apps flows)
11. `procedures/R__sp_*.sql` – any order (a procedure only checks the objects it uses when it runs)

schemachange reads all subfolders of `migrations/`. It runs `V` files by version number,
then `R` files by file name, so the folders can be reorganised freely.

Working days and exchange rates are not part of the migrations; they are entered in the
app. For development, `dev_data/load_dummy_data.sql` loads dummy values.

## Stored procedures

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

## Deploying

schemachange records what it has run in a change-history table. A typical call:

```
schemachange deploy \
  --root-folder migrations \
  --change-history-table PAYROLL_DB.SCHEMACHANGE.CHANGE_HISTORY \
  --create-change-history-table
```

Connection details (account, user, role, warehouse, database) come from environment
variables or a connections file. Option names differ between schemachange versions, so
check `schemachange deploy --help` for the version you install.

## Setting up a dev database

1. Deploy `migrations/` to the dev database.
2. Run `dev_data/load_dummy_data.sql` and review the checks at its end.
3. Run `tests/test_01_payroll_cycle.sql`, then `tests/test_02_remaining_procedures.sql`,
   top to bottom, comparing each result with its expected value.

## Conventions

- Tables `T_D_` (dimension), `T_F_` (fact), `T_P_` (parameter); views `V_D_` / `V_F_` / `V_P_`;
  procedures `SP_`.
- Standard technical columns on every table: `INSERT_DATE`, `UPDATE_DATE`, `INSERT_BY`, `UPDATE_BY`.
- Every column has a `COMMENT`.
- Power Apps writes only through `SP_` procedures, called by Power Automate with the
  user's email. Procedures return `{"status": "OK" | "ERROR", "message": "..."}`.
