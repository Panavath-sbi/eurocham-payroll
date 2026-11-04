CREATE OR REPLACE PROCEDURE APP.SP_SAVE_MONTHLY_INPUT(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT, P_INPUTS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Saves monthly inputs for one scenario period'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_type        TEXT;
    v_scen_status TEXT;
    v_status      TEXT;
    v_wd          INT;
    v_allowed     INT;
    v_rows        INT;
    v_bad         INT;
    v_dupes       INT;
    v_unknown     INT;
    v_overrides   INT;
    v_changed     INT;
    v_new         TEXT;   -- JSON array: one object per employee (EMPLOYEE_ID, ROW_EXISTS, CHANGED, OLD_VALUES, NEW_VALUES)
BEGIN
    -- Scenario and period
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

    -- Any active app user may do this (roles only limit approvals)
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    -- Editable?
    IF (v_type = 'ACTUAL' AND v_status <> 'OPEN' AND v_status <> 'IN_APPROVAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' is ' || v_status || ' and cannot be edited.');
    END IF;
    IF (v_type <> 'ACTUAL' AND ((v_scen_status <> 'DRAFT' AND v_scen_status <> 'REJECTED') OR v_status <> 'DRAFT')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This scenario is ' || v_scen_status || ' and cannot be edited.');
    END IF;

    -- The incoming rows merged with the current values, checked, and kept in v_new
    SELECT COUNT(*),
           COUNT_IF(EMPLOYEE_ID IS NULL OR ABSENCE_DAYS < 0 OR OVERTIME_DAYS < 0 OR OUTSTANDING_DAYS < 0
                    OR BONUS_USD < 0 OR ABSENCE_DAYS > :v_wd
                    OR COALESCE(SALARY_OVERRIDE_USD, 0) < 0 OR COALESCE(FRINGE_BENEFIT_OVERRIDE_USD, 0) < 0),
           COUNT(*) - COUNT(DISTINCT EMPLOYEE_ID),
           COUNT_IF(SALARY_OVERRIDE_USD IS NOT NULL OR FRINGE_BENEFIT_OVERRIDE_USD IS NOT NULL),
           COUNT_IF(NOT ROW_EXISTS OR OLD_VALUES <> NEW_VALUES),
           TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT_KEEP_NULL(
               'EMPLOYEE_ID', EMPLOYEE_ID, 'ROW_EXISTS', ROW_EXISTS,
               'CHANGED', NOT ROW_EXISTS OR OLD_VALUES <> NEW_VALUES,
               'OLD_VALUES', OLD_VALUES, 'NEW_VALUES', NEW_VALUES)))
      INTO :v_rows, :v_bad, :v_dupes, :v_overrides, :v_changed, :v_new
    FROM (
        SELECT m.*,
               OBJECT_CONSTRUCT_KEEP_NULL(
                   'INCLUDE_IN_PAYROLL', INCLUDE_IN_PAYROLL, 'ABSENCE_DAYS', ABSENCE_DAYS,
                   'OVERTIME_DAYS', OVERTIME_DAYS, 'OUTSTANDING_DAYS', OUTSTANDING_DAYS,
                   'BONUS_USD', BONUS_USD, 'SALARY_OVERRIDE_USD', SALARY_OVERRIDE_USD,
                   'FRINGE_BENEFIT_OVERRIDE_USD', FRINGE_BENEFIT_OVERRIDE_USD, 'NOTES', NOTES) AS NEW_VALUES
        FROM (
            SELECT
                j.VALUE:employee_id::INT                                                           AS EMPLOYEE_ID,
                COALESCE(j.VALUE:include_in_payroll::BOOLEAN, t.INCLUDE_IN_PAYROLL, TRUE)          AS INCLUDE_IN_PAYROLL,
                COALESCE(j.VALUE:absence_days::FLOAT,     t.ABSENCE_DAYS, 0)                       AS ABSENCE_DAYS,
                COALESCE(j.VALUE:overtime_days::FLOAT,    t.OVERTIME_DAYS, 0)                      AS OVERTIME_DAYS,
                COALESCE(j.VALUE:outstanding_days::FLOAT, t.OUTSTANDING_DAYS, 0)                   AS OUTSTANDING_DAYS,
                COALESCE(j.VALUE:bonus_usd::FLOAT,        t.BONUS_USD, 0)                          AS BONUS_USD,
                IFF(IS_NULL_VALUE(j.VALUE:salary_override_usd), NULL,
                    COALESCE(j.VALUE:salary_override_usd::FLOAT, t.SALARY_OVERRIDE_USD))           AS SALARY_OVERRIDE_USD,
                IFF(IS_NULL_VALUE(j.VALUE:fringe_benefit_override_usd), NULL,
                    COALESCE(j.VALUE:fringe_benefit_override_usd::FLOAT, t.FRINGE_BENEFIT_OVERRIDE_USD)) AS FRINGE_BENEFIT_OVERRIDE_USD,
                COALESCE(j.VALUE:notes::TEXT, t.NOTES)                                             AS NOTES,
                t.EMPLOYEE_ID IS NOT NULL                                                          AS ROW_EXISTS,
                OBJECT_CONSTRUCT_KEEP_NULL(
                    'INCLUDE_IN_PAYROLL', t.INCLUDE_IN_PAYROLL, 'ABSENCE_DAYS', t.ABSENCE_DAYS,
                    'OVERTIME_DAYS', t.OVERTIME_DAYS, 'OUTSTANDING_DAYS', t.OUTSTANDING_DAYS,
                    'BONUS_USD', t.BONUS_USD, 'SALARY_OVERRIDE_USD', t.SALARY_OVERRIDE_USD,
                    'FRINGE_BENEFIT_OVERRIDE_USD', t.FRINGE_BENEFIT_OVERRIDE_USD, 'NOTES', t.NOTES)  AS OLD_VALUES
            FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_INPUTS))) j
            LEFT JOIN APP.T_F_PAYROLL_INPUT t
                   ON t.SCENARIO_ID = :P_SCENARIO_ID AND t.PERIOD_KEY = :P_PERIOD_KEY
                  AND t.EMPLOYEE_ID = j.VALUE:employee_id::INT) m);

    IF (v_rows = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No input rows received.');
    END IF;
    IF (v_bad > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_bad || ' row(s) have a missing employee, a negative value, or more absence days than working days (' || v_wd || ').');
    END IF;
    IF (v_dupes > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The same employee appears more than once.');
    END IF;
    IF (v_type = 'ACTUAL' AND v_overrides > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Salary and fringe overrides are only allowed in budgets and forecasts. Change the contract instead.');
    END IF;

    -- Employees must belong to the payroll: a valid contract (ACTUAL) or the scenario (BUDGET / FORECAST)
    SELECT COUNT(*) INTO :v_unknown
    FROM (SELECT VALUE:EMPLOYEE_ID::INT AS EMPLOYEE_ID FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))) x
    WHERE (:v_type = 'ACTUAL' AND NOT EXISTS (
              SELECT 1 FROM APP.T_D_EMPLOYEE e
              JOIN APP.T_D_EMPLOYEE_CONTRACT c ON c.EMPLOYEE_ID = e.EMPLOYEE_ID
              WHERE e.EMPLOYEE_ID = x.EMPLOYEE_ID AND e.IS_ACTIVE AND NOT e.IS_PLANNED
                AND :P_PERIOD_KEY BETWEEN c.VALID_FROM_PERIOD_KEY AND COALESCE(c.VALID_TO_PERIOD_KEY, 999912)))
       OR (:v_type <> 'ACTUAL' AND NOT EXISTS (
              SELECT 1 FROM APP.T_D_SCENARIO_EMPLOYEE se
              WHERE se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = x.EMPLOYEE_ID));
    IF (v_unknown > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_unknown || ' employee(s) are not part of this payroll.');
    END IF;

    IF (v_changed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'No changes to save.');
    END IF;

    BEGIN TRANSACTION;

    -- Audit first (old vs new), only for rows that actually change
    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_PAYROLL_INPUT',
           OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'PERIOD_KEY', :P_PERIOD_KEY, 'EMPLOYEE_ID', VALUE:EMPLOYEE_ID::INT),
           IFF(VALUE:ROW_EXISTS::BOOLEAN, 'UPDATE', 'INSERT'),
           IFF(VALUE:ROW_EXISTS::BOOLEAN, VALUE:OLD_VALUES, NULL),
           VALUE:NEW_VALUES,
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))
    WHERE VALUE:CHANGED::BOOLEAN;

    MERGE INTO APP.T_F_PAYROLL_INPUT t
    USING (SELECT VALUE:EMPLOYEE_ID::INT                                AS EMPLOYEE_ID,
                  VALUE:NEW_VALUES:INCLUDE_IN_PAYROLL::BOOLEAN          AS INCLUDE_IN_PAYROLL,
                  VALUE:NEW_VALUES:ABSENCE_DAYS::FLOAT                  AS ABSENCE_DAYS,
                  VALUE:NEW_VALUES:OVERTIME_DAYS::FLOAT                 AS OVERTIME_DAYS,
                  VALUE:NEW_VALUES:OUTSTANDING_DAYS::FLOAT              AS OUTSTANDING_DAYS,
                  VALUE:NEW_VALUES:BONUS_USD::FLOAT                     AS BONUS_USD,
                  VALUE:NEW_VALUES:SALARY_OVERRIDE_USD::FLOAT           AS SALARY_OVERRIDE_USD,
                  VALUE:NEW_VALUES:FRINGE_BENEFIT_OVERRIDE_USD::FLOAT   AS FRINGE_BENEFIT_OVERRIDE_USD,
                  VALUE:NEW_VALUES:NOTES::TEXT                          AS NOTES
           FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))
           WHERE VALUE:CHANGED::BOOLEAN) s
       ON t.SCENARIO_ID = :P_SCENARIO_ID AND t.PERIOD_KEY = :P_PERIOD_KEY AND t.EMPLOYEE_ID = s.EMPLOYEE_ID
    WHEN MATCHED THEN UPDATE SET
        INCLUDE_IN_PAYROLL          = s.INCLUDE_IN_PAYROLL,
        ABSENCE_DAYS                = s.ABSENCE_DAYS,
        OVERTIME_DAYS               = s.OVERTIME_DAYS,
        OUTSTANDING_DAYS            = s.OUTSTANDING_DAYS,
        BONUS_USD                   = s.BONUS_USD,
        SALARY_OVERRIDE_USD         = s.SALARY_OVERRIDE_USD,
        FRINGE_BENEFIT_OVERRIDE_USD = s.FRINGE_BENEFIT_OVERRIDE_USD,
        NOTES                       = s.NOTES,
        UPDATE_DATE                 = CURRENT_TIMESTAMP,
        UPDATE_BY                   = :P_USER_EMAIL
    WHEN NOT MATCHED THEN INSERT
        (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, INCLUDE_IN_PAYROLL, ABSENCE_DAYS, OVERTIME_DAYS, OUTSTANDING_DAYS,
         BONUS_USD, SALARY_OVERRIDE_USD, FRINGE_BENEFIT_OVERRIDE_USD, NOTES, INSERT_BY, UPDATE_BY)
    VALUES
        (:P_SCENARIO_ID, :P_PERIOD_KEY, s.EMPLOYEE_ID, s.INCLUDE_IN_PAYROLL, s.ABSENCE_DAYS, s.OVERTIME_DAYS,
         s.OUTSTANDING_DAYS, s.BONUS_USD, s.SALARY_OVERRIDE_USD, s.FRINGE_BENEFIT_OVERRIDE_USD, s.NOTES,
         :P_USER_EMAIL, :P_USER_EMAIL);

    -- ACTUAL: numbers changed, so started approvals start over
    IF (v_type = 'ACTUAL') THEN
        -- Every approved step goes back to PENDING (logged first, while still APPROVED)
        INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
        SELECT 'APP.T_F_APPROVAL',
               OBJECT_CONSTRUCT('SCENARIO_ID', SCENARIO_ID, 'PERIOD_KEY', PERIOD_KEY, 'STEP_ORDER', STEP_ORDER), 'UPDATE',
               OBJECT_CONSTRUCT('STEP_STATUS', 'APPROVED'),
               OBJECT_CONSTRUCT('ACTION_TYPE', 'RESET', 'STEP_STATUS', 'PENDING', 'COMMENT', 'Monthly inputs changed'),
               :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
        FROM APP.T_F_APPROVAL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND STEP_STATUS = 'APPROVED';

        UPDATE APP.T_F_APPROVAL
        SET STEP_STATUS = 'PENDING', LAST_ACTION = 'RESET', ACTED_BY = 'SYSTEM', ACTED_AT = CURRENT_TIMESTAMP,
            STEP_COMMENT = 'Monthly inputs changed by ' || :P_USER_EMAIL,
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND STEP_STATUS = 'APPROVED';

        -- The changed employees must be checked again; an old rejection reason no longer applies
        UPDATE APP.T_F_PAYROLL_INPUT
        SET CHECK_STATUS = 'PENDING', CHECK_COMMENT = NULL, CHECKED_BY = NULL,
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY
          AND COALESCE(CHECK_STATUS, 'PENDING') <> 'PENDING'
          AND EMPLOYEE_ID IN (SELECT VALUE:EMPLOYEE_ID::INT FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))
                              WHERE VALUE:CHANGED::BOOLEAN);

        UPDATE APP.T_F_SCENARIO_PERIOD
        SET PERIOD_STATUS = 'OPEN', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND PERIOD_STATUS = 'IN_APPROVAL';
    END IF;

    CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :P_PERIOD_KEY);

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_changed || ' employee(s) updated and payroll recalculated.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
