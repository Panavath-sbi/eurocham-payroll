CREATE OR REPLACE PROCEDURE APP.SP_SAVE_EMPLOYEE_CONTRACT(P_USER_EMAIL TEXT, P_EMPLOYEE_ID INT, P_EFFECTIVE_PERIOD_KEY INT, P_CONTRACT TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Adds or corrects an employee contract version'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed    INT;
    v_exists     INT;
    v_planned    BOOLEAN;
    v_actual     INT;
    v_open       INT;
    v_last_final INT;
    v_eff        INT;
    v_prev       INT;
    v_cur_id     INT;
    v_cur_from   INT;
    v_cur_to     INT;
    v_ids        TEXT;
    v_entity_ok  INT;
    v_old        TEXT;
    v_new        TEXT;
    -- The new terms
    v_position   TEXT;
    v_emp_type   TEXT;
    v_contract   TEXT;
    v_entity     TEXT;
    v_salary     FLOAT;
    v_tax        TEXT;
    v_children   INT;
    v_spouse     INT;
    v_insurance  FLOAT;
    v_visa       FLOAT;
    v_permit     FLOAT;
    v_fringe     FLOAT;
    v_reason     TEXT;
    v_nr_from    DATE;
    v_nr_to      DATE;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT COUNT(*), MAX(IS_PLANNED) INTO :v_exists, :v_planned FROM APP.T_D_EMPLOYEE WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID;
    IF (v_exists = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || P_EMPLOYEE_ID || ' does not exist.');
    END IF;
    IF (v_planned) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Planned hires are edited on the Budget / Forecast pages.');
    END IF;

    SELECT MAX(s.SCENARIO_ID), MAX(IFF(x.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'), x.PERIOD_KEY, NULL)),
           MAX(IFF(x.PERIOD_STATUS = 'FINALIZED', x.PERIOD_KEY, NULL))
      INTO :v_actual, :v_open, :v_last_final
    FROM APP.T_D_SCENARIO s
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID
    WHERE s.SCENARIO_TYPE = 'ACTUAL';

    v_eff := COALESCE(P_EFFECTIVE_PERIOD_KEY, v_open);
    IF (v_eff IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No payroll month is open; give the effective month.');
    END IF;
    IF (v_eff <= COALESCE(v_last_final, 0)) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || v_eff || ' is finalized. Pay changes must start after ' || v_last_final || '.');
    END IF;

    SELECT MAX(TO_NUMBER(TO_CHAR(DATEADD(MONTH, -1, PERIOD_START_DATE), 'YYYYMM'))) INTO :v_prev
    FROM APP.T_D_PERIOD WHERE PERIOD_KEY = :v_eff;
    IF (v_prev IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || v_eff || ' is not in the calendar.');
    END IF;

    SELECT MAX(CONTRACT_ID), MAX(VALID_FROM_PERIOD_KEY), MAX(VALID_TO_PERIOD_KEY) INTO :v_cur_id, :v_cur_from, :v_cur_to
    FROM APP.T_D_EMPLOYEE_CONTRACT
    WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID
      AND :v_eff BETWEEN VALID_FROM_PERIOD_KEY AND COALESCE(VALID_TO_PERIOD_KEY, 999912);
    IF (v_cur_id IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The employee has no contract in force in ' || v_eff || '. Create one with SP_SAVE_EMPLOYEE.');
    END IF;

    -- New terms = current version overlaid with the JSON
    SELECT
        COALESCE(x.D:position::TEXT,           c.POSITION),
        COALESCE(x.D:employment_type::TEXT,    c.EMPLOYMENT_TYPE),
        COALESCE(x.D:contract_type::TEXT,      c.CONTRACT_TYPE),
        COALESCE(x.D:entity_code::TEXT,        c.ENTITY_CODE),
        COALESCE(x.D:monthly_salary_usd::FLOAT, c.MONTHLY_SALARY_USD),
        COALESCE(x.D:tax_status::TEXT,         c.TAX_STATUS),
        COALESCE(x.D:dependant_children::INT,  c.DEPENDANT_CHILDREN),
        COALESCE(x.D:dependant_spouse::INT,    c.DEPENDANT_SPOUSE),
        COALESCE(x.D:insurance_usd::FLOAT,     c.INSURANCE_USD),
        COALESCE(x.D:visa_usd::FLOAT,          c.VISA_USD),
        COALESCE(x.D:work_permit_usd::FLOAT,   c.WORK_PERMIT_USD),
        COALESCE(x.D:fringe_benefit_usd::FLOAT, c.FRINGE_BENEFIT_USD),
        COALESCE(x.D:change_reason::TEXT, 'Contract change'),
        IFF(COALESCE(x.D:tax_status::TEXT, c.TAX_STATUS) = 'RESIDENT', NULL,
            IFF(IS_NULL_VALUE(x.D:non_resident_from), NULL,
                COALESCE(x.D:non_resident_from::DATE, c.NON_RESIDENT_FROM))),
        IFF(COALESCE(x.D:tax_status::TEXT, c.TAX_STATUS) = 'RESIDENT', NULL,
            IFF(IS_NULL_VALUE(x.D:non_resident_to), NULL,
                COALESCE(x.D:non_resident_to::DATE, c.NON_RESIDENT_TO)))
      INTO :v_position, :v_emp_type, :v_contract, :v_entity, :v_salary, :v_tax, :v_children, :v_spouse,
           :v_insurance, :v_visa, :v_permit, :v_fringe, :v_reason, :v_nr_from, :v_nr_to
    FROM APP.T_D_EMPLOYEE_CONTRACT c, (SELECT PARSE_JSON(:P_CONTRACT) AS D) x
    WHERE c.CONTRACT_ID = :v_cur_id;

    SELECT COUNT(*) INTO :v_entity_ok FROM APP.T_D_ENTITY WHERE ENTITY_CODE = :v_entity AND IS_ACTIVE;
    IF (v_salary < 0 OR v_insurance < 0 OR v_visa < 0 OR v_permit < 0 OR v_fringe < 0 OR v_children < 0
        OR (v_spouse <> 0 AND v_spouse <> 1) OR (v_tax <> 'RESIDENT' AND v_tax <> 'NON_RESIDENT')
        OR v_entity_ok = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Invalid values: amounts must be >= 0, spouse 0 or 1, tax status RESIDENT / NON_RESIDENT, and the chamber must exist.');
    END IF;

    BEGIN TRANSACTION;

    SELECT TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL(*)) INTO :v_old FROM APP.T_D_EMPLOYEE_CONTRACT WHERE CONTRACT_ID = :v_cur_id;

    IF (v_cur_from = v_eff) THEN
        -- Same starting month: correct the version in place
        UPDATE APP.T_D_EMPLOYEE_CONTRACT
        SET POSITION = :v_position, EMPLOYMENT_TYPE = :v_emp_type, CONTRACT_TYPE = :v_contract,
            ENTITY_CODE = :v_entity, MONTHLY_SALARY_USD = :v_salary, TAX_STATUS = :v_tax,
            DEPENDANT_CHILDREN = :v_children, DEPENDANT_SPOUSE = :v_spouse,
            INSURANCE_USD = :v_insurance, VISA_USD = :v_visa, WORK_PERMIT_USD = :v_permit,
            FRINGE_BENEFIT_USD = :v_fringe, CHANGE_REASON = :v_reason,
            NON_RESIDENT_FROM = :v_nr_from, NON_RESIDENT_TO = :v_nr_to,
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE CONTRACT_ID = :v_cur_id;
    ELSE
        -- Close the version in force the month before, add the new version
        UPDATE APP.T_D_EMPLOYEE_CONTRACT
        SET VALID_TO_PERIOD_KEY = :v_prev, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE CONTRACT_ID = :v_cur_id;

        INSERT INTO APP.T_D_EMPLOYEE_CONTRACT
            (EMPLOYEE_ID, VALID_FROM_PERIOD_KEY, VALID_TO_PERIOD_KEY, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
             MONTHLY_SALARY_USD, TAX_STATUS, DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD,
             WORK_PERMIT_USD, FRINGE_BENEFIT_USD, CHANGE_REASON, NON_RESIDENT_FROM, NON_RESIDENT_TO, INSERT_BY, UPDATE_BY)
        SELECT :P_EMPLOYEE_ID, :v_eff, :v_cur_to, :v_position, :v_emp_type, :v_contract, :v_entity,
               :v_salary, :v_tax, :v_children, :v_spouse, :v_insurance, :v_visa,
               :v_permit, :v_fringe, :v_reason, :v_nr_from, :v_nr_to, :P_USER_EMAIL, :P_USER_EMAIL;
    END IF;

    SELECT TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL(*)) INTO :v_new
    FROM APP.T_D_EMPLOYEE_CONTRACT
    WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID
      AND :v_eff BETWEEN VALID_FROM_PERIOD_KEY AND COALESCE(VALID_TO_PERIOD_KEY, 999912);
    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_EMPLOYEE_CONTRACT', OBJECT_CONSTRUCT('EMPLOYEE_ID', :P_EMPLOYEE_ID, 'EFFECTIVE_PERIOD_KEY', :v_eff), 'UPDATE', PARSE_JSON(:v_old), PARSE_JSON(:v_new), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_open IS NOT NULL AND v_open >= v_eff) THEN
        v_ids := '[' || P_EMPLOYEE_ID || ']';
        CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_actual, :v_open, :v_ids, 'Contract changed');
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :v_actual, :v_open);
    END IF;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Contract saved from ' || v_eff || '.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
