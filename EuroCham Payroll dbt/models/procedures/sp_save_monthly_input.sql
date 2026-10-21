-- depends_on: {{ ref('t_d_scenario') }}, {{ ref('t_f_scenario_period') }}, {{ ref('t_d_app_user') }}, {{ ref('t_f_payroll_input') }}, {{ ref('t_d_employee') }}, {{ ref('t_d_employee_contract') }}, {{ ref('t_d_scenario_employee') }}, {{ ref('t_f_change_log') }}, {{ ref('t_f_approval') }}, {{ ref('sp_calc_period') }}
/* =====================================================================================
   SP_SAVE_MONTHLY_INPUT
   Saves monthly inputs for one scenario period.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-09-29  Fix: COMMENT moved before EXECUTE AS (Snowflake clause order).
   2026-10-02  Approval reset uses APP.T_F_APPROVAL_STEP_STATE (no more action log) and is
               written to T_F_CHANGE_LOG.
   2026-10-02  V1.5.0: approvals in APP.T_F_APPROVAL; changed employees' checks (on their
               input row) go back to PENDING with the comment cleared; CORE -> APP;
               one role per user.
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CONVENTIONS
   -----------
   * Every public procedure takes P_USER_EMAIL (the Power Apps user, passed by Power
     Automate), checks the user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Every public procedure returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
     Power Automate returns it to the app as is.
   * Validations run before any write. Writes run in one transaction; any error rolls
     the whole call back.
   * Currency rule: earnings are calculated in USD and converted to KHR at the NBC rate
     (from the unrounded USD). NSSF and salary tax are calculated in KHR and converted
     back to USD, rounded to the cent. Net pay USD = gross USD - deductions USD.

   ===================================================================================== */
