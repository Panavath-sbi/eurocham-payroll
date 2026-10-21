-- depends_on: {{ ref('t_d_app_user') }}, {{ ref('t_d_scenario') }}, {{ ref('t_f_scenario_period') }}, {{ ref('t_d_employee') }}, {{ ref('t_f_payroll_input') }}, {{ ref('t_d_scenario_employee') }}, {{ ref('t_d_entity') }}, {{ ref('t_f_change_log') }}, {{ ref('sp_calc_period') }}
/* =====================================================================================
   SP_SAVE_PLANNED_HIRE
   Adds or edits a planned hire in a budget or forecast scenario.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  V1.5.0: CORE tables moved to APP; role check reads T_D_APP_USER.ROLE_CODE (one role per user).
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Budget Input and Forecast pages: "Add New Hire" and editing a new hire.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   P_HIRE: JSON object. New hire (no employee_id): entity_code and monthly_salary_usd are
   required; first_name / last_name default to 'New' / 'Hire'. Optional: position,
   employment_type, contract_type, raise_pct, revaluation_period_key, tax_status,
   dependant_children, dependant_spouse, insurance_usd, visa_usd, work_permit_usd,
   fringe_benefit_usd, start_period_key (default: first scenario month), end_period_key.
   Existing hire (employee_id given): keys left out keep their value.
   The hire is paid only in months between start and end (INCLUDE_IN_PAYROLL).
   A planned hire exists only in its own scenario. Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE SP_SAVE_PLANNED_HIRE(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_HIRE TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Adds or edits a planned hire'
EXECUTE AS OWNER
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
    v_bad         INT;
    v_pk          INT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;
    SELECT MAX(SCENARIO_TYPE), MAX(SCENARIO_STATUS) INTO :v_type, :v_scen_status
    FROM T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL OR v_type = 'ACTUAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' is not a budget or forecast.');
    END IF;
    IF (v_scen_status <> 'DRAFT' AND v_scen_status <> 'REJECTED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This scenario is ' || v_scen_status || ' and cannot be edited.');
    END IF;

    SELECT D:employee_id::INT INTO :v_emp FROM (SELECT PARSE_JSON(:P_HIRE) AS D);
    SELECT MIN(PERIOD_KEY) INTO :v_first FROM T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :P_SCENARIO_ID;

    IF (v_emp IS NOT NULL) THEN
        SELECT COUNT(*) INTO :v_found FROM T_D_EMPLOYEE
        WHERE EMPLOYEE_ID = :v_emp AND IS_PLANNED AND PLANNED_SCENARIO_ID = :P_SCENARIO_ID;
        IF (v_found = 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || v_emp || ' is not a planned hire of this scenario.');
        END IF;
        SELECT MIN(IFF(i.INCLUDE_IN_PAYROLL, x.PERIOD_KEY, NULL)), MAX(IFF(i.INCLUDE_IN_PAYROLL, x.PERIOD_KEY, NULL))
          INTO :v_start, :v_end
        FROM T_F_SCENARIO_PERIOD x
        LEFT JOIN T_F_PAYROLL_INPUT i ON i.SCENARIO_ID = x.SCENARIO_ID AND i.PERIOD_KEY = x.PERIOD_KEY AND i.EMPLOYEE_ID = :v_emp
        WHERE x.SCENARIO_ID = :P_SCENARIO_ID;
    END IF;

    SELECT COALESCE(D:start_period_key::INT, :v_start, :v_first),
           IFF(IS_NULL_VALUE(D:end_period_key), NULL, COALESCE(D:end_period_key::INT, :v_end))
      INTO :v_start, :v_end
    FROM (SELECT PARSE_JSON(:P_HIRE) AS D);

    -- The hire's terms (existing values overlaid with the JSON)
    CREATE OR REPLACE TEMPORARY TABLE TMP_HIRE AS
    SELECT
        COALESCE(x.D:first_name::TEXT, e.FIRST_NAME, 'New')                 AS FIRST_NAME,
        COALESCE(x.D:last_name::TEXT, e.LAST_NAME, 'Hire')                  AS LAST_NAME,
        COALESCE(x.D:position::TEXT, se.POSITION)                           AS POSITION,
        COALESCE(x.D:employment_type::TEXT, se.EMPLOYMENT_TYPE, 'FULL_TIME') AS EMPLOYMENT_TYPE,
        COALESCE(x.D:contract_type::TEXT, se.CONTRACT_TYPE)                 AS CONTRACT_TYPE,
        COALESCE(x.D:entity_code::TEXT, se.ENTITY_CODE)                     AS ENTITY_CODE,
        COALESCE(x.D:monthly_salary_usd::FLOAT, se.MONTHLY_SALARY_USD)      AS MONTHLY_SALARY_USD,
        COALESCE(x.D:raise_pct::FLOAT, se.RAISE_PCT, 0)                     AS RAISE_PCT,
        IFF(IS_NULL_VALUE(x.D:revaluation_period_key), NULL,
            COALESCE(x.D:revaluation_period_key::INT, se.REVALUATION_PERIOD_KEY)) AS REVALUATION_PERIOD_KEY,
        COALESCE(x.D:tax_status::TEXT, se.TAX_STATUS, 'RESIDENT')           AS TAX_STATUS,
        COALESCE(x.D:dependant_children::INT, se.DEPENDANT_CHILDREN, 0)     AS DEPENDANT_CHILDREN,
        COALESCE(x.D:dependant_spouse::INT, se.DEPENDANT_SPOUSE, 0)         AS DEPENDANT_SPOUSE,
        COALESCE(x.D:insurance_usd::FLOAT, se.INSURANCE_USD, 0)             AS INSURANCE_USD,
        COALESCE(x.D:visa_usd::FLOAT, se.VISA_USD, 0)                       AS VISA_USD,
        COALESCE(x.D:work_permit_usd::FLOAT, se.WORK_PERMIT_USD, 0)         AS WORK_PERMIT_USD,
        COALESCE(x.D:fringe_benefit_usd::FLOAT, se.FRINGE_BENEFIT_USD, 0)   AS FRINGE_BENEFIT_USD
    FROM (SELECT PARSE_JSON(:P_HIRE) AS D) x
    LEFT JOIN T_D_EMPLOYEE e ON e.EMPLOYEE_ID = :v_emp
    LEFT JOIN T_D_SCENARIO_EMPLOYEE se ON se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = :v_emp;

    SELECT COUNT_IF(t.MONTHLY_SALARY_USD IS NULL OR t.MONTHLY_SALARY_USD < 0 OR e.ENTITY_CODE IS NULL
                    OR t.RAISE_PCT < -100 OR t.DEPENDANT_SPOUSE NOT IN (0, 1) OR t.DEPENDANT_CHILDREN < 0
                    OR t.TAX_STATUS NOT IN ('RESIDENT', 'NON_RESIDENT'))
      INTO :v_bad
    FROM TMP_HIRE t
    LEFT JOIN T_D_ENTITY e ON e.ENTITY_CODE = t.ENTITY_CODE AND e.IS_ACTIVE;
    IF (v_bad > 0) THEN
        DROP TABLE IF EXISTS TMP_HIRE;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A planned hire needs a known chamber (entity_code), a salary >= 0 and valid tax details.');
    END IF;
    IF (v_end IS NOT NULL AND v_end < v_start) THEN
        DROP TABLE IF EXISTS TMP_HIRE;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The end month is before the start month.');
    END IF;

    BEGIN TRANSACTION;

    IF (v_emp IS NULL) THEN
        v_code := 'PLAN-' || P_SCENARIO_ID || '-' || UPPER(LEFT(REPLACE(UUID_STRING(), '-', ''), 8));
        INSERT INTO T_D_EMPLOYEE (RESOURCE_CODE, FIRST_NAME, LAST_NAME, IS_ACTIVE, IS_PLANNED, PLANNED_SCENARIO_ID, INSERT_BY, UPDATE_BY)
        SELECT :v_code, FIRST_NAME, LAST_NAME, TRUE, TRUE, :P_SCENARIO_ID, :P_USER_EMAIL, :P_USER_EMAIL FROM TMP_HIRE;
        SELECT MAX(EMPLOYEE_ID) INTO :v_emp FROM T_D_EMPLOYEE WHERE RESOURCE_CODE = :v_code;

        INSERT INTO T_D_SCENARIO_EMPLOYEE
            (SCENARIO_ID, EMPLOYEE_ID, SOURCE_CONTRACT_ID, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
             MONTHLY_SALARY_USD, RAISE_PCT, REVALUATION_PERIOD_KEY, FINAL_SALARY_USD, TAX_STATUS,
             DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD, WORK_PERMIT_USD, FRINGE_BENEFIT_USD, INSERT_BY, UPDATE_BY)
        SELECT :P_SCENARIO_ID, :v_emp, NULL, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
               MONTHLY_SALARY_USD, RAISE_PCT, REVALUATION_PERIOD_KEY, ROUND(MONTHLY_SALARY_USD * (1 + RAISE_PCT / 100), 2),
               TAX_STATUS, DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD, WORK_PERMIT_USD, FRINGE_BENEFIT_USD,
               :P_USER_EMAIL, :P_USER_EMAIL
        FROM TMP_HIRE;
    ELSE
        UPDATE T_D_EMPLOYEE e
        SET FIRST_NAME = t.FIRST_NAME, LAST_NAME = t.LAST_NAME, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        FROM TMP_HIRE t WHERE e.EMPLOYEE_ID = :v_emp;

        UPDATE T_D_SCENARIO_EMPLOYEE se
        SET POSITION = t.POSITION, EMPLOYMENT_TYPE = t.EMPLOYMENT_TYPE, CONTRACT_TYPE = t.CONTRACT_TYPE,
            ENTITY_CODE = t.ENTITY_CODE, MONTHLY_SALARY_USD = t.MONTHLY_SALARY_USD, RAISE_PCT = t.RAISE_PCT,
            REVALUATION_PERIOD_KEY = t.REVALUATION_PERIOD_KEY,
            FINAL_SALARY_USD = ROUND(t.MONTHLY_SALARY_USD * (1 + t.RAISE_PCT / 100), 2),
            TAX_STATUS = t.TAX_STATUS, DEPENDANT_CHILDREN = t.DEPENDANT_CHILDREN, DEPENDANT_SPOUSE = t.DEPENDANT_SPOUSE,
            INSURANCE_USD = t.INSURANCE_USD, VISA_USD = t.VISA_USD, WORK_PERMIT_USD = t.WORK_PERMIT_USD,
            FRINGE_BENEFIT_USD = t.FRINGE_BENEFIT_USD, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        FROM TMP_HIRE t
        WHERE se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = :v_emp;
    END IF;

    -- Paid only between the start and end months
    MERGE INTO T_F_PAYROLL_INPUT t
    USING (SELECT PERIOD_KEY, (PERIOD_KEY >= :v_start AND PERIOD_KEY <= COALESCE(:v_end, 999912)) AS INCLUDED
           FROM T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :P_SCENARIO_ID) s
       ON t.SCENARIO_ID = :P_SCENARIO_ID AND t.PERIOD_KEY = s.PERIOD_KEY AND t.EMPLOYEE_ID = :v_emp
    WHEN MATCHED THEN UPDATE SET INCLUDE_IN_PAYROLL = s.INCLUDED, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHEN NOT MATCHED THEN INSERT (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, INCLUDE_IN_PAYROLL, INSERT_BY, UPDATE_BY)
        VALUES (:P_SCENARIO_ID, s.PERIOD_KEY, :v_emp, s.INCLUDED, :P_USER_EMAIL, :P_USER_EMAIL);

    INSERT INTO T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_SCENARIO_EMPLOYEE', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'EMPLOYEE_ID', :v_emp), 'UPDATE', NULL, PARSE_JSON(:P_HIRE), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    LET rs_calc RESULTSET := (
        SELECT PERIOD_KEY FROM T_F_SCENARIO_PERIOD
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_STATUS NOT IN ('FINALIZED', 'LOCKED')
        ORDER BY PERIOD_KEY);
    LET cur_calc CURSOR FOR rs_calc;
    FOR rec IN cur_calc DO
        v_pk := rec.PERIOD_KEY;
        CALL SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :v_pk);
    END FOR;

    COMMIT;
    DROP TABLE IF EXISTS TMP_HIRE;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Planned hire saved.', 'employee_id', v_emp);
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        DROP TABLE IF EXISTS TMP_HIRE;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
