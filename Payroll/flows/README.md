# Power Automate flows

How Power Apps talks to Snowflake. Two shared flows: **Payroll – Read** (this file) and
**Payroll – Action** (calls the `APP.SP_` procedures; to be designed).

## History

- 2026-10-05 Initial version: Payroll – Read, with `read_catalog.json`.

## Payroll – Read

The app asks for a read by name (for example `MonthlyInputs`) and passes up to three
numbers. The flow looks the name up in a fixed list of SQL statements
(`read_catalog.json`), puts the numbers in, runs the statement and returns the rows as
JSON. The app can only choose a read from the list; it never sends SQL.

| Placeholder | Meaning |
| --- | --- |
| `{S}` | Scenario id (the actual payroll scenario, a budget or a forecast) |
| `{P}` | Month as YYYYMM (`202610`); for `Calendar` and `BudgetVsActual` the year (`2026`); `0` for a budget's approval |
| `{E}` | Employee id |

Unused numbers can be left at 0. `tests/test_03_reads.sql` runs every read with dummy
values; run it in Snowsight to check the SQL before building the flow.

### Building the flow

1. **Trigger: "When Power Apps calls a flow (V2)"** with four inputs:
   `ReadName` (Text), `ScenarioId` (Number), `PeriodKey` (Number), `EmployeeId` (Number).
   Mark the three numbers as optional.
   In expressions, the trigger names its inputs by type, not by label: normally `text`,
   `number`, `number_1`, `number_2`, in the order they were added. Check with
   "Peek code" on the trigger and adjust the expressions below if they differ.

2. **Compose, renamed `Catalog`.** Paste the whole content of `read_catalog.json` as the
   input. Adding a read later = adding one line here (and the same line to the JSON file).

3. **Compose, renamed `SqlTemplate`.** Expression:
   ```
   outputs('Catalog')?[triggerBody()?['text']]
   ```

4. **Condition:** `empty(outputs('SqlTemplate'))` is equal to `true`.
   - *Yes:* **Respond to a PowerApp or flow** with `status` = `ERROR`,
     `message` = `Unknown read`, `rows` = `[]`. Then **Terminate** (Succeeded).
   - *No:* nothing (continue below the condition).

5. **Compose, renamed `Sql`.** Expression (one line), which turns each number into a whole
   number first, so anything that is not a number makes the flow fail instead of reaching
   Snowflake:
   ```
   replace(replace(replace(outputs('SqlTemplate'),
     '{S}', string(int(string(coalesce(triggerBody()?['number'], 0))))),
     '{P}', string(int(string(coalesce(triggerBody()?['number_1'], 0))))),
     '{E}', string(int(string(coalesce(triggerBody()?['number_2'], 0)))))
   ```

6. **Snowflake: Submit SQL Statement for Execution.** Statement = output of `Sql`;
   database `PAYROLL_DB`; schema `RPT`; your warehouse; the read role (see below);
   Asynchronous = No; timeout 60.

7. **Snowflake: Check the Status and Get Results**, with the statement handle from step 6.

8. **Respond to a PowerApp or flow** with three text outputs:
   - `status` = `OK`
   - `message` = (empty)
   - `rows` = `string(body('Check_the_Status_and_Get_Results')?['Data'])`

   On the first test, open the run history and look at the output of step 7: `rows`
   must be a list of objects such as `[{"PERIOD_KEY": 202610, ...}]`. If it is a list of
   lists instead, tell Claude the exact shape and the expression will be adjusted.

9. **Errors.** Add a second **Respond to a PowerApp or flow** next to step 8, with
   "Configure run after" set to *has failed* / *has timed out* on step 7, returning
   `status` = `ERROR`, `message` = `The read failed`, `rows` = `[]`. The app then always
   gets an answer instead of a flow error.

### Snowflake role for this flow

Reads only need `SELECT` on the RPT views the catalog uses (views run with their
owner's rights, so no access to the APP tables is needed). Give this flow's connection a
role with only that, for example:

```sql
GRANT USAGE ON DATABASE PAYROLL_DB TO ROLE <READ_ROLE>;
GRANT USAGE ON SCHEMA PAYROLL_DB.RPT TO ROLE <READ_ROLE>;
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_D_LOOKUP TO ROLE <READ_ROLE>;
-- ... one line per view used in read_catalog.json
```

Even if something went wrong in the flow, that role cannot change data or read the
Power BI views.

### Calling it from Power Apps (example)

```
Set(varAnswer, 'Payroll-Read'.Run("MonthlyInputs", varActualScenarioId, 202610, 0));
If(varAnswer.status = "OK",
    ClearCollect(colInputs,
        ForAll(Table(ParseJSON(varAnswer.rows)),
            { EmployeeId: Value(ThisRecord.Value.EMPLOYEE_ID),
              Name:       Text(ThisRecord.Value.FULL_NAME),
              Overtime:   Value(ThisRecord.Value.OVERTIME_DAYS),
              Check:      Text(ThisRecord.Value.CHECK_STATUS) })),
    Notify(varAnswer.message, NotificationType.Error)
)
```

Column names come back in capitals, exactly as in the views.

### The reads

| Read | Filters | Used on |
| --- | --- | --- |
| Lookups | – | Dropdowns (chambers, funds, departments) |
| Scenarios | – | Scenario / quarter dropdowns; the actual scenario id |
| ScenarioPeriods | S | Period dropdown, FX card, which month is open |
| Calendar | P = year | Settings: working days; next month's rates |
| Employees | – | Employee Register, Cost Center list |
| EmployeeHistory | E | Edit Employee: contract versions |
| MonthlyInputs | S, P | Monthly Inputs grid; Approval validation buttons |
| ScenarioInputs | S | Budget / Forecast Show Details |
| Allocations | S, P | Cost Center: fund and department panels |
| PayrollSummary | S, P | Approval grid, Cost Center summary |
| ScenarioPayroll | S | Previous month / 6-month average; Budget Approval and Forecast grids |
| PayrollLines | S, P | Cards by component (bonus, seniority, ToS) |
| ScenarioPayrollLines | S | Budget Approval / Forecast cards by component |
| CostCenterSummary | S, P | Cost Center: department bars |
| ScenarioSummary | S | Dashboard trend; Budget and Forecast KPI cards |
| DashboardKpi | – | Dashboard cards |
| BudgetVsActual | P = year | Dashboard budget vs forecast; Approval budget / forecast |
| ApprovalProgress | S, P (0 for a budget) | Approval chain on every approval page |
| ScenarioEmployees | S | Budget Input grid, Forecast |
| ApprovalSteps | – | Settings: approval steps and approvers |
| Users | – | Settings; showing names |

Bank details are not in any read: every app user shares the flow's connection, so
anything readable here is readable by all of them. They will come from a procedure
that checks the caller is a payroll admin, through Payroll – Action.
