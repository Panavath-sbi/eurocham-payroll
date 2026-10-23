# EuroCham Payroll - deployment scripts

Plain SQL scripts for the tables, views and procedures of the EuroCham payroll app. They create or update objects in
**existing** schemas: the database, the schemas, the roles and the grants are created elsewhere (Snowflake setup), not here.

```
deployment/
├── config.yml        per-environment values: database, schemas, owner role
├── deploy.py         renders the {{ }} placeholders from config.yml and runs the scripts in order
├── tables/           21 scripts   (T_*)     run first
├── views/            30 scripts   (V_*)     run second
└── procedures/       28 scripts   (SP_*)    run last
```

## Rules for every script
- One object per file; the file name is the object name in lower case (`t_d_entity.sql`).
- Starts with an optional `-- depends_on: T_A, T_B` line, then `USE ROLE` and `USE DATABASE` (from `config.yml`). The warehouse comes from the connection / user default.
  `USE ROLE` is the owner role, so every object is created by, and owned by, that role.
- The only placeholders are `{{ schema_app }}` (tables, procedures), `{{ schema_rpt }}` (views), `{{ database }}`, `{{ role_owner }}`.
- **Tables** are never replaced: `CREATE TABLE IF NOT EXISTS`. A new column is an `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`
  line in the same file. Renames and drops are written by hand.
- **Views and procedures** are `CREATE OR REPLACE ... COPY GRANTS`, so existing grants survive a redeploy.
- Every script is safe to run again.

## Order
`DEPLOY_ORDER` at the top of `deploy.py` lists every script, in the order they run: tables, then views, then procedures,
dependencies first (needed for table foreign keys and for views that read other views). Before every run, `deploy.py`
checks the list against the folders and stops if a script is not listed, is listed but missing, is listed twice, or comes
before a script named in its own `-- depends_on:` line.

## Running
```bash
python deploy.py uat                          # print all rendered scripts in order, nothing runs
python deploy.py uat tables                   # one folder (or one script: python deploy.py uat t_d_entity)
python deploy.py uat --run -c <connection>    # run them with the Snowflake CLI
python deploy.py prod --run -c <connection>   # prod: fill in the <PROD_*> values in config.yml first
```
Needs `pip install pyyaml`. In Snowsight (Workspace with this folder uploaded), set `ENV`, `ONLY`, `RUN` at the top of `deploy.py`
and press Run. `RUN = False` only prints.

## Adding or changing an object
1. Edit or add the file in the right folder; list what it uses in `-- depends_on:`, and add the file to `DEPLOY_ORDER` in `deploy.py` (after what it depends on).
2. Add new columns as `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` lines in the table's own script.
3. Add a History line at the top of the file for the change.
4. `python deploy.py uat <script>` to check the SQL, then `--run`.

## Not included
- Database, schemas, roles, users, integrations: created by the Snowflake setup scripts.
- Grants to the app role: a new view or procedure may need one; the setup scripts hold the future grants for the schemas.
- A record of what has run (no history table): the scripts are safe to repeat instead.
