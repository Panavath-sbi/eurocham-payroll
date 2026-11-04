CREATE OR REPLACE PROCEDURE APP.SP_SAVE_PLANNED_HIRE(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_HIRE TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Adds or edits a planned hire'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed     INT;
    v_type        TEXT;
    v_scen_status TEXT;
    v_emp         INT;
    v_found       INT;
    v_code        TEXT;
    v_first       INT;
    v_start       INT;
    v_end         INT;
    v_entity_ok   INT;
    v_pk          INT;
    -- The hire's terms
    v_first_name  TEXT;
    v_last_name   TEXT;
    v_position    TEXT;
    v_emp_type    TEXT;
    v_contract    TEXT;
    v_entity      TEXT;
    v_salary      FLOAT;
    v_raise       FLOAT;
    v_reval       INT;
    v_tax         TEXT;
    v_children    INT;
    v_spouse      INT;
    v_insurance   FLOAT;
    v_visa        FLOAT;
    v_permit      FLOAT;
    v_fringe      FLOAT;
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

    SELECT D:employee_id::INT INTO :v_emp FROM (SELECT PARSE_JSON(:P_HIRE) AS D);
    SELECT MIN(PERIOD_KEY) INTO :v_first FROM APP.T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :P_SCENARIO_ID;

    IF (v_emp IS NOT NULL) THEN
        SELECT COUNT(*) INTO :v_found FROM APP.T_D_EMPLOYEE
        WHERE EMPLOYEE_ID = :v_emp AND IS_PLANNED AND PLANNED_SCENARIO_ID = :P_SCENARIO_ID;
        IF (v_found = 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || v_emp || ' is not a planned hire of this scenario.');
        END IF;
        SELECT MIN(IFF(i.INCLUDE_IN_PAYROLL, x.PERIOD_KEY, NULL)), MAX(IFF(i.INCLUDE_IN_PAYROLL, x.PERIOD_KEY, NULL))
          INTO :v_start, :v_end
        FROM APP.T_F_SCENARIO_PERIOD x
        LEFT JOIN APP.T_F_PAYROLL_INPUT i ON i.SCENARIO_ID = x.SCENARIO_ID AND i.PERIOD_KEY = x.PERIOD_KEY AND i.EMPLOYEE_ID = :v_emp
        WHERE x.SCENARIO_ID = :P_SCENARIO_ID;
    END IF;

    SELECT COALESCE(D:start_period_key::INT, :v_start, :v_first),
           IFF(IS_NULL_VALUE(D:end_period_key), NULL, COALESCE(D:end_period_key::INT, :v_end))
      INTO :v_start, :v_end
    FROM (SELECT PARSE_JSON(:P_HIRE) AS D);

    -- The hire's terms (existing values overlaid with the JSON)
    SELECT
        COALESCE(x.D:first_name::TEXT, e.FIRST_NAME, 'New'),
        COALESCE(x.D:last_name::TEXT, e.LAST_NAME, 'Hire'),
        COALESCE(x.D:position::TEXT, se.POSITION),
        COALESCE(x.D:employment_type::TEXT, se.EMPLOYMENT_TYPE, 'FULL_TIME'),
        COALESCE(x.D:contract_type::TEXT, se.CONTRACT_TYPE),
        COALESCE(x.D:entity_code::TEXT, se.ENTITY_CODE),
        COALESCE(x.D:monthly_salary_usd::FLOAT, se.MONTHLY_SALARY_USD),
        COALESCE(x.D:raise_pct::FLOAT, se.RAISE_PCT, 0),
        IFF(IS_NULL_VALUE(x.D:revaluation_period_key), NULL,
            COALESCE(x.D:revaluation_period_key::INT, se.REVALUATION_PERIOD_KEY)),
        COALESCE(x.D:tax_status::TEXT, se.TAX_STATUS, 'RESIDENT'),
        COALESCE(x.D:dependant_children::INT, se.DEPENDANT_CHILDREN, 0),
        COALESCE(x.D:dependant_spouse::INT, se.DEPENDANT_SPOUSE, 0),
        COALESCE(x.D:insurance_usd::FLOAT, se.INSURANCE_USD, 0),
        COALESCE(x.D:visa_usd::FLOAT, se.VISA_USD, 0),
        COALESCE(x.D:work_permit_usd::FLOAT, se.WORK_PERMIT_USD, 0),
        COALESCE(x.D:fringe_benefit_usd::FLOAT, se.FRINGE_BENEFIT_USD, 0)
      INTO :v_first_name, :v_last_name, :v_position, :v_emp_type, :v_contract, :v_entity,
           :v_salary, :v_raise, :v_reval, :v_tax, :v_children, :v_spouse,
           :v_insurance, :v_visa, :v_permit, :v_fringe
    FROM (SELECT PARSE_JSON(:P_HIRE) AS D) x
    LEFT JOIN APP.T_D_EMPLOYEE e ON e.EMPLOYEE_ID = :v_emp
    LEFT JOIN APP.T_D_SCENARIO_EMPLOYEE se ON se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = :v_emp;

    SELECT COUNT(*) INTO :v_entity_ok FROM APP.T_D_ENTITY WHERE ENTITY_CODE = :v_entity AND IS_ACTIVE;
    IF (v_salary IS NULL OR v_salary < 0 OR v_entity_ok = 0 OR v_raise < -100
        OR (v_spouse <> 0 AND v_spouse <> 1) OR v_children < 0
        OR (v_tax <> 'RESIDENT' AND v_tax <> 'NON_RESIDENT')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A planned hire needs a known chamber (entity_code), a salary >= 0 and valid tax details.');
    END IF;
    IF (v_end IS NOT NULL AND v_end < v_start) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The end month is before the start month.');
    END IF;

    BEGIN TRANSACTION;

    IF (v_emp IS NULL) THEN
        v_code := 'PLAN-' || P_SCENARIO_ID || '-' || UPPER(LEFT(REPLACE(UUID_STRING(), '-', ''), 8));
        INSERT INTO APP.T_D_EMPLOYEE (RESOURCE_CODE, FIRST_NAME, LAST_NAME, IS_ACTIVE, IS_PLANNED, PLANNED_SCENARIO_ID, INSERT_BY, UPDATE_BY)
        SELECT :v_code, :v_first_name, :v_last_name, TRUE, TRUE, :P_SCENARIO_ID, :P_USER_EMAIL, :P_USER_EMAIL;
        SELECT MAX(EMPLOYEE_ID) INTO :v_emp FROM APP.T_D_EMPLOYEE WHERE RESOURCE_CODE = :v_code;

        INSERT INTO APP.T_D_SCENARIO_EMPLOYEE
            (SCENARIO_ID, EMPLOYEE_ID, SOURCE_CONTRACT_ID, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
             MONTHLY_SALARY_USD, RAISE_PCT, REVALUATION_PERIOD_KEY, FINAL_SALARY_USD, TAX_STATUS,
             DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD, WORK_PERMIT_USD, FRINGE_BENEFIT_USD, INSERT_BY, UPDATE_BY)
        SELECT :P_SCENARIO_ID, :v_emp, NULL, :v_position, :v_emp_type, :v_contract, :v_entity,
               :v_salary, :v_raise, :v_reval, ROUND(:v_salary * (1 + :v_raise / 100), 2),
               :v_tax, :v_children, :v_spouse, :v_insurance, :v_visa, :v_permit, :v_fringe,
               :P_USER_EMAIL, :P_USER_EMAIL;
    ELSE
        UPDATE APP.T_D_EMPLOYEE
        SET FIRST_NAME = :v_first_name, LAST_NAME = :v_last_name, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE EMPLOYEE_ID = :v_emp;

        UPDATE APP.T_D_SCENARIO_EMPLOYEE
        SET POSITION = :v_position, EMPLOYMENT_TYPE = :v_emp_type, CONTRACT_TYPE = :v_contract,
            ENTITY_CODE = :v_entity, MONTHLY_SALARY_USD = :v_salary, RAISE_PCT = :v_raise,
            REVALUATION_PERIOD_KEY = :v_reval,
            FINAL_SALARY_USD = ROUND(:v_salary * (1 + :v_raise / 100), 2),
            TAX_STATUS = :v_tax, DEPENDANT_CHILDREN = :v_children, DEPENDANT_SPOUSE = :v_spouse,
            INSURANCE_USD = :v_insurance, VISA_USD = :v_visa, WORK_PERMIT_USD = :v_permit,
            FRINGE_BENEFIT_USD = :v_fringe, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND EMPLOYEE_ID = :v_emp;
    END IF;

    -- Paid only between the start and end months
    MERGE INTO APP.T_F_PAYROLL_INPUT t
    USING (SELECT PERIOD_KEY, (PERIOD_KEY >= :v_start AND PERIOD_KEY <= COALESCE(:v_end, 999912)) AS INCLUDED
           FROM APP.T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :P_SCENARIO_ID) s
       ON t.SCENARIO_ID = :P_SCENARIO_ID AND t.PERIOD_KEY = s.PERIOD_KEY AND t.EMPLOYEE_ID = :v_emp
    WHEN MATCHED THEN UPDATE SET INCLUDE_IN_PAYROLL = s.INCLUDED, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHEN NOT MATCHED THEN INSERT (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, INCLUDE_IN_PAYROLL, INSERT_BY, UPDATE_BY)
        VALUES (:P_SCENARIO_ID, s.PERIOD_KEY, :v_emp, s.INCLUDED, :P_USER_EMAIL, :P_USER_EMAIL);

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_SCENARIO_EMPLOYEE', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'EMPLOYEE_ID', :v_emp), 'UPDATE', NULL, PARSE_JSON(:P_HIRE), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

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
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Planned hire saved.', 'employee_id', v_emp);
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
