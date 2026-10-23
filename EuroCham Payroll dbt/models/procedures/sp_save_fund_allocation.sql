-- depends_on: {{ ref('t_d_scenario') }}, {{ ref('t_f_scenario_period') }}, {{ ref('t_d_app_user') }}, {{ ref('t_f_payroll_input') }}, {{ ref('t_d_scenario_employee') }}, {{ ref('t_d_fund') }}, {{ ref('t_f_fund_allocation') }}, {{ ref('t_f_change_log') }}, {{ ref('sp_reset_approvals') }}, {{ ref('sp_calc_period') }}
/* =====================================================================================
   SP_SAVE_FUND_ALLOCATION
   Replaces one employee's fund split for one scenario period.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  V1.5.0: CORE tables moved to APP; role check reads T_D_APP_USER.ROLE_CODE (one role per user).
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   2026-10-19  Fix: the error message for an unknown / inactive fund showed the placeholder {jcode}; it now says
               "fund code".
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Cost Center page: the Working Days panel (ECCC / CCIFC / EU Gate) "Save".

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   P_ALLOCATIONS: [{"fund_code": "ECCC", "days": 15}, {"fund_code": "EU_GATE", "days": 7}]  (days are converted
   to % of the period working days), or [{"fund_code": "ECCC", "share_pct": 100}]
   Shares must total 100% (0.01 tolerance). Rows with a 0 share are not stored.
   Editable: actual month OPEN / IN_APPROVAL (approvals reset for the employee),
   budget / forecast DRAFT. The period is recalculated.
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE {{ app() }}.SP_SAVE_FUND_ALLOCATION(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT, P_EMPLOYEE_ID INT, P_ALLOCATIONS TEXT)
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
    FROM {{ app() }}.T_D_SCENARIO s
    LEFT JOIN {{ app() }}.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID AND x.PERIOD_KEY = :P_PERIOD_KEY
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
    FROM {{ app() }}.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT COUNT(*) INTO :v_in_payroll
    FROM (SELECT EMPLOYEE_ID FROM {{ app() }}.T_F_PAYROLL_INPUT
          WHERE :v_type = 'ACTUAL' AND SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :P_EMPLOYEE_ID
          UNION
          SELECT EMPLOYEE_ID FROM {{ app() }}.T_D_SCENARIO_EMPLOYEE
          WHERE :v_type <> 'ACTUAL' AND SCENARIO_ID = :P_SCENARIO_ID AND EMPLOYEE_ID = :P_EMPLOYEE_ID);
    IF (v_in_payroll = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || P_EMPLOYEE_ID || ' is not part of this payroll.');
    END IF;

    CREATE OR REPLACE TEMPORARY TABLE {{ app() }}.TMP_ALLOC_FUND AS
    SELECT f.VALUE:fund_code::TEXT AS CODE, COALESCE(f.VALUE:share_pct::FLOAT, f.VALUE:days::FLOAT / NULLIF(:v_wd, 0) * 100) AS SHARE_PCT
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_ALLOCATIONS))) f;

    SELECT COUNT(*), COUNT(*) - COUNT(DISTINCT t.CODE), COALESCE(SUM(t.SHARE_PCT), 0),
           COUNT_IF(t.CODE IS NULL OR t.SHARE_PCT IS NULL OR t.SHARE_PCT < 0 OR d.FUND_CODE IS NULL)
      INTO :v_rows, :v_dupes, :v_total, :v_bad
    FROM {{ app() }}.TMP_ALLOC_FUND t
    LEFT JOIN {{ app() }}.T_D_FUND d ON d.FUND_CODE = t.CODE AND d.IS_ACTIVE;
    IF (v_rows = 0 OR v_bad > 0 OR v_dupes > 0) THEN
        DROP TABLE IF EXISTS {{ app() }}.TMP_ALLOC_FUND;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each row needs a known, active fund code and a share >= 0, with no duplicates.');
    END IF;
    IF (ABS(v_total - 100) > 0.01) THEN
        DROP TABLE IF EXISTS {{ app() }}.TMP_ALLOC_FUND;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The shares total ' || ROUND(v_total, 2) || '%. They must total 100%.');
    END IF;

    BEGIN TRANSACTION;

    SELECT TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT('fund_code', FUND_CODE, 'share_pct', SHARE_PCT))) INTO :v_old
    FROM {{ app() }}.T_F_FUND_ALLOCATION WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :P_EMPLOYEE_ID;

    DELETE FROM {{ app() }}.T_F_FUND_ALLOCATION WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :P_EMPLOYEE_ID;

    INSERT INTO {{ app() }}.T_F_FUND_ALLOCATION (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, FUND_CODE, SHARE_PCT, INSERT_BY, UPDATE_BY)
    SELECT :P_SCENARIO_ID, :P_PERIOD_KEY, :P_EMPLOYEE_ID, CODE, SHARE_PCT, :P_USER_EMAIL, :P_USER_EMAIL
    FROM {{ app() }}.TMP_ALLOC_FUND WHERE SHARE_PCT > 0;

    SELECT TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT('fund_code', CODE, 'share_pct', SHARE_PCT))) INTO :v_new
    FROM {{ app() }}.TMP_ALLOC_FUND WHERE SHARE_PCT > 0;
    INSERT INTO {{ app() }}.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_FUND_ALLOCATION', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'PERIOD_KEY', :P_PERIOD_KEY, 'EMPLOYEE_ID', :P_EMPLOYEE_ID), 'UPDATE', PARSE_JSON(:v_old), PARSE_JSON(:v_new), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_type = 'ACTUAL') THEN
        v_ids := '[' || P_EMPLOYEE_ID || ']';
        CALL {{ app() }}.SP_RESET_APPROVALS(:P_USER_EMAIL, :P_SCENARIO_ID, :P_PERIOD_KEY, :v_ids, 'Fund split changed');
    END IF;
    CALL {{ app() }}.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :P_PERIOD_KEY);

    COMMIT;
    DROP TABLE IF EXISTS {{ app() }}.TMP_ALLOC_FUND;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Fund split saved.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        DROP TABLE IF EXISTS {{ app() }}.TMP_ALLOC_FUND;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
