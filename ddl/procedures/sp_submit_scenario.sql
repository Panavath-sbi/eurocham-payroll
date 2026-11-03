CREATE OR REPLACE PROCEDURE APP.SP_SUBMIT_SCENARIO(P_USER_EMAIL TEXT, P_SCENARIO_ID INT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Submits a budget scenario for approval'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed     INT;
    v_type        TEXT;
    v_scen_status TEXT;
    v_emps        INT;
    v_pk          INT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;
    SELECT MAX(SCENARIO_TYPE), MAX(SCENARIO_STATUS) INTO :v_type, :v_scen_status
    FROM APP.T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL OR v_type = 'ACTUAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' is not a budget or forecast.');
    END IF;
    IF (v_scen_status <> 'DRAFT' AND v_scen_status <> 'REJECTED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This scenario is ' || v_scen_status || ' and cannot be edited.');
    END IF;

    IF (v_type <> 'BUDGET') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only budget scenarios go through approval.');
    END IF;
    SELECT COUNT(*) INTO :v_emps FROM APP.T_D_SCENARIO_EMPLOYEE WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_emps = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The scenario has no employees.');
    END IF;

    BEGIN TRANSACTION;

    LET rs_calc RESULTSET := (
        SELECT PERIOD_KEY FROM APP.T_F_SCENARIO_PERIOD
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_STATUS NOT IN ('FINALIZED', 'LOCKED')
        ORDER BY PERIOD_KEY);
    LET cur_calc CURSOR FOR rs_calc;
    FOR rec IN cur_calc DO
        v_pk := rec.PERIOD_KEY;
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :v_pk);
    END FOR;

    -- The approval starts over: one PENDING row per approval step in force for the budget year
    DELETE FROM APP.T_F_APPROVAL WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = 0;

    INSERT INTO APP.T_F_APPROVAL (SCENARIO_ID, PERIOD_KEY, STEP_ORDER, STEP_STATUS, INSERT_BY, UPDATE_BY)
    SELECT DISTINCT sc.SCENARIO_ID, 0, st.STEP_ORDER, 'PENDING', :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.T_D_SCENARIO sc
    JOIN APP.T_P_APPROVAL_STEP st
      ON st.IS_ACTIVE
     AND st.APPLIES_TO IN ('ALL', sc.SCENARIO_TYPE)
     AND sc.FISCAL_YEAR * 100 + 1 BETWEEN st.VALID_FROM_PERIOD_KEY AND COALESCE(st.VALID_TO_PERIOD_KEY, 999912)
    WHERE sc.SCENARIO_ID = :P_SCENARIO_ID;

    UPDATE APP.T_D_SCENARIO
    SET SCENARIO_STATUS = 'IN_APPROVAL', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHERE SCENARIO_ID = :P_SCENARIO_ID;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_SCENARIO', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID), 'UPDATE', OBJECT_CONSTRUCT('SCENARIO_STATUS', :v_scen_status), OBJECT_CONSTRUCT('SCENARIO_STATUS', 'IN_APPROVAL'), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Scenario submitted for approval.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
