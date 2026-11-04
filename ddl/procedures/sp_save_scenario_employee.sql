CREATE OR REPLACE PROCEDURE APP.SP_SAVE_SCENARIO_EMPLOYEE(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_EMPLOYEES TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Edits employee terms in a budget or forecast scenario'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed     INT;
    v_type        TEXT;
    v_scen_status TEXT;
    v_rows        INT;
    v_bad         INT;
    v_pk          INT;
    v_new         TEXT;   -- JSON array: one object per employee, new terms + OLD_VALUES
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

    -- Each employee's new terms (current values overlaid with the JSON) and the old values for the log
    SELECT COUNT(*),
           TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT_KEEP_NULL(
               'EMPLOYEE_ID',            f.VALUE:employee_id::INT,
               'IN_SCENARIO',            se.EMPLOYEE_ID IS NOT NULL,
               'MONTHLY_SALARY_USD',     COALESCE(f.VALUE:monthly_salary_usd::FLOAT, se.MONTHLY_SALARY_USD),
               'RAISE_PCT',              COALESCE(f.VALUE:raise_pct::FLOAT, se.RAISE_PCT, 0),
               'REVALUATION_PERIOD_KEY', IFF(IS_NULL_VALUE(f.VALUE:revaluation_period_key), NULL,
                                             COALESCE(f.VALUE:revaluation_period_key::INT, se.REVALUATION_PERIOD_KEY)),
               'FRINGE_BENEFIT_USD',     COALESCE(f.VALUE:fringe_benefit_usd::FLOAT, se.FRINGE_BENEFIT_USD),
               'POSITION',               COALESCE(f.VALUE:position::TEXT, se.POSITION),
               'EMPLOYMENT_TYPE',        COALESCE(f.VALUE:employment_type::TEXT, se.EMPLOYMENT_TYPE),
               'CONTRACT_TYPE',          COALESCE(f.VALUE:contract_type::TEXT, se.CONTRACT_TYPE),
               'ENTITY_CODE',            COALESCE(f.VALUE:entity_code::TEXT, se.ENTITY_CODE),
               'TAX_STATUS',             COALESCE(f.VALUE:tax_status::TEXT, se.TAX_STATUS),
               'DEPENDANT_CHILDREN',     COALESCE(f.VALUE:dependant_children::INT, se.DEPENDANT_CHILDREN),
               'DEPENDANT_SPOUSE',       COALESCE(f.VALUE:dependant_spouse::INT, se.DEPENDANT_SPOUSE),
               'INSURANCE_USD',          COALESCE(f.VALUE:insurance_usd::FLOAT, se.INSURANCE_USD),
               'VISA_USD',               COALESCE(f.VALUE:visa_usd::FLOAT, se.VISA_USD),
               'WORK_PERMIT_USD',        COALESCE(f.VALUE:work_permit_usd::FLOAT, se.WORK_PERMIT_USD),
               'OLD_VALUES', OBJECT_CONSTRUCT_KEEP_NULL('MONTHLY_SALARY_USD', se.MONTHLY_SALARY_USD, 'RAISE_PCT', se.RAISE_PCT,
                   'REVALUATION_PERIOD_KEY', se.REVALUATION_PERIOD_KEY, 'FINAL_SALARY_USD', se.FINAL_SALARY_USD,
                   'FRINGE_BENEFIT_USD', se.FRINGE_BENEFIT_USD, 'ENTITY_CODE', se.ENTITY_CODE))))
      INTO :v_rows, :v_new
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_EMPLOYEES))) f
    LEFT JOIN APP.T_D_SCENARIO_EMPLOYEE se
           ON se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = f.VALUE:employee_id::INT;

    SELECT COUNT_IF(NOT t.R:IN_SCENARIO::BOOLEAN OR t.R:MONTHLY_SALARY_USD::FLOAT < 0 OR t.R:RAISE_PCT::FLOAT < -100
                    OR t.R:FRINGE_BENEFIT_USD::FLOAT < 0 OR t.R:INSURANCE_USD::FLOAT < 0 OR t.R:VISA_USD::FLOAT < 0
                    OR t.R:WORK_PERMIT_USD::FLOAT < 0 OR t.R:DEPENDANT_CHILDREN::INT < 0
                    OR t.R:DEPENDANT_SPOUSE::INT NOT IN (0, 1) OR t.R:TAX_STATUS::TEXT NOT IN ('RESIDENT', 'NON_RESIDENT')
                    OR e.ENTITY_CODE IS NULL
                    OR (t.R:REVALUATION_PERIOD_KEY::INT IS NOT NULL AND x.PERIOD_KEY IS NULL))
      INTO :v_bad
    FROM (SELECT VALUE AS R FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))) t
    LEFT JOIN APP.T_D_ENTITY e ON e.ENTITY_CODE = t.R:ENTITY_CODE::TEXT AND e.IS_ACTIVE
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = :P_SCENARIO_ID AND x.PERIOD_KEY = t.R:REVALUATION_PERIOD_KEY::INT;
    IF (v_rows = 0 OR v_bad > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Invalid rows: employees must be in the scenario, amounts >= 0, raise >= -100%, a known chamber and a revaluation month inside the scenario.');
    END IF;

    BEGIN TRANSACTION;

    UPDATE APP.T_D_SCENARIO_EMPLOYEE se
    SET MONTHLY_SALARY_USD = t.R:MONTHLY_SALARY_USD::FLOAT, RAISE_PCT = t.R:RAISE_PCT::FLOAT,
        REVALUATION_PERIOD_KEY = t.R:REVALUATION_PERIOD_KEY::INT,
        FINAL_SALARY_USD = ROUND(t.R:MONTHLY_SALARY_USD::FLOAT * (1 + t.R:RAISE_PCT::FLOAT / 100), 2),
        FRINGE_BENEFIT_USD = t.R:FRINGE_BENEFIT_USD::FLOAT, POSITION = t.R:POSITION::TEXT,
        EMPLOYMENT_TYPE = t.R:EMPLOYMENT_TYPE::TEXT, CONTRACT_TYPE = t.R:CONTRACT_TYPE::TEXT,
        ENTITY_CODE = t.R:ENTITY_CODE::TEXT, TAX_STATUS = t.R:TAX_STATUS::TEXT,
        DEPENDANT_CHILDREN = t.R:DEPENDANT_CHILDREN::INT, DEPENDANT_SPOUSE = t.R:DEPENDANT_SPOUSE::INT,
        INSURANCE_USD = t.R:INSURANCE_USD::FLOAT, VISA_USD = t.R:VISA_USD::FLOAT, WORK_PERMIT_USD = t.R:WORK_PERMIT_USD::FLOAT,
        UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM (SELECT VALUE AS R FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))) t
    WHERE se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = t.R:EMPLOYEE_ID::INT;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_SCENARIO_EMPLOYEE', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'EMPLOYEE_ID', se.EMPLOYEE_ID), 'UPDATE',
           t.R:OLD_VALUES,
           OBJECT_CONSTRUCT_KEEP_NULL('MONTHLY_SALARY_USD', se.MONTHLY_SALARY_USD, 'RAISE_PCT', se.RAISE_PCT,
                'REVALUATION_PERIOD_KEY', se.REVALUATION_PERIOD_KEY, 'FINAL_SALARY_USD', se.FINAL_SALARY_USD,
                'FRINGE_BENEFIT_USD', se.FRINGE_BENEFIT_USD, 'ENTITY_CODE', se.ENTITY_CODE),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM (SELECT VALUE AS R FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))) t
    JOIN APP.T_D_SCENARIO_EMPLOYEE se ON se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = t.R:EMPLOYEE_ID::INT;

    LET rs_calc RESULTSET := (
        SELECT PERIOD_KEY FROM APP.T_F_SCENARIO_PERIOD
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_STATUS NOT IN ('FINALIZED', 'LOCKED')
        ORDER BY PERIOD_KEY);
    LET cur_calc CURSOR FOR rs_calc;
    FOR rec IN cur_calc DO
        v_pk := rec.PERIOD_KEY;
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :v_pk);
    END FOR;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_rows || ' employee(s) updated and the scenario recalculated.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
