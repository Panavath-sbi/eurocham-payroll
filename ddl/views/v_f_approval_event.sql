CREATE OR REPLACE VIEW RPT.V_F_APPROVAL_EVENT
COPY GRANTS COMMENT = 'Grain: one row per approval action (approve, reject, send back, undo, reset), read from the change log. PERIOD_KEY 0 = a whole budget.'
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
FROM APP.T_F_CHANGE_LOG c
WHERE c.TABLE_NAME = 'APP.T_F_APPROVAL';
