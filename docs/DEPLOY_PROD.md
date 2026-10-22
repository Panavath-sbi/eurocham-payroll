# Deploying EuroCham Payroll dbt to prod

Prod today = database `DEV_PAYROLL_DB`, schemas `APP_PROD` (tables + procedures) and `RPT_PROD` (views), same Snowflake account as UAT.
The database and schemas already exist; this page covers what is configured in the dbt project and in GitHub.

## 1. How prod deploys

`.github/workflows/dbt-prod.yml` runs two Snowflake CLI commands:

1. `snow dbt deploy EUROCHAM_PAYROLL_DBT_PROD --source "EuroCham Payroll dbt"` uploads the project folder into Snowflake as a
   *dbt project object* named `EUROCHAM_PAYROLL_DBT_PROD`, stored in `DEV_PAYROLL_DB.APP_PROD`. Each deploy adds a version.
2. `snow dbt execute EUROCHAM_PAYROLL_DBT_PROD build --target prod` runs `dbt build` inside Snowflake on `SANDBOX_WH`.
   dbt runs the SQL of each model as written (`macros/ddl_table.sql`):
   - tables: `CREATE TABLE IF NOT EXISTS` plus `ALTER ... ADD COLUMN IF NOT EXISTS`. Existing data is never replaced.
   - views and procedures: `CREATE OR REPLACE ... COPY GRANTS`, so the app's grants survive.

`--target prod` is what makes it prod. The name `..._PROD` is only a label.

## 2. `EuroCham Payroll dbt/profiles.yml`

```yaml
EUROCHAM_PAYROLL:
  target: uat              # default for local runs only (the workflow passes --target prod); uat is safer, see below
  outputs:
    prod:
      type: snowflake
      role: '"SF_APA_PAYROLL-DBA"'     # owns the schemas; quoted because of the hyphens
      warehouse: SANDBOX_WH
      database: DEV_PAYROLL_DB
      schema: APP_PROD                 # dbt's default schema only (see below)
      threads: 8
```

| Field | Prod value | Notes |
|---|---|---|
| `role` | `"SF_APA_PAYROLL-DBA"` | Must equal `SNOWFLAKE_ROLE` in the workflow. Keep the inner double quotes. |
| `warehouse` | `SANDBOX_WH` | Must equal `SNOWFLAKE_WAREHOUSE`. |
| `database` | `DEV_PAYROLL_DB` | Must equal `SNOWFLAKE_DATABASE`. |
| `schema` | `APP_PROD` | Default schema only. Tables/procedures go to `APP_PROD` and views to `RPT_PROD` through `macros/generate_schema_name.sql` and `{{ app() }}` / `{{ rpt() }}`: the `uat` and `prod` targets add the suffix `_UAT` / `_PROD` to `APP` / `RPT`. |
| account, user, password | not in the file | The connection comes from the workflow's `SNOWFLAKE_*` variables. |
| top-level `target:` | `uat` recommended | Only the default for runs that give no `--target`. Both workflows pass it explicitly, so CI works with either value. With `prod` as the default, a manual `dbt build` from a laptop would deploy to prod. |

## 3. GitHub setup (once)

1. **Environment.** Repo Settings -> Environments -> New environment `prod`. Add *Required reviewers*. The workflow job says
   `environment: prod`, so it pauses until a reviewer approves. If the environment does not exist, GitHub creates it with no approval step.
2. **Secrets.** Settings -> Secrets and variables -> Actions (repository level, or on the `prod` environment to override):

   | Secret | Used as |
   |---|---|
   | `SNOWFLAKE_ACCOUNT` | `SNOWFLAKE_ACCOUNT` |
   | `SNOWFLAKE_USER` | `SNOWFLAKE_USER` |
   | `SNOWFLAKE_PAT` | `SNOWFLAKE_PASSWORD` (a programmatic access token works as the password; it expires, so note the date) |

## 4. `.github/workflows/dbt-prod.yml`

These values must agree with the `prod` block of `profiles.yml`:

| Workflow value | Prod value | Must match / exist |
|---|---|---|
| `SNOWFLAKE_ROLE` | `SF_APA_PAYROLL-DBA` | `role` in the profile; needs the right to create a dbt project in `SNOWFLAKE_SCHEMA` |
| `SNOWFLAKE_WAREHOUSE` | `SANDBOX_WH` | `warehouse` in the profile |
| `SNOWFLAKE_DATABASE` | `DEV_PAYROLL_DB` | `database` in the profile |
| `SNOWFLAKE_SCHEMA` | `APP_PROD` | Where the project object lives. The schema must already exist. |
| project object name | `EUROCHAM_PAYROLL_DBT_PROD` | Different from UAT (`..._UAT`), so the two never overwrite each other |
| build command | `build --target prod` | The target must exist in `profiles.yml` |
| trigger | `workflow_dispatch` | Manual only. The file must be on `main` for the *Run workflow* button to appear. |
| concurrency | `eurocham-dbt-prod` | One prod run at a time |

## 5. Deploy checklist

1. The UAT run (`dbt-uat.yml` on `eurocham-uat`) is green for the commit you want in prod.
2. Merge `eurocham-uat` into `main` through a pull request (regular merge commit, not squash).
3. GitHub -> Actions -> **EuroCham dbt build (prod)** -> *Run workflow*, branch `main`.
4. A reviewer approves the `prod` environment prompt.
5. Check the run log: `snow connection test`, `snow dbt deploy`, `snow dbt execute` all succeed.
6. In Snowsight, check: the project object exists in `APP_PROD`; the tables are in `APP_PROD` and the views in `RPT_PROD`;
   the app role (`SF_APA_PAYROLL-ETL`) can still read the views and call the procedures.

## 6. Pointing prod at a different database or account later

Change only these places:

| Where | What |
|---|---|
| `profiles.yml` -> `prod` | `role`, `warehouse`, `database`, `schema` (the schema names derive from the `_PROD` suffix) |
| `dbt-prod.yml` -> `env` | `SNOWFLAKE_ROLE`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_SCHEMA` |
| GitHub `prod` environment | `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PAT` for the new account |

The new database, schemas, roles and grants must exist before the first run.

## 7. Rollback and troubleshooting

- **Rollback.** Re-run the workflow from an earlier commit (choose that commit's branch or tag). Views and procedures return to that
  version. Tables are never replaced, so data stays, but a column added by a newer deploy is not removed.
- **"Schema does not exist".** `SNOWFLAKE_SCHEMA` (the project-object schema) must exist before `snow dbt deploy`.
- **Privilege error on `snow dbt deploy`.** The deploy role needs the right to create a dbt project in that schema. Not yet checked on a first run.
- **Authentication error.** The PAT expired or was rotated. Update the `SNOWFLAKE_PAT` secret.
- **Unknown `--target` argument.** I expect `snow dbt execute ... build --target prod` to pass the flag through to dbt, but this has
  not been tested on this CLI version. If it fails, check the CLI's help for how to pass dbt arguments.
- **No Run workflow button.** The workflow file is not on `main` yet.
