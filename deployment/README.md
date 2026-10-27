# EuroCham Payroll - deployment scripts

Plain SQL scripts for the tables, views and procedures of the EuroCham payroll app. They create or update objects in
**existing** schemas. The database, the schemas, the roles and the grants are provisioned by the Snowflake Administrator and are
not part of these scripts.

```
deployment/
├── config.yml        per-environment values: database and owner role
├── deploy.py         renders the {{ }} placeholders from config.yml, runs the scripts in order and confirms the result
├── tables/           22 scripts   (T_*)     run first (T_F_DEPLOY_LOG, the deployment log, is the first)
├── views/            30 scripts   (V_*)     run second
└── procedures/       28 scripts   (SP_*)    run last
```

## Deployment process
`eurocham-dev` holds exactly what runs in **uat**, and `main` exactly what runs in **prod**. Nobody runs DDL by hand in prod.

```
change ──push──► eurocham-dev ──► deploy uat + verify
                      │
                      └──PR──► main ──► Snowflake Administrator approves ──► deploy prod + verify
```

1. Make the change on `eurocham-dev` (see *Adding or changing an object*) and push. GitHub Actions
   (`.github/workflows/eurocham-deploy.yml`) deploys it to uat and verifies it.
2. When uat is confirmed, open a pull request from `eurocham-dev` to `main`.
3. Merge. The same workflow waits for the Snowflake Administrator's approval, then deploys to prod
   (`EUROCHAM_PAYROLL_DB`, role `EUROCHAM_PAYROLL-DBA`) and verifies it.
4. Every change, including urgent fixes, goes through `eurocham-dev`.

The deployment is **state-based**: each file is the current definition of one object, and every push deploys all scripts.
Unchanged scripts change nothing (tables are never replaced; views and procedures are re-applied as they are in git), so a full
run is safe, takes a few minutes, and also repairs anything that drifted from git.
To deploy only some scripts by hand: **Run workflow** with `only` (e.g. `t_d_employee v_d_employee`), or `ONLY` in Snowsight.
**Run workflow** on *EuroCham deploy* also has an `environment` choice (`uat` / `prod`): it deploys the code of the
branch you pick to that environment; `prod` always waits for the Snowflake Administrator's approval. The button appears
once the workflow file is on `main` (a GitHub rule). Each run is titled `EuroCham deploy | <environment> | <branch>`.

A failed prod run leaves `main` ahead of prod: fix the cause (for example a missing privilege) and re-run the job, or fix it
through `eurocham-dev`.

## Confirming the deployment
A run without an error is **not** yet a confirmed deployment. After every run, `deploy.py` checks all 80 objects, not only
the ones it deployed. The output must end with:
```
VERIFY (prod): EUROCHAM_PAYROLL_DB
  tables in APP     22/22
  views in RPT      30/30
  procedures in APP 28/28
  views compile     30/30
  unexpected        none
DEPLOYMENT CONFIRMED (prod): all 80 objects verified in EUROCHAM_PAYROLL_DB.
```
A short count names the problem on the same line (`missing: ...`, `broken: ...`, `cannot list ...`). `unexpected` lists any
table, view or procedure in `APP` / `RPT` that is not in `DEPLOY_ORDER`, such as a leftover table after a rename. Either way
the run ends with `DEPLOYMENT NOT CONFIRMED`.

## Deployment log
Every run with `RUN = True` / `--run` writes one row to `APP.T_F_DEPLOY_LOG`, whatever the outcome (dry runs and
`VERIFY`-only checks are not logged):

| Column | Content |
|---|---|
| `STATUS` | `CONFIRMED`, `NOT CONFIRMED` (verification found problems) or `FAILED` (a statement failed) |
| `CHANGED_SCRIPTS` | scripts changed in git since the last `CONFIRMED` deployment of that environment, e.g. `tables/t_d_employee.sql, views/v_d_employee.sql`; `none` = a redeploy without changes; empty from Snowsight or for the first logged deployment |
| `OBJECTS_ADDED_REMOVED` | objects that appeared or disappeared during the run, e.g. `added: table T_D_NEW; removed: table T_D_OLD` |
| `FAILED_SCRIPT`, `ERROR_MESSAGE` | the script that stopped the run and the first line of the error, or the verification problems |
| `VERIFY_SUMMARY` | the verification counts |
| `GIT_COMMIT`, `TRIGGERED_BY`, `RUN_URL` | the commit deployed, who pushed or merged it, and the link to the GitHub Actions run (from Snowsight: the Snowflake user) |
| `STARTED_AT`, `FINISHED_AT`, `DEPLOYED_BY` | timing and the Snowflake user of the deployment |

