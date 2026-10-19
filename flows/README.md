# Power Automate flow: EuroCham-Snowflake

How Power Apps talks to Snowflake. One flow for everything: reads and procedure calls.

## History

- 2026-10-05 Initial version (two flows planned).
- 2026-10-05 Replaced by one generic flow with a single `Sql` input.

## What it does

The app sends one SQL statement as text. The flow runs it only if it is:

- a `SELECT` (reads; the role can only see the RPT views granted in `A__grants.sql`), or
- a `CALL APP.SP_<name>(...)` of a procedure on the allow-list (the 24 public procedures).

Anything else is refused with `status = ERROR`, `message = Not allowed`. Snowflake also refuses
several statements in one call (multi statement count not set).

The flow returns three text outputs: `status` (OK / ERROR), `message`, `rows` (the result rows
as JSON text). For a `CALL`, `rows` holds one row with one column named after the procedure,
containing the procedure's own `{"status": ..., "message": ...}`.

## Steps in the flow

1. Trigger: **When Power Apps calls a flow (V2)**, one Text input `Sql`.
2. Compose `Text`: `trim(triggerBody()?['text'])`
3. Compose `Allowed`: JSON list of the 24 public procedure names (not SP_CALC_PERIOD,
   SP_RESET_APPROVALS).
4. Compose `Statement`:
   ```
   if(or(startsWith(toUpper(outputs('Text')), 'SELECT '), and(startsWith(toUpper(outputs('Text')), 'CALL APP.SP_'), contains(outputs('Allowed'), toUpper(substring(outputs('Text'), 9, sub(indexOf(outputs('Text'), '('), 9)))))), outputs('Text'), '')
   ```
5. Condition `empty(outputs('Statement'))`: if true, respond ERROR / Not allowed and Terminate.
6. **Submit SQL Statement for Execution** (Snowflake connector): statement = `Statement`,
   database `DEV_PAYROLL_DB` (`PROD_PAYROLL_DB` for the production flow), role `SF_APA_PAYROLL-ETL`, the warehouse; schema empty.
7. Respond: `status` OK, `rows` = `string(body('Submit_SQL_Statement_for_Execution')?['Data'])`.
8. Parallel respond (run after: failed / timed out): `status` ERROR, `rows` = `[]`.

When a procedure is added for the app, add its name to `Allowed` and to `grants/grants.sql`.

## Calling it from Power Apps

The flow is added to the app as `'EuroCham-Snowflake'`.

Read:
```
Set(varAns, 'EuroCham-Snowflake'.Run("SELECT * FROM RPT.V_D_LOOKUP WHERE IS_ACTIVE"));
ClearCollect(colX, ForAll(Table(ParseJSON(varAns.rows)) As r, { Code: Text(r.Value.CODE) }));
```

Procedure:
```
Set(varAns, 'EuroCham-Snowflake'.Run("CALL APP.SP_APPROVE_STEP('" & User().Email & "', " & varActualScenarioId & ", " & varOpenPeriod & ", 1, '" & Substitute(txtComment.Text, "'", "''") & "')"));
Set(varRes, Index(Table(ParseJSON(varAns.rows)), 1).Value.SP_APPROVE_STEP);   // varRes.status, varRes.message
```

JSON payloads (P_EMPLOYEE, P_INPUTS ...) are built with `JSON({...})` and wrapped in
`Substitute(..., "'", "''")`.

## Things to know

- Column names come back in capitals, as in the views. Empty values are left out of the row.
- Dates come back as days since 1970-01-01, timestamps as seconds since 1970-01-01:
  `DateAdd(Date(1970,1,1), Value(Text(x)), TimeUnit.Days)` and
  `DateAdd(DateTime(1970,1,1,0,0,0), Round(Value(Text(x))*1000,0), TimeUnit.Milliseconds)`.
- Very large results come in several partitions; `Data` holds only the first. None of the
  app's reads is anywhere near that size.
- The app sends `User().Email` itself (accepted risk: a user who tampers with the request could
  act as someone else; the app is used by senior management only). The safer alternative is
  the trigger's `x-ms-user-email` header.
