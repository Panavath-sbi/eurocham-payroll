/* =====================================================================================
   R - SP_CREATE_SCENARIO
   Creates a budget scenario, empty or copied from another budget scenario.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  V1.5.0: CORE tables moved to APP; role check reads T_D_APP_USER.ROLE_CODE (one role per user).
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   Budget Input page: create a scenario / copy a scenario.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* Empty scenario (P_SOURCE_SCENARIO_ID = NULL): 12 months of P_FISCAL_YEAR with the budget
   calendar (all 12 BUDGET_WORKING_DAYS must be set), FX assumption = the latest actual
   month's rates, and every active employee's current contract terms.
   Copy (P_SOURCE_SCENARIO_ID given): same fiscal year as the source; its months, employee
   terms, monthly inputs, allocations and planned hires (as new planned employees) are copied.
   The new scenario is DRAFT and fully calculated. Roles: PAYROLL_ADMIN or BUDGET_EDITOR. */
USE DATABASE PAYROLL_DB;
   
CREATE OR REPLACE PROCEDURE APP.SP_CREATE_SCENARIO(P_USER_EMAIL TEXT, P_SCENARIO_NAME TEXT, P_FISCAL_YEAR INT,
                                                   P_SOURCE_SCENARIO_ID INT, P_DESCRIPTION TEXT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Creates a budget scenario'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_allowed   INT;
    v_name      TEXT;
    v_dupe      INT;
    v_year      INT;
    v_src_type  TEXT;
    v_src_year  INT;
    v_unset     INT;
    v_nbc       FLOAT;
    v_nssf      FLOAT;
    v_new       INT;
    v_emps      INT DEFAULT 0;
    v_pk        INT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE AND u.ROLE_CODE IN ('PAYROLL_ADMIN', 'BUDGET_EDITOR');
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not allowed to manage budgets and forecasts.');
    END IF;

    v_name := TRIM(P_SCENARIO_NAME);
    IF (COALESCE(v_name, '') = '') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A scenario name is required.');
    END IF;
    SELECT COUNT(*) INTO :v_dupe FROM APP.T_D_SCENARIO WHERE UPPER(SCENARIO_NAME) = UPPER(:v_name);
    IF (v_dupe > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A scenario named ' || v_name || ' already exists.');
    END IF;

    IF (P_SOURCE_SCENARIO_ID IS NOT NULL) THEN
        SELECT MAX(SCENARIO_TYPE), MAX(FISCAL_YEAR) INTO :v_src_type, :v_src_year
        FROM APP.T_D_SCENARIO WHERE SCENARIO_ID = :P_SOURCE_SCENARIO_ID;
        IF (v_src_type IS NULL OR v_src_type <> 'BUDGET') THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The source must be an existing budget scenario.');
        END IF;
        IF (P_FISCAL_YEAR IS NOT NULL AND P_FISCAL_YEAR <> v_src_year) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A copy keeps the fiscal year of its source (' || v_src_year || ').');
        END IF;
        v_year := v_src_year;
    ELSE
        v_year := P_FISCAL_YEAR;
        IF (v_year IS NULL) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A fiscal year is required.');
        END IF;
        SELECT COUNT_IF(COALESCE(BUDGET_WORKING_DAYS, 0) = 0) INTO :v_unset FROM APP.T_D_PERIOD WHERE YEAR = :v_year;
        IF (v_unset > 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_unset || ' month(s) of ' || v_year || ' have no budget working days. Set them on the Settings page.');
        END IF;
        SELECT MAX_BY(x.FX_RATE_NBC, x.PERIOD_KEY), MAX_BY(x.FX_RATE_NSSF, x.PERIOD_KEY) INTO :v_nbc, :v_nssf
        FROM APP.T_F_SCENARIO_PERIOD x
        JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID AND s.SCENARIO_TYPE = 'ACTUAL';
        IF (v_nbc IS NULL) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No actual month exists to take the exchange rate assumption from.');
        END IF;
    END IF;

    BEGIN TRANSACTION;

    INSERT INTO APP.T_D_SCENARIO (SCENARIO_TYPE, SCENARIO_NAME, FISCAL_YEAR, SCENARIO_STATUS, IS_OFFICIAL, BASE_SCENARIO_ID, DESCRIPTION, INSERT_BY, UPDATE_BY)
    SELECT 'BUDGET', :v_name, :v_year, 'DRAFT', FALSE, :P_SOURCE_SCENARIO_ID, :P_DESCRIPTION, :P_USER_EMAIL, :P_USER_EMAIL;
    SELECT MAX(SCENARIO_ID) INTO :v_new FROM APP.T_D_SCENARIO WHERE SCENARIO_NAME = :v_name;

    IF (P_SOURCE_SCENARIO_ID IS NULL) THEN
        INSERT INTO APP.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY, PERIOD_STATUS, WORKING_DAYS, FX_RATE_NBC, FX_RATE_NSSF, INSERT_BY, UPDATE_BY)
        SELECT :v_new, PERIOD_KEY, 'DRAFT', BUDGET_WORKING_DAYS, :v_nbc, :v_nssf, :P_USER_EMAIL, :P_USER_EMAIL
        FROM APP.T_D_PERIOD WHERE YEAR = :v_year;

        INSERT INTO APP.T_D_SCENARIO_EMPLOYEE
            (SCENARIO_ID, EMPLOYEE_ID, SOURCE_CONTRACT_ID, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
             MONTHLY_SALARY_USD, RAISE_PCT, REVALUATION_PERIOD_KEY, FINAL_SALARY_USD, TAX_STATUS,
             DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD, WORK_PERMIT_USD, FRINGE_BENEFIT_USD, INSERT_BY, UPDATE_BY)
        SELECT :v_new, c.EMPLOYEE_ID, c.CONTRACT_ID, c.POSITION, c.EMPLOYMENT_TYPE, c.CONTRACT_TYPE, c.ENTITY_CODE,
               c.MONTHLY_SALARY_USD, 0, NULL, c.MONTHLY_SALARY_USD, c.TAX_STATUS,
               c.DEPENDANT_CHILDREN, c.DEPENDANT_SPOUSE, c.INSURANCE_USD, c.VISA_USD, c.WORK_PERMIT_USD, c.FRINGE_BENEFIT_USD,
               :P_USER_EMAIL, :P_USER_EMAIL
        FROM APP.T_D_EMPLOYEE e
        JOIN APP.T_D_EMPLOYEE_CONTRACT c ON c.EMPLOYEE_ID = e.EMPLOYEE_ID AND c.VALID_TO_PERIOD_KEY IS NULL
        WHERE e.IS_ACTIVE AND NOT e.IS_PLANNED;
        v_emps := SQLROWCOUNT;
    ELSE
        INSERT INTO APP.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY, PERIOD_STATUS, WORKING_DAYS, FX_RATE_NBC, FX_RATE_NSSF, INSERT_BY, UPDATE_BY)
        SELECT :v_new, PERIOD_KEY, 'DRAFT', WORKING_DAYS, FX_RATE_NBC, FX_RATE_NSSF, :P_USER_EMAIL, :P_USER_EMAIL
        FROM APP.T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :P_SOURCE_SCENARIO_ID;

        -- Planned hires of the source become new planned employees of the copy
        INSERT INTO APP.T_D_EMPLOYEE (RESOURCE_CODE, FIRST_NAME, LAST_NAME, IS_ACTIVE, IS_PLANNED, PLANNED_SCENARIO_ID, INSERT_BY, UPDATE_BY)
        SELECT 'PLAN-' || :v_new || '-' || EMPLOYEE_ID, FIRST_NAME, LAST_NAME, TRUE, TRUE, :v_new, :P_USER_EMAIL, :P_USER_EMAIL
        FROM APP.T_D_EMPLOYEE WHERE IS_PLANNED AND PLANNED_SCENARIO_ID = :P_SOURCE_SCENARIO_ID;

        -- (old employee id -> new id: planned hires are remapped, actual employees keep their id)

        INSERT INTO APP.T_D_SCENARIO_EMPLOYEE
            (SCENARIO_ID, EMPLOYEE_ID, SOURCE_CONTRACT_ID, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
             MONTHLY_SALARY_USD, RAISE_PCT, REVALUATION_PERIOD_KEY, FINAL_SALARY_USD, TAX_STATUS,
             DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD, WORK_PERMIT_USD, FRINGE_BENEFIT_USD, INSERT_BY, UPDATE_BY)
        SELECT :v_new, m.NEW_ID, se.SOURCE_CONTRACT_ID, se.POSITION, se.EMPLOYMENT_TYPE, se.CONTRACT_TYPE, se.ENTITY_CODE,
               se.MONTHLY_SALARY_USD, se.RAISE_PCT, se.REVALUATION_PERIOD_KEY, se.FINAL_SALARY_USD, se.TAX_STATUS,
               se.DEPENDANT_CHILDREN, se.DEPENDANT_SPOUSE, se.INSURANCE_USD, se.VISA_USD, se.WORK_PERMIT_USD, se.FRINGE_BENEFIT_USD,
               :P_USER_EMAIL, :P_USER_EMAIL
        FROM APP.T_D_SCENARIO_EMPLOYEE se JOIN (SELECT se.EMPLOYEE_ID AS OLD_ID, COALESCE(n.EMPLOYEE_ID, se.EMPLOYEE_ID) AS NEW_ID
                     FROM APP.T_D_SCENARIO_EMPLOYEE se
                     LEFT JOIN APP.T_D_EMPLOYEE n ON n.RESOURCE_CODE = 'PLAN-' || :v_new || '-' || se.EMPLOYEE_ID
                     WHERE se.SCENARIO_ID = :P_SOURCE_SCENARIO_ID) m ON m.OLD_ID = se.EMPLOYEE_ID
        WHERE se.SCENARIO_ID = :P_SOURCE_SCENARIO_ID;
        v_emps := SQLROWCOUNT;

        INSERT INTO APP.T_F_PAYROLL_INPUT
            (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, INCLUDE_IN_PAYROLL, ABSENCE_DAYS, OVERTIME_DAYS, OUTSTANDING_DAYS, BONUS_USD,
             SALARY_OVERRIDE_USD, FRINGE_BENEFIT_OVERRIDE_USD, NOTES, INSERT_BY, UPDATE_BY)
        SELECT :v_new, i.PERIOD_KEY, m.NEW_ID, i.INCLUDE_IN_PAYROLL, i.ABSENCE_DAYS, i.OVERTIME_DAYS, i.OUTSTANDING_DAYS, i.BONUS_USD,
               i.SALARY_OVERRIDE_USD, i.FRINGE_BENEFIT_OVERRIDE_USD, i.NOTES, :P_USER_EMAIL, :P_USER_EMAIL
        FROM APP.T_F_PAYROLL_INPUT i JOIN (SELECT se.EMPLOYEE_ID AS OLD_ID, COALESCE(n.EMPLOYEE_ID, se.EMPLOYEE_ID) AS NEW_ID
                     FROM APP.T_D_SCENARIO_EMPLOYEE se
                     LEFT JOIN APP.T_D_EMPLOYEE n ON n.RESOURCE_CODE = 'PLAN-' || :v_new || '-' || se.EMPLOYEE_ID
                     WHERE se.SCENARIO_ID = :P_SOURCE_SCENARIO_ID) m ON m.OLD_ID = i.EMPLOYEE_ID
        WHERE i.SCENARIO_ID = :P_SOURCE_SCENARIO_ID;

        INSERT INTO APP.T_F_FUND_ALLOCATION (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, FUND_CODE, SHARE_PCT, INSERT_BY, UPDATE_BY)
        SELECT :v_new, a.PERIOD_KEY, m.NEW_ID, a.FUND_CODE, a.SHARE_PCT, :P_USER_EMAIL, :P_USER_EMAIL
        FROM APP.T_F_FUND_ALLOCATION a JOIN (SELECT se.EMPLOYEE_ID AS OLD_ID, COALESCE(n.EMPLOYEE_ID, se.EMPLOYEE_ID) AS NEW_ID
                     FROM APP.T_D_SCENARIO_EMPLOYEE se
                     LEFT JOIN APP.T_D_EMPLOYEE n ON n.RESOURCE_CODE = 'PLAN-' || :v_new || '-' || se.EMPLOYEE_ID
                     WHERE se.SCENARIO_ID = :P_SOURCE_SCENARIO_ID) m ON m.OLD_ID = a.EMPLOYEE_ID
        WHERE a.SCENARIO_ID = :P_SOURCE_SCENARIO_ID;

        INSERT INTO APP.T_F_DEPARTMENT_ALLOCATION (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, DEPARTMENT_CODE, SHARE_PCT, INSERT_BY, UPDATE_BY)
        SELECT :v_new, a.PERIOD_KEY, m.NEW_ID, a.DEPARTMENT_CODE, a.SHARE_PCT, :P_USER_EMAIL, :P_USER_EMAIL
        FROM APP.T_F_DEPARTMENT_ALLOCATION a JOIN (SELECT se.EMPLOYEE_ID AS OLD_ID, COALESCE(n.EMPLOYEE_ID, se.EMPLOYEE_ID) AS NEW_ID
                     FROM APP.T_D_SCENARIO_EMPLOYEE se
                     LEFT JOIN APP.T_D_EMPLOYEE n ON n.RESOURCE_CODE = 'PLAN-' || :v_new || '-' || se.EMPLOYEE_ID
                     WHERE se.SCENARIO_ID = :P_SOURCE_SCENARIO_ID) m ON m.OLD_ID = a.EMPLOYEE_ID
        WHERE a.SCENARIO_ID = :P_SOURCE_SCENARIO_ID;
    END IF;

    LET rs_calc RESULTSET := (
        SELECT PERIOD_KEY FROM APP.T_F_SCENARIO_PERIOD
        WHERE SCENARIO_ID = :v_new AND PERIOD_STATUS NOT IN ('FINALIZED', 'LOCKED')
        ORDER BY PERIOD_KEY);
    LET cur_calc CURSOR FOR rs_calc;
    FOR rec IN cur_calc DO
        v_pk := rec.PERIOD_KEY;
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :v_new, :v_pk);
    END FOR;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_SCENARIO', OBJECT_CONSTRUCT('SCENARIO_ID', :v_new), 'INSERT', NULL, OBJECT_CONSTRUCT('SCENARIO_NAME', :v_name, 'FISCAL_YEAR', :v_year, 'SOURCE_SCENARIO_ID', :P_SOURCE_SCENARIO_ID, 'EMPLOYEES', :v_emps), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Scenario ' || v_name || ' created with ' || v_emps || ' employees.', 'scenario_id', v_new);
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