/* =====================================================================================
   SP_SAVE_MONTHLY_INPUT (public) - Monthly Inputs grid, Budget / Forecast "Show Details"
   P_INPUTS is a JSON array, one object per employee. Keys left out keep their current
   value; for the two overrides, an explicit null clears the override:
   [{"employee_id": 7, "absence_days": 2, "overtime_days": 0, "outstanding_days": 0,
     "bonus_usd": 0, "include_in_payroll": true, "notes": "...",
     "salary_override_usd": null, "fringe_benefit_override_usd": null}]
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ACTUAL: period must be OPEN or IN_APPROVAL; overrides are not allowed; a change resets
   started approvals (approved steps go back to PENDING + the changed employees' checks).
   BUDGET / FORECAST: scenario must be DRAFT or REJECTED and the period DRAFT.
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE SP_SAVE_MONTHLY_INPUT(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT, P_INPUTS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Saves monthly inputs for one scenario period'
EXECUTE AS OWNER
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
BEGIN
    -- Scenario and period
    SELECT MAX(s.SCENARIO_TYPE), MAX(s.SCENARIO_STATUS), MAX(x.PERIOD_STATUS), MAX(x.WORKING_DAYS)
      INTO :v_type, :v_scen_status, :v_status, :v_wd
    FROM T_D_SCENARIO s
    LEFT JOIN T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID AND x.PERIOD_KEY = :P_PERIOD_KEY
    WHERE s.SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' does not exist.');
    END IF;
    IF (v_status IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' does not exist in this scenario.');
    END IF;

    -- Any active app user may do this (roles only limit approvals)
    SELECT COUNT(*) INTO :v_allowed
    FROM T_D_APP_USER u
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

    -- Stage the incoming rows merged with the current values (DDL: before the transaction)
    CREATE OR REPLACE TEMPORARY TABLE TMP_PAYROLL_INPUT AS
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
    LEFT JOIN T_F_PAYROLL_INPUT t
           ON t.SCENARIO_ID = :P_SCENARIO_ID AND t.PERIOD_KEY = :P_PERIOD_KEY
          AND t.EMPLOYEE_ID = j.VALUE:employee_id::INT;

    ALTER TABLE TMP_PAYROLL_INPUT ADD COLUMN NEW_VALUES VARIANT;
    UPDATE TMP_PAYROLL_INPUT SET NEW_VALUES = OBJECT_CONSTRUCT_KEEP_NULL(
        'INCLUDE_IN_PAYROLL', INCLUDE_IN_PAYROLL, 'ABSENCE_DAYS', ABSENCE_DAYS,
        'OVERTIME_DAYS', OVERTIME_DAYS, 'OUTSTANDING_DAYS', OUTSTANDING_DAYS,
        'BONUS_USD', BONUS_USD, 'SALARY_OVERRIDE_USD', SALARY_OVERRIDE_USD,
        'FRINGE_BENEFIT_OVERRIDE_USD', FRINGE_BENEFIT_OVERRIDE_USD, 'NOTES', NOTES);

    -- Validations
    SELECT COUNT(*),
           COUNT_IF(EMPLOYEE_ID IS NULL OR ABSENCE_DAYS < 0 OR OVERTIME_DAYS < 0 OR OUTSTANDING_DAYS < 0
                    OR BONUS_USD < 0 OR ABSENCE_DAYS > :v_wd
                    OR COALESCE(SALARY_OVERRIDE_USD, 0) < 0 OR COALESCE(FRINGE_BENEFIT_OVERRIDE_USD, 0) < 0),
           COUNT(*) - COUNT(DISTINCT EMPLOYEE_ID),
           COUNT_IF(SALARY_OVERRIDE_USD IS NOT NULL OR FRINGE_BENEFIT_OVERRIDE_USD IS NOT NULL)
      INTO :v_rows, :v_bad, :v_dupes, :v_overrides
    FROM TMP_PAYROLL_INPUT;

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
    FROM TMP_PAYROLL_INPUT x
    WHERE (:v_type = 'ACTUAL' AND NOT EXISTS (
              SELECT 1 FROM T_D_EMPLOYEE e
              JOIN T_D_EMPLOYEE_CONTRACT c ON c.EMPLOYEE_ID = e.EMPLOYEE_ID
              WHERE e.EMPLOYEE_ID = x.EMPLOYEE_ID AND e.IS_ACTIVE AND NOT e.IS_PLANNED
                AND :P_PERIOD_KEY BETWEEN c.VALID_FROM_PERIOD_KEY AND COALESCE(c.VALID_TO_PERIOD_KEY, 999912)))
       OR (:v_type <> 'ACTUAL' AND NOT EXISTS (
              SELECT 1 FROM T_D_SCENARIO_EMPLOYEE se
              WHERE se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = x.EMPLOYEE_ID));
    IF (v_unknown > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_unknown || ' employee(s) are not part of this payroll.');
    END IF;

    SELECT COUNT_IF(NOT ROW_EXISTS OR OLD_VALUES <> NEW_VALUES) INTO :v_changed FROM TMP_PAYROLL_INPUT;
    IF (v_changed = 0) THEN
        DROP TABLE IF EXISTS TMP_PAYROLL_INPUT;
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'No changes to save.');
    END IF;

    BEGIN TRANSACTION;

    -- Audit first (old vs new), only for rows that actually change
    INSERT INTO T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_PAYROLL_INPUT',
           OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'PERIOD_KEY', :P_PERIOD_KEY, 'EMPLOYEE_ID', EMPLOYEE_ID),
           IFF(ROW_EXISTS, 'UPDATE', 'INSERT'),
           IFF(ROW_EXISTS, OLD_VALUES, NULL),
           NEW_VALUES,
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TMP_PAYROLL_INPUT
    WHERE NOT ROW_EXISTS OR OLD_VALUES <> NEW_VALUES;

    MERGE INTO T_F_PAYROLL_INPUT t
    USING (SELECT * FROM TMP_PAYROLL_INPUT WHERE NOT ROW_EXISTS OR OLD_VALUES <> NEW_VALUES) s
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
        INSERT INTO T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
        SELECT 'APP.T_F_APPROVAL',
               OBJECT_CONSTRUCT('SCENARIO_ID', SCENARIO_ID, 'PERIOD_KEY', PERIOD_KEY, 'STEP_ORDER', STEP_ORDER), 'UPDATE',
               OBJECT_CONSTRUCT('STEP_STATUS', 'APPROVED'),
               OBJECT_CONSTRUCT('ACTION_TYPE', 'RESET', 'STEP_STATUS', 'PENDING', 'COMMENT', 'Monthly inputs changed'),
               :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
        FROM T_F_APPROVAL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND STEP_STATUS = 'APPROVED';

        UPDATE T_F_APPROVAL
        SET STEP_STATUS = 'PENDING', LAST_ACTION = 'RESET', ACTED_BY = 'SYSTEM', ACTED_AT = CURRENT_TIMESTAMP,
            STEP_COMMENT = 'Monthly inputs changed by ' || :P_USER_EMAIL,
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND STEP_STATUS = 'APPROVED';

        -- The changed employees must be checked again; an old rejection reason no longer applies
        UPDATE T_F_PAYROLL_INPUT
        SET CHECK_STATUS = 'PENDING', CHECK_COMMENT = NULL, CHECKED_BY = NULL,
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY
          AND COALESCE(CHECK_STATUS, 'PENDING') <> 'PENDING'
          AND EMPLOYEE_ID IN (SELECT EMPLOYEE_ID FROM TMP_PAYROLL_INPUT
                              WHERE NOT ROW_EXISTS OR OLD_VALUES <> NEW_VALUES);

        UPDATE T_F_SCENARIO_PERIOD
        SET PERIOD_STATUS = 'OPEN', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND PERIOD_STATUS = 'IN_APPROVAL';
    END IF;

    CALL SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :P_PERIOD_KEY);

    COMMIT;
    DROP TABLE IF EXISTS TMP_PAYROLL_INPUT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_changed || ' employee(s) updated and payroll recalculated.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        DROP TABLE IF EXISTS TMP_PAYROLL_INPUT;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