```sql
SELECT DEPLOY_ID, ENV, STATUS, CHANGED_SCRIPTS, OBJECTS_ADDED_REMOVED, FAILED_SCRIPT, ERROR_MESSAGE,
       GIT_COMMIT, TRIGGERED_BY, FINISHED_AT
FROM EUROCHAM_PAYROLL_DB.APP.T_F_DEPLOY_LOG
ORDER BY FINISHED_AT DESC;
```
Not logged: a run that cannot connect (see the GitHub Actions log), and a failure before the log table exists (first run
in a new environment); then `WARNING: deployment log not written` is printed. Column-level detail of a change is in the
commit (`GIT_COMMIT`). Reading the log needs a `SELECT` grant from the Snowflake Administrator.

## Rules for every script
- One object per file; the file name is the object name in lower case (`t_d_entity.sql`).
- Starts with an optional `-- depends_on: T_A, T_B` line, then `USE ROLE` and `USE DATABASE` (from `config.yml`). The warehouse comes from the connection / user default.
  `USE ROLE` is the owner role, so every object is created by, and owned by, that role.
- Schemas are written directly: `APP` (tables, procedures) and `RPT` (views). The only placeholders are `{{ database }}` and `{{ role_owner }}`.
- **Tables** are never replaced: `CREATE TABLE IF NOT EXISTS`. Changes follow *Changing a table* below.
  Table scripts hold no data (no `INSERT` / `MERGE`): reference rows and payroll data are loaded and maintained in each
  environment, not by the deployment.
- **Views and procedures** are `CREATE OR REPLACE ... COPY GRANTS`, so existing grants survive a redeploy.
- Every script is safe to run again.

## Order
`DEPLOY_ORDER` at the top of `deploy.py` lists every script, in the order they run: tables, then views, then procedures,
dependencies first (needed for table foreign keys and for views that read other views). Before every run, `deploy.py`
stops if a script is not listed, is listed but missing, is listed twice, or comes before a script named in its own
`-- depends_on:` line.

## Changing a table
The `CREATE TABLE IF NOT EXISTS` shows the final state, for a new environment. The statement below it brings existing
environments there. Both live in the table's own script.

| Change | Write |
|---|---|
| Add column (no default) | `ALTER TABLE APP.T_X ADD COLUMN IF NOT EXISTS NEW_COL TEXT COMMENT '...';` |
| Add column **with a DEFAULT** | guarded block (below): Snowflake rejects `ADD COLUMN IF NOT EXISTS ... DEFAULT` on a rerun (`ambiguous column name`) |
| Drop column | `ALTER TABLE APP.T_X DROP COLUMN IF EXISTS OLD_COL;` (after a backup) |
| Widen type | `ALTER TABLE APP.T_X ALTER COLUMN C SET DATA TYPE NUMBER(18,2);` |
| Rename table | rename the file, the `CREATE` and the `DEPLOY_ORDER` entry; above the `CREATE`: `ALTER TABLE IF EXISTS APP.T_OLD RENAME TO APP.T_NEW;` |
| Rename column | guarded block (below) |
| Other type change | guarded block: add the new column, copy with `TRY_CAST`, stop if a value failed, drop the old one, rename |

Column rename, run only while the old column still exists:
```sql
EXECUTE IMMEDIATE $$
BEGIN
  IF (EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
              WHERE TABLE_SCHEMA = 'APP' AND TABLE_NAME = 'T_D_EMPLOYEE' AND COLUMN_NAME = 'PHONE')) THEN
    ALTER TABLE APP.T_D_EMPLOYEE RENAME COLUMN PHONE TO PHONE_NUMBER;
  END IF;
END;
$$;
```

Column with a DEFAULT, added only while it does not exist yet (existing rows get the default):
```sql
EXECUTE IMMEDIATE $$
BEGIN
  IF (NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
                  WHERE TABLE_SCHEMA = 'APP' AND TABLE_NAME = 'T_D_EMPLOYEE' AND COLUMN_NAME = 'STATUS')) THEN
    ALTER TABLE APP.T_D_EMPLOYEE ADD COLUMN STATUS TEXT DEFAULT 'NEW' COMMENT 'Employee status';
  END IF;
END;
$$;
```

