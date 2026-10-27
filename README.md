# EuroCham Payroll - deployment scripts

Plain SQL scripts for the tables, views, procedures, stages and functions of the EuroCham payroll app. They create or
update objects in **existing** schemas. The database, the schemas, the roles and the grants are provisioned by the
Snowflake Administrator and are not part of these scripts.

```
deployment/
├── config.yml        per-environment values: database and owner role
├── deploy.py         renders the {{ }} placeholders from config.yml, runs the scripts in order, then verifies
├── tables/           22 scripts   (T_*)
├── views/            31 scripts   (V_*)
├── procedures/       28 scripts   (SP_*)
├── stages/            1 script    (PAYSLIP_TEMPLATE)
└── functions/         1 script    (FN_*)
```

## Rules for every script
- One object per file; the file name is the object name in lower case (`t_d_entity.sql`).
- Starts with an optional `-- depends_on: T_A, T_B` line, then `USE ROLE` and `USE DATABASE` (from `config.yml`). The warehouse comes from the connection / user default.
  `USE ROLE` is the owner role, so every object is created by, and owned by, that role.
- Schemas are written directly: `APP` (tables, procedures, stages, functions) and `RPT` (views). The only placeholders are `{{ database }}` and `{{ role_owner }}`.
- **Tables** are never replaced: `CREATE TABLE IF NOT EXISTS`, structure only (no `INSERT` of reference data; that data
  is loaded once per environment). A new column is an `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` line in the same file;
  a new column **with a `DEFAULT`** needs a guarded `EXECUTE IMMEDIATE` block, because `ADD COLUMN IF NOT EXISTS ... DEFAULT`
  fails when run again. Renames and drops are written by hand.
- **Stages** are `CREATE STAGE IF NOT EXISTS`; the files in them are uploaded by hand.
- **Views, procedures and functions** are `CREATE OR REPLACE ... COPY GRANTS`, so existing grants survive a redeploy.
- Every script is safe to run again: every deployment runs all scripts.

## Order
`DEPLOY_ORDER` at the top of `deploy.py` lists every script, in the order they run: tables, views, procedures, stages,
functions, then the views that use a function, dependencies first (needed for table foreign keys and for views that
read other views). Before every run, `deploy.py`
checks the list against the folders and stops if a script is not listed, is listed but missing, is listed twice, or comes
before a script named in its own `-- depends_on:` line.

## Deploying Process
Choose one of the two ways below. Both run the same scripts, then verify; a good run ends with
`DEPLOYMENT CONFIRMED (<env>)`.

### Option 1: GitHub Actions
A push or merged pull request to `main` deploys to prod (`.github/workflows/eurocham-deploy.yml`).

**Pre-requisite** (before running the GitHub Actions workflow): in GitHub -> Settings -> Secrets and Variables -> Actions, add these repository secrets:

| Secret | Value |
|---|---|
| `SNOWFLAKE_ACCOUNT` | Snowflake account identifier |
| `SNOWFLAKE_USER` | Snowflake user that runs the deployment |
| `SNOWFLAKE_PAT` | a PAT of that user, generated for the `EUROCHAM_PAYROLL-DBA` role |

When the secrets are right, the step "Check the Snowflake connection" prints:

```
CONNECTED to Snowflake account <prod account> as *** (role EUROCHAM_PAYROLL-DBA, warehouse EUROCHAM_WH)
```

If a secret is missing or wrong, the run stops at that step with `CONNECTION FAILED`.

### Option 2: Snowsight
Open this folder in a Snowsight Workspace, open `deploy.py`, and set the settings at the top:

```python
ENV = 'prod'     # which block of config.yml to use: 'uat' or 'prod'
ONLY = None      # None = all scripts, or a subset, e.g. ['views'] or ['t_d_entity']
RUN = False      # False = dry run: only prints the SQL.  True = deploys
VERIFY = False   # with RUN = False: True = only check what is deployed (read-only)
```

1. **Dry run.** Keep `RUN = False` and press Run. The Output tab prints every script with the database and `USE ROLE`
   of the chosen environment. Nothing is sent to Snowflake.
2. **Deploy.** Set `RUN = True` and press Run again. The run stops at the first error.

## Confirming the deployment
A run without an error is not yet a confirmed deployment. After every run, `deploy.py` checks all 83 objects, not only
the ones it deployed. The output must end with:

```
VERIFY (prod): EUROCHAM_PAYROLL_DB
  tables in APP     22/22
  views in RPT      31/31
  procedures in APP 28/28
  stages in APP     1/1
  functions in APP  1/1
  views compile     31/31
  unexpected        none
DEPLOYMENT CONFIRMED (prod): all 83 objects verified in EUROCHAM_PAYROLL_DB.
```

Anything else ends with `DEPLOYMENT NOT CONFIRMED (prod)`; the line with the problem names the missing, broken or
unexpected objects. To only check prod without deploying, run in Snowsight with `RUN = False` and `VERIFY = True`.

## Deployment log
Every run with `RUN = True` / `--run` writes one row to `APP.T_F_DEPLOY_LOG`, whatever the outcome (dry runs and
VERIFY-only checks are not logged):

| Column | Content |
|---|---|
| `STATUS` | `CONFIRMED`, `NOT CONFIRMED` (verification found problems) or `FAILED` (a statement failed) |
| `CHANGED_SCRIPTS` | scripts changed in git since the last `CONFIRMED` deployment of that environment, e.g. `tables/t_d_employee.sql, views/v_d_employee.sql`; `none` = a redeploy without changes; empty from Snowsight or for the first logged deployment |
| `OBJECTS_ADDED_REMOVED` | objects that appeared or disappeared during the run, e.g. `added: table T_D_NEW; removed: table T_D_OLD` |
| `FAILED_SCRIPT`, `ERROR_MESSAGE` | the script that stopped the run and the first line of the error, or the verification problems |
| `VERIFY_SUMMARY` | the verification counts |
| `GIT_COMMIT`, `TRIGGERED_BY`, `RUN_URL` | the commit deployed, who pushed or merged it, and the link to the GitHub Actions run (from Snowsight: the Snowflake user) |
| `STARTED_AT`, `FINISHED_AT`, `DEPLOYED_BY` | timing and the Snowflake user of the deployment |

## Future DDL/Objects changes
To change an object, change its own script, the same file that created it. There is no separate "change script".

Every deployment runs all the scripts again, and each script is written so that running it again is harmless. So
redeploying is always safe: objects that have not changed stay as they are, and nothing is lost.

- **Views, procedures and functions** are simply replaced by the new version.
- **Tables are never replaced**, so their data is always kept. A change to a table (a new column, a renamed column, ...)
  is written as an extra line in the table's script that updates the existing table, next to the table definition.
- **A new object** is a new script in the right folder, also added to the list in `deploy.py`.
- **Removing an object** means deleting its script, and dropping the object by hand in Snowflake; until then, the
  verification reports it as `unexpected`.

Every change goes to uat first (`eurocham-dev`), and reaches prod only through a pull request into `main`. Each
deployment should end with `DEPLOYMENT CONFIRMED`.

## Not included
- Database, schemas, roles, users and integrations: provisioned and maintained by the Snowflake Administrator.
- Grants to the application role: managed by the Snowflake Administrator. A new view or procedure that needs a grant
  that the schema's existing grants do not already cover must be requested from the Snowflake Administrator.
- Reference data rows (departments, periods, tax brackets, ...): loaded once per environment, not by these scripts.
