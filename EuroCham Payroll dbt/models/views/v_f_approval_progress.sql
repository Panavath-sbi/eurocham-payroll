-- depends_on: {{ ref('t_f_approval') }}, {{ ref('t_d_scenario') }}, {{ ref('t_f_scenario_period') }}, {{ ref('t_p_approval_step') }}
/* =====================================================================================
   V_F_APPROVAL_PROGRESS - Every step of every approval (each payroll month, each submitted budget with PERIOD_KEY 0), its current state, and the next step to act on
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-02  V_F_APPROVAL_PROGRESS reads APP.T_F_APPROVAL_STEP_STATE (one row per step)
               instead of the dropped action log; adds LAST_ACTION and MANAGES_EMPLOYEE_CHECKS.
   2026-10-02  V1.5.0: base views and tables referenced in RPT / APP (CORE removed).
               V_F_COST_CENTER_SUMMARY reads RPT.V_F_COST_ALLOCATION. V_F_APPROVAL_PROGRESS
               reads APP.T_F_APPROVAL by scenario + period (no request id): REQUEST_ID and
               REQUEST_STATUS are replaced by SCENARIO_TYPE, APPROVAL_STATUS (the month's
               or the budget's status) and IS_IN_PROGRESS; ACTION_COMMENT is now STEP_COMMENT.
   2026-10-19  Own file for DLSync (was in R__views_rpt.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.
   ===================================================================================== */
CREATE OR REPLACE VIEW {{ rpt() }}.V_F_APPROVAL_PROGRESS
COPY GRANTS
COMMENT = 'Every step of every approval (each payroll month, each submitted budget with PERIOD_KEY 0), its current state, and the next step to act on.'
AS
WITH item AS (   -- each approval: a payroll month, or a whole budget (period 0)
    SELECT DISTINCT a.SCENARIO_ID, a.PERIOD_KEY
    FROM {{ app() }}.T_F_APPROVAL a
),
src AS (
    SELECT i.SCENARIO_ID, i.PERIOD_KEY, s.SCENARIO_TYPE,
           IFF(s.SCENARIO_TYPE = 'ACTUAL', sp.PERIOD_STATUS, s.SCENARIO_STATUS)         AS APPROVAL_STATUS,
           IFF(s.SCENARIO_TYPE = 'ACTUAL', sp.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'),
                                           s.SCENARIO_STATUS = 'IN_APPROVAL')           AS IS_IN_PROGRESS,
           IFF(i.PERIOD_KEY = 0, s.FISCAL_YEAR * 100 + 1, i.PERIOD_KEY)                 AS STEP_PERIOD_KEY
    FROM item i
    JOIN {{ app() }}.T_D_SCENARIO s ON s.SCENARIO_ID = i.SCENARIO_ID
    LEFT JOIN {{ app() }}.T_F_SCENARIO_PERIOD sp ON sp.SCENARIO_ID = i.SCENARIO_ID AND sp.PERIOD_KEY = i.PERIOD_KEY
),
steps AS (       -- the step definitions in force for that month / budget year
    SELECT src.*, st.STEP_ORDER, st.STEP_TITLE, st.APPROVER_ROLE,
           (COALESCE(st.MANAGES_EMPLOYEE_CHECKS, FALSE) AND src.SCENARIO_TYPE = 'ACTUAL') AS MANAGES_EMPLOYEE_CHECKS
    FROM src
    JOIN {{ app() }}.T_P_APPROVAL_STEP st
      ON st.IS_ACTIVE
     AND st.APPLIES_TO IN ('ALL', src.SCENARIO_TYPE)
     AND src.STEP_PERIOD_KEY BETWEEN st.VALID_FROM_PERIOD_KEY AND COALESCE(st.VALID_TO_PERIOD_KEY, 999912)
),
state AS (       -- a step without a row in T_F_APPROVAL counts as PENDING
    SELECT s.*,
           COALESCE(a.STEP_STATUS, 'PENDING') AS STEP_STATUS,
           a.LAST_ACTION, a.ACTED_BY, a.ACTED_AT, a.STEP_COMMENT
    FROM steps s
    LEFT JOIN {{ app() }}.T_F_APPROVAL a
           ON a.SCENARIO_ID = s.SCENARIO_ID AND a.PERIOD_KEY = s.PERIOD_KEY AND a.STEP_ORDER = s.STEP_ORDER
)
SELECT
    SCENARIO_ID, PERIOD_KEY, SCENARIO_TYPE, APPROVAL_STATUS, IS_IN_PROGRESS,
    STEP_ORDER, STEP_TITLE, APPROVER_ROLE,
    STEP_STATUS, LAST_ACTION, ACTED_BY, ACTED_AT, STEP_COMMENT,
    STEP_ORDER = MIN(IFF(STEP_STATUS <> 'APPROVED', STEP_ORDER, NULL))
                 OVER (PARTITION BY SCENARIO_ID, PERIOD_KEY)                       AS IS_NEXT_STEP,
    MANAGES_EMPLOYEE_CHECKS
FROM state;
