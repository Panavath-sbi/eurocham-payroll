CREATE OR REPLACE PROCEDURE APP.SP_SAVE_FUND_ALLOCATION(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT, P_EMPLOYEE_ID INT, P_ALLOCATIONS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Saves the fund split of one employee'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_type        TEXT;
    v_scen_status TEXT;
    v_status      TEXT;
    v_wd          INT;
    v_allowed     INT;
    v_in_payroll  INT;
    v_rows        INT;
    v_bad         INT;
    v_dupes       INT;
    v_total       FLOAT;
    v_old         TEXT;
    v_new         TEXT;
    v_ids         TEXT;
BEGIN
    SELECT MAX(s.SCENARIO_TYPE), MAX(s.SCENARIO_STATUS), MAX(x.PERIOD_STATUS), MAX(x.WORKING_DAYS)
      INTO :v_type, :v_scen_status, :v_status, :v_wd
    FROM APP.T_D_SCENARIO s
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID AND x.PERIOD_KEY = :P_PERIOD_KEY
    WHERE s.SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' does not exist.');
    END IF;
    IF (v_status IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' does not exist in this scenario.');
    END IF;
    IF (v_type = 'ACTUAL' AND v_status <> 'OPEN' AND v_status <> 'IN_APPROVAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' is ' || v_status || ' and cannot be edited.');
    END IF;
    IF (v_type <> 'ACTUAL' AND ((v_scen_status <> 'DRAFT' AND v_scen_status <> 'REJECTED') OR v_status <> 'DRAFT')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This scenario is ' || v_scen_status || ' and cannot be edited.');
    END IF;

    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT COUNT(*) INTO :v_in_payroll
    FROM (SELECT EMPLOYEE_ID FROM APP.T_F_PAYROLL_INPUT
          WHERE :v_type = 'ACTUAL' AND SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :P_EMPLOYEE_ID
          UNION
          SELECT EMPLOYEE_ID FROM APP.T_D_SCENARIO_EMPLOYEE
          WHERE :v_type <> 'ACTUAL' AND SCENARIO_ID = :P_SCENARIO_ID AND EMPLOYEE_ID = :P_EMPLOYEE_ID);
    IF (v_in_payroll = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || P_EMPLOYEE_ID || ' is not part of this payroll.');
    END IF;

    -- Checks, and the new split (rows with a share > 0) kept in v_new
    SELECT COUNT(*), COUNT(*) - COUNT(DISTINCT t.CODE), COALESCE(SUM(t.SHARE_PCT), 0),
           COUNT_IF(t.CODE IS NULL OR t.SHARE_PCT IS NULL OR t.SHARE_PCT < 0 OR d.FUND_CODE IS NULL),
           TO_JSON(ARRAY_AGG(IFF(t.SHARE_PCT > 0, OBJECT_CONSTRUCT('fund_code', t.CODE, 'share_pct', t.SHARE_PCT), NULL)))
      INTO :v_rows, :v_dupes, :v_total, :v_bad, :v_new
    FROM (SELECT f.VALUE:fund_code::TEXT AS CODE,
                 COALESCE(f.VALUE:share_pct::FLOAT, f.VALUE:days::FLOAT / NULLIF(:v_wd, 0) * 100) AS SHARE_PCT
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_ALLOCATIONS))) f) t
    LEFT JOIN APP.T_D_FUND d ON d.FUND_CODE = t.CODE AND d.IS_ACTIVE;
    IF (v_rows = 0 OR v_bad > 0 OR v_dupes > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each row needs a known, active fund code and a share >= 0, with no duplicates.');
    END IF;
    IF (ABS(v_total - 100) > 0.01) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The shares total ' || ROUND(v_total, 2) || '%. They must total 100%.');
    END IF;

    BEGIN TRANSACTION;

    SELECT TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT('fund_code', FUND_CODE, 'share_pct', SHARE_PCT))) INTO :v_old
    FROM APP.T_F_FUND_ALLOCATION WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :P_EMPLOYEE_ID;

    DELETE FROM APP.T_F_FUND_ALLOCATION WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :P_EMPLOYEE_ID;

    INSERT INTO APP.T_F_FUND_ALLOCATION (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, FUND_CODE, SHARE_PCT, INSERT_BY, UPDATE_BY)
    SELECT :P_SCENARIO_ID, :P_PERIOD_KEY, :P_EMPLOYEE_ID, VALUE:fund_code::TEXT, VALUE:share_pct::FLOAT, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)));

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_FUND_ALLOCATION', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'PERIOD_KEY', :P_PERIOD_KEY, 'EMPLOYEE_ID', :P_EMPLOYEE_ID), 'UPDATE', PARSE_JSON(:v_old), PARSE_JSON(:v_new), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_type = 'ACTUAL') THEN
        v_ids := '[' || P_EMPLOYEE_ID || ']';
        CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :P_SCENARIO_ID, :P_PERIOD_KEY, :v_ids, 'Fund split changed');
    END IF;
    CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :P_PERIOD_KEY);

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Fund split saved.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
