# EuroCham Payroll - deployment scripts

Plain SQL scripts for the tables, views and procedures of the EuroCham payroll app. They create or update objects in
**existing** schemas. The database, the schemas, the roles and the grants are provisioned by the Snowflake Administrator and are
not part of these scripts.

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

## Running (in Snowsight)
> **Note:** Before the first run, configure the `prod` block in `config.yml`.

Open this folder in a Snowsight Workspace and open `deploy.py`. The three settings at the top decide what happens:

```python
ENV = 'uat'      # which block of config.yml to use: 'uat' or 'prod'
ONLY = None      # None = all scripts in DEPLOY_ORDER, or a subset, e.g. ['views'] or ['t_d_entity']
RUN = False      # False = dry run: only prints the rendered SQL.  True = executes it
```

1. **Dry run.** Set `ENV` to `uat` or `prod`, keep `RUN = False`, and press Run. The Output tab prints every script with the
   values from `config.yml` filled in (database, schemas, owner role), in deploy order. Nothing is sent to Snowflake.
2. **Check the output.** Look at the schema and database names and the `USE ROLE` line for the environment you chose.
3. **Deploy.** Set `RUN = True` and press Run again. Each statement is printed as it runs, tables first, then views, then
   procedures. The run stops at the first error.

## Adding or changing an object
1. Edit or add the file in the right folder; list what it uses in `-- depends_on:`, and add the file to `DEPLOY_ORDER` in `deploy.py` (after what it depends on).
2. Add new columns as `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` lines in the table's own script.
3. Add a History line at the top of the file for the change.
4. In `deploy.py` set `ONLY = ['<script name>']` and `RUN = False` to check the SQL, then `RUN = True` to deploy it.

## Not included
- Database, schemas, roles, users and integrations: provisioned and maintained by the Snowflake Administrator.
- Grants to the application role: managed by the Snowflake Administrator. A new view or procedure that needs a grant
  that the schema's existing grants do not already cover must be requested from the Snowflake Administrator.
- A record of what has run (no history table): the scripts are safe to repeat instead.
