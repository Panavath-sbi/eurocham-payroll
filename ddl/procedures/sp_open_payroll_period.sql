CREATE OR REPLACE PROCEDURE APP.SP_OPEN_PAYROLL_PERIOD(P_USER_EMAIL TEXT, P_PERIOD_KEY INT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Opens a new actual payroll month'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed     INT;
    v_scen        INT;
    v_open        INT;
    v_exists      INT;
    v_existing    INT;
    v_max_period  INT;
    v_prev        INT;
    v_prev_status TEXT;
    v_wd          INT;
    v_nbc         FLOAT;
    v_nssf        FLOAT;
    v_emp         INT DEFAULT 0;
BEGIN
    -- Any active app user may do this (roles only limit approvals)
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    -- Actual scenario
    SELECT MAX(SCENARIO_ID) INTO :v_scen FROM APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'ACTUAL';
    IF (v_scen IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The ACTUAL scenario is missing.');
    END IF;

    -- Period must exist in the calendar
    SELECT MAX(TO_NUMBER(TO_CHAR(DATEADD(MONTH, -1, PERIOD_START_DATE), 'YYYYMM'))), MAX(WORKING_DAYS)
      INTO :v_prev, :v_wd
    FROM APP.T_D_PERIOD WHERE PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_prev IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' is not in the calendar.');
    END IF;
    IF (v_wd IS NULL OR v_wd <= 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Set the working days for ' || P_PERIOD_KEY || ' on the Settings page first.');
    END IF;

    -- Only one open month at a time; no reopening; no going backwards
    SELECT COUNT_IF(PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL')), COUNT_IF(PERIOD_KEY = :P_PERIOD_KEY),
           COUNT(*), MAX(PERIOD_KEY)
      INTO :v_open, :v_exists, :v_existing, :v_max_period
    FROM APP.T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :v_scen;
    IF (v_open > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Another payroll month is still open. Finalize it first.');
    END IF;
    IF (v_exists > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' already exists.');
    END IF;
    IF (v_existing > 0 AND P_PERIOD_KEY < v_max_period) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' is earlier than the latest period.');
    END IF;

    -- Previous month must be finalized (skipped for the very first period)
    IF (v_existing > 0) THEN
        SELECT MAX(PERIOD_STATUS) INTO :v_prev_status
        FROM APP.T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :v_prev;
        IF (v_prev_status IS NULL OR v_prev_status <> 'FINALIZED') THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The previous month (' || v_prev || ') must be finalized first.');
        END IF;
    END IF;

    -- FX rates: published rate for the month, otherwise last month's applied rate
    SELECT MAX(FX_RATE_NBC), MAX(FX_RATE_NSSF) INTO :v_nbc, :v_nssf
    FROM APP.T_D_PERIOD WHERE PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_nbc IS NULL OR v_nssf IS NULL) THEN
        SELECT COALESCE(:v_nbc, MAX(FX_RATE_NBC)), COALESCE(:v_nssf, MAX(FX_RATE_NSSF))
          INTO :v_nbc, :v_nssf
        FROM APP.T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :v_prev;
    END IF;
    IF (v_nbc IS NULL OR v_nssf IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No NBC / NSSF exchange rates found for ' || P_PERIOD_KEY || '.');
    END IF;

    BEGIN TRANSACTION;

    -- Non-residency ended before this month: the employee is RESIDENT from this month.
    -- Logged first (the rows still show NON_RESIDENT).
    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_EMPLOYEE_CONTRACT',
           OBJECT_CONSTRUCT('EMPLOYEE_ID', c.EMPLOYEE_ID, 'EFFECTIVE_PERIOD_KEY', :P_PERIOD_KEY), 'UPDATE',
           OBJECT_CONSTRUCT('TAX_STATUS', 'NON_RESIDENT', 'NON_RESIDENT_TO', c.NON_RESIDENT_TO),
           OBJECT_CONSTRUCT('TAX_STATUS', 'RESIDENT', 'CHANGE_REASON', 'Non-residency ended (automatic)'),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.T_D_EMPLOYEE_CONTRACT c
    WHERE :P_PERIOD_KEY BETWEEN c.VALID_FROM_PERIOD_KEY AND COALESCE(c.VALID_TO_PERIOD_KEY, 999912)
      AND c.TAX_STATUS = 'NON_RESIDENT'
      AND c.NON_RESIDENT_TO < DATE_FROM_PARTS(FLOOR(:P_PERIOD_KEY / 100), MOD(:P_PERIOD_KEY, 100), 1);

    -- A version that starts this month is corrected in place
    UPDATE APP.T_D_EMPLOYEE_CONTRACT
    SET TAX_STATUS = 'RESIDENT', NON_RESIDENT_FROM = NULL, NON_RESIDENT_TO = NULL,
        CHANGE_REASON = 'Non-residency ended (automatic)', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHERE VALID_FROM_PERIOD_KEY = :P_PERIOD_KEY
      AND TAX_STATUS = 'NON_RESIDENT'
      AND NON_RESIDENT_TO < DATE_FROM_PARTS(FLOOR(:P_PERIOD_KEY / 100), MOD(:P_PERIOD_KEY, 100), 1);

    -- Otherwise: a new RESIDENT version from this month ...
    INSERT INTO APP.T_D_EMPLOYEE_CONTRACT
        (EMPLOYEE_ID, VALID_FROM_PERIOD_KEY, VALID_TO_PERIOD_KEY, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
         MONTHLY_SALARY_USD, TAX_STATUS, DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD,
         WORK_PERMIT_USD, FRINGE_BENEFIT_USD, CHANGE_REASON, NON_RESIDENT_FROM, NON_RESIDENT_TO, INSERT_BY, UPDATE_BY)
    SELECT EMPLOYEE_ID, :P_PERIOD_KEY, VALID_TO_PERIOD_KEY, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
           MONTHLY_SALARY_USD, 'RESIDENT', DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD,
           WORK_PERMIT_USD, FRINGE_BENEFIT_USD, 'Non-residency ended (automatic)', NULL, NULL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.T_D_EMPLOYEE_CONTRACT
    WHERE VALID_FROM_PERIOD_KEY < :P_PERIOD_KEY
      AND :P_PERIOD_KEY <= COALESCE(VALID_TO_PERIOD_KEY, 999912)
      AND TAX_STATUS = 'NON_RESIDENT'
      AND NON_RESIDENT_TO < DATE_FROM_PARTS(FLOOR(:P_PERIOD_KEY / 100), MOD(:P_PERIOD_KEY, 100), 1);

    -- ... and the old version ends the month before
    UPDATE APP.T_D_EMPLOYEE_CONTRACT
    SET VALID_TO_PERIOD_KEY = :v_prev, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHERE VALID_FROM_PERIOD_KEY < :P_PERIOD_KEY
      AND :P_PERIOD_KEY <= COALESCE(VALID_TO_PERIOD_KEY, 999912)
      AND TAX_STATUS = 'NON_RESIDENT'
      AND NON_RESIDENT_TO < DATE_FROM_PARTS(FLOOR(:P_PERIOD_KEY / 100), MOD(:P_PERIOD_KEY, 100), 1);

    INSERT INTO APP.T_F_SCENARIO_PERIOD
        (SCENARIO_ID, PERIOD_KEY, PERIOD_STATUS, WORKING_DAYS, FX_RATE_NBC, FX_RATE_NSSF, INSERT_BY, UPDATE_BY)
    SELECT :v_scen, :P_PERIOD_KEY, 'OPEN', :v_wd, :v_nbc, :v_nssf, :P_USER_EMAIL, :P_USER_EMAIL;

    -- One empty input row per active employee with a contract valid this month
    INSERT INTO APP.T_F_PAYROLL_INPUT (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, INSERT_BY, UPDATE_BY)
    SELECT DISTINCT :v_scen, :P_PERIOD_KEY, e.EMPLOYEE_ID, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.T_D_EMPLOYEE e
    JOIN APP.T_D_EMPLOYEE_CONTRACT c
      ON c.EMPLOYEE_ID = e.EMPLOYEE_ID
     AND :P_PERIOD_KEY BETWEEN c.VALID_FROM_PERIOD_KEY AND COALESCE(c.VALID_TO_PERIOD_KEY, 999912)
    WHERE e.IS_ACTIVE AND NOT e.IS_PLANNED;
    v_emp := SQLROWCOUNT;

    -- Carry last month's splits forward for the employees included this month
    INSERT INTO APP.T_F_FUND_ALLOCATION (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, FUND_CODE, SHARE_PCT, INSERT_BY, UPDATE_BY)
    SELECT :v_scen, :P_PERIOD_KEY, f.EMPLOYEE_ID, f.FUND_CODE, f.SHARE_PCT, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.T_F_FUND_ALLOCATION f
    JOIN APP.T_F_PAYROLL_INPUT i
      ON i.SCENARIO_ID = :v_scen AND i.PERIOD_KEY = :P_PERIOD_KEY AND i.EMPLOYEE_ID = f.EMPLOYEE_ID
    WHERE f.SCENARIO_ID = :v_scen AND f.PERIOD_KEY = :v_prev;

    INSERT INTO APP.T_F_DEPARTMENT_ALLOCATION (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, DEPARTMENT_CODE, SHARE_PCT, INSERT_BY, UPDATE_BY)
    SELECT :v_scen, :P_PERIOD_KEY, d.EMPLOYEE_ID, d.DEPARTMENT_CODE, d.SHARE_PCT, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.T_F_DEPARTMENT_ALLOCATION d
    JOIN APP.T_F_PAYROLL_INPUT i
      ON i.SCENARIO_ID = :v_scen AND i.PERIOD_KEY = :P_PERIOD_KEY AND i.EMPLOYEE_ID = d.EMPLOYEE_ID
    WHERE d.SCENARIO_ID = :v_scen AND d.PERIOD_KEY = :v_prev;

    -- One PENDING approval row per step in force this month
    INSERT INTO APP.T_F_APPROVAL (SCENARIO_ID, PERIOD_KEY, STEP_ORDER, STEP_STATUS, INSERT_BY, UPDATE_BY)
    SELECT DISTINCT :v_scen, :P_PERIOD_KEY, st.STEP_ORDER, 'PENDING', :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.T_P_APPROVAL_STEP st
    WHERE st.IS_ACTIVE AND st.APPLIES_TO IN ('ALL', 'ACTUAL')
      AND :P_PERIOD_KEY BETWEEN st.VALID_FROM_PERIOD_KEY AND COALESCE(st.VALID_TO_PERIOD_KEY, 999912);

    CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :v_scen, :P_PERIOD_KEY);

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_SCENARIO_PERIOD',
           OBJECT_CONSTRUCT('SCENARIO_ID', :v_scen, 'PERIOD_KEY', :P_PERIOD_KEY),
           'INSERT', NULL,
           OBJECT_CONSTRUCT('PERIOD_STATUS', 'OPEN', 'WORKING_DAYS', :v_wd, 'FX_RATE_NBC', :v_nbc,
                            'FX_RATE_NSSF', :v_nssf, 'EMPLOYEES', :v_emp),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Payroll ' || P_PERIOD_KEY || ' opened for ' || v_emp || ' employees.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
