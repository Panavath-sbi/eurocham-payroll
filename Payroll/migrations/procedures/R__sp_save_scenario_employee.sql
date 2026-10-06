/* =====================================================================================
   R - SP_SAVE_SCENARIO_EMPLOYEE
   Edits employee terms inside a budget or forecast scenario.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  V1.5.0: CORE tables moved to APP; role check reads T_D_APP_USER.ROLE_CODE (one role per user).
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   Budget Input grid (salary, raise, revaluation month, fringe) and Forecast edits.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* P_EMPLOYEES: JSON array; employee_id required, then any of monthly_salary_usd, raise_pct,
   revaluation_period_key (null clears the raise month), fringe_benefit_usd, position,
   employment_type, contract_type, entity_code, tax_status, dependant_children,
   dependant_spouse, insurance_usd, visa_usd, work_permit_usd. Keys left out keep their value.
   FINAL_SALARY_USD = monthly salary x (1 + raise % / 100), rounded to the cent.
   The revaluation month must be one of the scenario's months. Only this scenario changes;
   real contracts are never touched. The scenario is recalculated.
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3). */
USE DATABASE PAYROLL_DB;
   
CREATE OR REPLACE PROCEDURE APP.SP_SAVE_SCENARIO_EMPLOYEE(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_EMPLOYEES TEXT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Edits employee terms in a budget or forecast scenario'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_allowed     INT;
    v_type        TEXT;
    v_scen_status TEXT;
    v_rows        INT;
    v_bad         INT;
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

    CREATE OR REPLACE TEMPORARY TABLE APP.TMP_SCEN_EMP AS
    SELECT
        f.VALUE:employee_id::INT AS EMPLOYEE_ID,
        se.EMPLOYEE_ID IS NOT NULL AS IN_SCENARIO,
        COALESCE(f.VALUE:monthly_salary_usd::FLOAT, se.MONTHLY_SALARY_USD) AS MONTHLY_SALARY_USD,
        COALESCE(f.VALUE:raise_pct::FLOAT, se.RAISE_PCT, 0)                AS RAISE_PCT,
        IFF(IS_NULL_VALUE(f.VALUE:revaluation_period_key), NULL,
            COALESCE(f.VALUE:revaluation_period_key::INT, se.REVALUATION_PERIOD_KEY)) AS REVALUATION_PERIOD_KEY,
        COALESCE(f.VALUE:fringe_benefit_usd::FLOAT, se.FRINGE_BENEFIT_USD) AS FRINGE_BENEFIT_USD,
        COALESCE(f.VALUE:position::TEXT, se.POSITION)                      AS POSITION,
        COALESCE(f.VALUE:employment_type::TEXT, se.EMPLOYMENT_TYPE)        AS EMPLOYMENT_TYPE,
        COALESCE(f.VALUE:contract_type::TEXT, se.CONTRACT_TYPE)            AS CONTRACT_TYPE,
        COALESCE(f.VALUE:entity_code::TEXT, se.ENTITY_CODE)                AS ENTITY_CODE,
        COALESCE(f.VALUE:tax_status::TEXT, se.TAX_STATUS)                  AS TAX_STATUS,
        COALESCE(f.VALUE:dependant_children::INT, se.DEPENDANT_CHILDREN)   AS DEPENDANT_CHILDREN,
        COALESCE(f.VALUE:dependant_spouse::INT, se.DEPENDANT_SPOUSE)       AS DEPENDANT_SPOUSE,
        COALESCE(f.VALUE:insurance_usd::FLOAT, se.INSURANCE_USD)           AS INSURANCE_USD,
        COALESCE(f.VALUE:visa_usd::FLOAT, se.VISA_USD)                     AS VISA_USD,
        COALESCE(f.VALUE:work_permit_usd::FLOAT, se.WORK_PERMIT_USD)       AS WORK_PERMIT_USD,
        TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL('MONTHLY_SALARY_USD', se.MONTHLY_SALARY_USD, 'RAISE_PCT', se.RAISE_PCT,
                'REVALUATION_PERIOD_KEY', se.REVALUATION_PERIOD_KEY, 'FINAL_SALARY_USD', se.FINAL_SALARY_USD,
                'FRINGE_BENEFIT_USD', se.FRINGE_BENEFIT_USD, 'ENTITY_CODE', se.ENTITY_CODE)) AS OLD_VALUES
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_EMPLOYEES))) f
    LEFT JOIN APP.T_D_SCENARIO_EMPLOYEE se
           ON se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = f.VALUE:employee_id::INT;

    SELECT COUNT(*),
           COUNT_IF(NOT t.IN_SCENARIO OR t.MONTHLY_SALARY_USD < 0 OR t.RAISE_PCT < -100 OR t.FRINGE_BENEFIT_USD < 0
                    OR t.INSURANCE_USD < 0 OR t.VISA_USD < 0 OR t.WORK_PERMIT_USD < 0 OR t.DEPENDANT_CHILDREN < 0
                    OR t.DEPENDANT_SPOUSE NOT IN (0, 1) OR t.TAX_STATUS NOT IN ('RESIDENT', 'NON_RESIDENT')
                    OR e.ENTITY_CODE IS NULL
                    OR (t.REVALUATION_PERIOD_KEY IS NOT NULL AND x.PERIOD_KEY IS NULL))
      INTO :v_rows, :v_bad
    FROM APP.TMP_SCEN_EMP t
    LEFT JOIN APP.T_D_ENTITY e ON e.ENTITY_CODE = t.ENTITY_CODE AND e.IS_ACTIVE
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = :P_SCENARIO_ID AND x.PERIOD_KEY = t.REVALUATION_PERIOD_KEY;
    IF (v_rows = 0 OR v_bad > 0) THEN
        DROP TABLE IF EXISTS APP.TMP_SCEN_EMP;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Invalid rows: employees must be in the scenario, amounts >= 0, raise >= -100%, a known chamber and a revaluation month inside the scenario.');
    END IF;

    BEGIN TRANSACTION;

    UPDATE APP.T_D_SCENARIO_EMPLOYEE se
    SET MONTHLY_SALARY_USD = t.MONTHLY_SALARY_USD, RAISE_PCT = t.RAISE_PCT, REVALUATION_PERIOD_KEY = t.REVALUATION_PERIOD_KEY,
        FINAL_SALARY_USD = ROUND(t.MONTHLY_SALARY_USD * (1 + t.RAISE_PCT / 100), 2),
        FRINGE_BENEFIT_USD = t.FRINGE_BENEFIT_USD, POSITION = t.POSITION, EMPLOYMENT_TYPE = t.EMPLOYMENT_TYPE,
        CONTRACT_TYPE = t.CONTRACT_TYPE, ENTITY_CODE = t.ENTITY_CODE, TAX_STATUS = t.TAX_STATUS,
        DEPENDANT_CHILDREN = t.DEPENDANT_CHILDREN, DEPENDANT_SPOUSE = t.DEPENDANT_SPOUSE,
        INSURANCE_USD = t.INSURANCE_USD, VISA_USD = t.VISA_USD, WORK_PERMIT_USD = t.WORK_PERMIT_USD,
        UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM APP.TMP_SCEN_EMP t
    WHERE se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = t.EMPLOYEE_ID;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_SCENARIO_EMPLOYEE', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'EMPLOYEE_ID', t.EMPLOYEE_ID), 'UPDATE',
           PARSE_JSON(t.OLD_VALUES),
           OBJECT_CONSTRUCT_KEEP_NULL('MONTHLY_SALARY_USD', se.MONTHLY_SALARY_USD, 'RAISE_PCT', se.RAISE_PCT,
                'REVALUATION_PERIOD_KEY', se.REVALUATION_PERIOD_KEY, 'FINAL_SALARY_USD', se.FINAL_SALARY_USD,
                'FRINGE_BENEFIT_USD', se.FRINGE_BENEFIT_USD, 'ENTITY_CODE', se.ENTITY_CODE),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.TMP_SCEN_EMP t
    JOIN APP.T_D_SCENARIO_EMPLOYEE se ON se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = t.EMPLOYEE_ID;

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
    DROP TABLE IF EXISTS APP.TMP_SCEN_EMP;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_rows || ' employee(s) updated and the scenario recalculated.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        DROP TABLE IF EXISTS APP.TMP_SCEN_EMP;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