- Existing rows are always kept. A table script never uses `CREATE OR REPLACE TABLE`, `DROP TABLE`, `TRUNCATE` or `DELETE`
  without `WHERE`; the pull request review checks this.
- Before a destructive step: `CREATE TABLE IF NOT EXISTS APP.T_X_BAK_<yyyymmdd> CLONE APP.T_X;`, and drop the backup once the
  deployment is confirmed (until then it shows as `unexpected`).
- Rollback: revert the pull request. Views and procedures return to their previous version; table data comes back from the
  backup or Time Travel.

## Adding or changing an object
1. Edit or add the file in the right folder; list what it uses in `-- depends_on:`, and add the file to `DEPLOY_ORDER` in `deploy.py` (after what it depends on).
2. For a table, follow *Changing a table*.
3. Add a History line at the top of the file for the change.
4. Push to `eurocham-dev` (see *Deployment process*).

## Running by hand (Snowsight)
For a dry run, a check, or when GitHub Actions is unavailable. Open this folder in a Snowsight Workspace and open
`deploy.py`. The settings at the top decide what happens:

```python
ENV = 'uat'      # which block of config.yml to use: 'uat' or 'prod'
ONLY = None      # None = all scripts, or a subset, e.g. ['views'] or ['t_d_entity']
RUN = False      # False = dry run: only prints the rendered SQL.  True = executes it
VERIFY = False   # with RUN = False: True = only check an earlier deployment (read-only)
```

1. **Dry run.** Keep `RUN = False` and press Run. The Output tab prints every script with the values from `config.yml` filled
   in, in deploy order. Nothing is sent to Snowflake.
2. **Deploy.** Set `RUN = True` and press Run again. The run is silent and ends with the VERIFY block; on an error it stops
   with `DEPLOYMENT FAILED (<env>) in <script>: <error>`.
3. **Check only.** `RUN = False` and `VERIFY = True`: read-only, nothing is changed.

GitHub Actions does not use these settings; it runs `python deploy.py <env> [script ...] --run`.

## Testing in uat
Tested directly in Snowflake, in a Snowsight Workspace, with `ENV = 'uat'`. Edits made for a test are made in the Workspace
copy only and undone afterwards; nothing is committed.

| # | Test | Settings / action | Expected |
|---|---|---|---|
| 1 | Dry run | `RUN = False` | every script printed with `DEV_PAYROLL_DB` and `SF_APA_PAYROLL-DBA`; nothing sent |
| 2 | Current state | `VERIFY = True` | the VERIFY block for uat as it is today (shows anything already missing) |
| 3 | Full deployment | `RUN = True` | `DEPLOYMENT CONFIRMED (uat): all 80 objects` |
| 4 | Rerun is safe | run 3 again; compare `SELECT COUNT(*)` of a few tables before and after | confirmed again, row counts unchanged |
| 5 | Single script | `ONLY = ['v_d_period']`, `RUN = True` | only that script runs; all 80 verified |
| 6 | Leftover table | in a worksheet: `CREATE TABLE DEV_PAYROLL_DB.APP.T_TEST_LEFTOVER (A INT);` then `VERIFY = True` | `unexpected table T_TEST_LEFTOVER`, `NOT CONFIRMED`; then `DROP TABLE` it |
| 7 | Failing script | add a typo to a view file, `ONLY = ['<that view>']`, `RUN = True` | `DEPLOYMENT FAILED (uat) in views/<file>.sql: ...`; no VERIFY block; undo the typo |
| 8 | Unknown name | `ONLY = ['nope']` | `Unknown: ['nope']` |

## One-time setup
**GitHub** (repository Settings)
- Environments `uat` and `prod`; `prod` has the Snowflake Administrator as required reviewer.
- Secrets `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PAT` for the deployment service user.

**Snowflake Administrator**
- One deployment service user with both owner roles in `config.yml` (`SF_APA_PAYROLL-DBA`, `EUROCHAM_PAYROLL-DBA`); in prod,
  only this user holds the owner role. Its default warehouse is the one the deployments use.
- Time Travel on the prod database: 7-30 days (the default is 1).

## Not included
- Database, schemas, roles, users and integrations: provisioned and maintained by the Snowflake Administrator.
- Grants to the application role: managed by the Snowflake Administrator. A new view or procedure that needs a grant
  that the schema's existing grants do not already cover must be requested from the Snowflake Administrator.
- A record of what has run (no history table): the scripts are safe to repeat instead.
