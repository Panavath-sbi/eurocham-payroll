-- depends_on: T_F_CHANGE_LOG
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_F_APPROVAL_EVENT - Grain: one row per approval action (approve, reject, send back, undo, reset), read from the change log
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-02  V_F_APPROVAL_EVENT reads the approval history from APP.T_F_CHANGE_LOG
               (APP.T_F_APPROVAL_ACTION was dropped in V1.4.0).
   2026-10-02  V1.5.0: the views move from CORE to RPT (CORE is removed; tables are in APP).
               New V_F_COST_ALLOCATION replaces the dropped T_F_COST_ALLOCATION table.
               V_F_APPROVAL_EVENT reads the change-log rows of APP.T_F_APPROVAL (by
               scenario + period; actions logged before V1.5.0 used a request id and are
               no longer listed).
   2026-10-19  Own file for DLSync (was in R__views_core.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.
   ===================================================================================== */
CREATE OR REPLACE VIEW {{ schema_rpt }}.V_F_APPROVAL_EVENT
COPY GRANTS
COMMENT = 'Grain: one row per approval action (approve, reject, send back, undo, reset), read from the change log. PERIOD_KEY 0 = a whole budget.'
AS
SELECT
    c.CHANGE_ID                       AS ACTION_ID,
    c.RECORD_KEY:SCENARIO_ID::INT     AS SCENARIO_ID,
    c.RECORD_KEY:PERIOD_KEY::INT      AS PERIOD_KEY,
    c.RECORD_KEY:STEP_ORDER::INT      AS STEP_ORDER,
    c.NEW_VALUES:ACTION_TYPE::TEXT    AS ACTION_TYPE,
    c.CHANGED_BY                      AS ACTED_BY,
    c.INSERT_DATE                     AS ACTED_AT,
    c.NEW_VALUES:COMMENT::TEXT        AS ACTION_COMMENT
FROM {{ schema_app }}.T_F_CHANGE_LOG c
WHERE c.TABLE_NAME = 'APP.T_F_APPROVAL';
