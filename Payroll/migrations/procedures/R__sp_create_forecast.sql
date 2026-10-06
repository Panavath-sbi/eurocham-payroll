/* =====================================================================================
   R - SP_CREATE_FORECAST
   Creates a roll-forward forecast from the actuals of a quarter.
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
   Forecast page: choose Q1 / Q2 / Q3 and generate.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* The forecast takes the actuals up to the end of the quarter (P_QUARTER 1-3, as-of month
   = March, June or September) and rolls the as-of month forward to December:
   - the as-of month must be FINALIZED;
   - months after it get the actual calendar's working days (weekdays if not set yet) and
     the as-of month's exchange rates;
   - each employee paid in the as-of month gets that month's contract terms;
   - fund and department splits of the as-of month are copied to every forecast month.
   Months up to the as-of month are not copied: reports read them from the actuals.
   P_SCENARIO_NAME defaults to 'Forecast <year> Q<quarter>'.
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3). */
USE DATABASE PAYROLL_DB;
   
CREATE OR REPLACE PROCEDURE APP.SP_CREATE_FORECAST(P_USER_EMAIL TEXT, P_FISCAL_YEAR INT, P_QUARTER INT, P_SCENARIO_NAME TEXT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Creates a roll-forward forecast'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_allowed INT;
    v_actual  INT;
    v_asof    INT;
    v_status  TEXT;
    v_nbc     FLOAT;
    v_nssf    FLOAT;
    v_name    TEXT;
    v_dupe    INT;
    v_new     INT;
    v_emps    INT DEFAULT 0;
    v_pk      INT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    IF (P_FISCAL_YEAR IS NULL OR P_QUARTER IS NULL OR P_QUARTER < 1 OR P_QUARTER > 3) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Give a fiscal year and a quarter from 1 to 3.');
    END IF;
    v_asof := P_FISCAL_YEAR * 100 + P_QUARTER * 3;
    v_name := COALESCE(NULLIF(TRIM(P_SCENARIO_NAME), ''), 'Forecast ' || P_FISCAL_YEAR || ' Q' || P_QUARTER);

    SELECT COUNT(*) INTO :v_dupe FROM APP.T_D_SCENARIO WHERE UPPER(SCENARIO_NAME) = UPPER(:v_name);
    IF (v_dupe > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A scenario named ' || v_name || ' already exists. Delete it or choose another name.');
    END IF;

    SELECT MAX(s.SCENARIO_ID), MAX(x.PERIOD_STATUS), MAX(x.FX_RATE_NBC), MAX(x.FX_RATE_NSSF)
      INTO :v_actual, :v_status, :v_nbc, :v_nssf
    FROM APP.T_D_SCENARIO s
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID AND x.PERIOD_KEY = :v_asof
    WHERE s.SCENARIO_TYPE = 'ACTUAL';
    IF (v_status IS NULL OR v_status <> 'FINALIZED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The actual payroll of ' || v_asof || ' must be finalized first.');
    END IF;

    BEGIN TRANSACTION;

    INSERT INTO APP.T_D_SCENARIO (SCENARIO_TYPE, SCENARIO_NAME, FISCAL_YEAR, SCENARIO_STATUS, IS_OFFICIAL, FORECAST_AS_OF_PERIOD_KEY, DESCRIPTION, INSERT_BY, UPDATE_BY)
    SELECT 'FORECAST', :v_name, :P_FISCAL_YEAR, 'DRAFT', FALSE, :v_asof,
           'Actuals to ' || :v_asof || ', rolled forward to December', :P_USER_EMAIL, :P_USER_EMAIL;
    SELECT MAX(SCENARIO_ID) INTO :v_new FROM APP.T_D_SCENARIO WHERE SCENARIO_NAME = :v_name;

    INSERT INTO APP.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY, PERIOD_STATUS, WORKING_DAYS, FX_RATE_NBC, FX_RATE_NSSF, INSERT_BY, UPDATE_BY)
    SELECT :v_new, PERIOD_KEY, 'DRAFT', COALESCE(NULLIF(WORKING_DAYS, 0), WEEKDAY_COUNT), :v_nbc, :v_nssf, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.T_D_PERIOD WHERE YEAR = :P_FISCAL_YEAR AND PERIOD_KEY > :v_asof;

    INSERT INTO APP.T_D_SCENARIO_EMPLOYEE
        (SCENARIO_ID, EMPLOYEE_ID, SOURCE_CONTRACT_ID, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
         MONTHLY_SALARY_USD, RAISE_PCT, REVALUATION_PERIOD_KEY, FINAL_SALARY_USD, TAX_STATUS,
         DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD, WORK_PERMIT_USD, FRINGE_BENEFIT_USD, INSERT_BY, UPDATE_BY)
    SELECT :v_new, c.EMPLOYEE_ID, c.CONTRACT_ID, c.POSITION, c.EMPLOYMENT_TYPE, c.CONTRACT_TYPE, c.ENTITY_CODE,
           c.MONTHLY_SALARY_USD, 0, NULL, c.MONTHLY_SALARY_USD, c.TAX_STATUS,
           c.DEPENDANT_CHILDREN, c.DEPENDANT_SPOUSE, c.INSURANCE_USD, c.VISA_USD, c.WORK_PERMIT_USD, c.FRINGE_BENEFIT_USD,
           :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.T_F_PAYROLL_INPUT i
    JOIN APP.T_D_EMPLOYEE_CONTRACT c
      ON c.EMPLOYEE_ID = i.EMPLOYEE_ID AND :v_asof BETWEEN c.VALID_FROM_PERIOD_KEY AND COALESCE(c.VALID_TO_PERIOD_KEY, 999912)
    WHERE i.SCENARIO_ID = :v_actual AND i.PERIOD_KEY = :v_asof AND i.INCLUDE_IN_PAYROLL;
    v_emps := SQLROWCOUNT;

    INSERT INTO APP.T_F_FUND_ALLOCATION (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, FUND_CODE, SHARE_PCT, INSERT_BY, UPDATE_BY)
    SELECT :v_new, x.PERIOD_KEY, a.EMPLOYEE_ID, a.FUND_CODE, a.SHARE_PCT, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.T_F_FUND_ALLOCATION a
    JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = :v_new
    JOIN APP.T_D_SCENARIO_EMPLOYEE se ON se.SCENARIO_ID = :v_new AND se.EMPLOYEE_ID = a.EMPLOYEE_ID
    WHERE a.SCENARIO_ID = :v_actual AND a.PERIOD_KEY = :v_asof;

    INSERT INTO APP.T_F_DEPARTMENT_ALLOCATION (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, DEPARTMENT_CODE, SHARE_PCT, INSERT_BY, UPDATE_BY)
    SELECT :v_new, x.PERIOD_KEY, a.EMPLOYEE_ID, a.DEPARTMENT_CODE, a.SHARE_PCT, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.T_F_DEPARTMENT_ALLOCATION a
    JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = :v_new
    JOIN APP.T_D_SCENARIO_EMPLOYEE se ON se.SCENARIO_ID = :v_new AND se.EMPLOYEE_ID = a.EMPLOYEE_ID
    WHERE a.SCENARIO_ID = :v_actual AND a.PERIOD_KEY = :v_asof;

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
    SELECT 'APP.T_D_SCENARIO', OBJECT_CONSTRUCT('SCENARIO_ID', :v_new), 'INSERT', NULL, OBJECT_CONSTRUCT('SCENARIO_NAME', :v_name, 'FORECAST_AS_OF_PERIOD_KEY', :v_asof, 'EMPLOYEES', :v_emps), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_name || ' created from ' || v_asof || ' for ' || v_emps || ' employees.', 'scenario_id', v_new);
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
