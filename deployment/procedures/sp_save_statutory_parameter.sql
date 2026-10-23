-- depends_on: T_D_APP_USER, T_D_PERIOD, T_D_SCENARIO, T_F_SCENARIO_PERIOD, T_P_STATUTORY_PARAMETER, T_F_CHANGE_LOG, SP_RESET_APPROVALS, SP_CALC_PERIOD
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   SP_SAVE_STATUTORY_PARAMETER
   Changes statutory parameters from the open payroll month onward.
   =====================================================================================

   HISTORY
   -------
   2026-10-20  Initial version.

   CALLED FROM
   -----------
   Monthly Inputs: "Rates & parameters" dialog, Save (parameters part).

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   P_PERIOD_KEY: the open actual month (OPEN or IN_APPROVAL); any other month is refused.
   P_PARAMS: JSON array, e.g. '[{"param_code": "NSSF_BASE_CAP_KHR", "param_value": 1500000}]'.
   Rates as decimals (0.02 = 2%). Values equal to the current one are skipped.
   For each changed parameter, the value in force in P_PERIOD_KEY:
     - started in P_PERIOD_KEY        -> its value is updated (a second change in the same month);
     - started before P_PERIOD_KEY    -> it ends the month before, and a new row starts in
                                         P_PERIOD_KEY (same end month, unit and description).
   Rows starting after P_PERIOD_KEY (entered in Snowflake) are left as they are.
   Recalculated from P_PERIOD_KEY on: the open actual month (approvals reset), draft forecast
   months, draft / rejected budget months.
   Checks: known code, value >= 0, RATE at most 1, no duplicate codes.
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE APP.SP_SAVE_STATUTORY_PARAMETER(P_USER_EMAIL TEXT, P_PERIOD_KEY INT, P_PARAMS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Changes statutory parameters from the open payroll month onward'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed  INT;
    v_status   TEXT;
    v_prev_key INT;
    v_rows     INT;
    v_bad      INT;
    v_dupes    INT;
    v_changed  INT;
    v_recalc   INT;
    v_sid      INT;
    v_pk       INT;
    v_type     TEXT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT MAX(x.PERIOD_STATUS) INTO :v_status
    FROM APP.T_F_SCENARIO_PERIOD x
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID AND s.SCENARIO_TYPE = 'ACTUAL'
    WHERE x.PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_status IS NULL OR (v_status <> 'OPEN' AND v_status <> 'IN_APPROVAL')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || COALESCE(P_PERIOD_KEY::TEXT, '?') || ' is not the open payroll month; parameters can only change from the open month.');
    END IF;

    v_prev_key := TO_NUMBER(TO_CHAR(DATEADD(MONTH, -1, TO_DATE(P_PERIOD_KEY::TEXT, 'YYYYMM')), 'YYYYMM'));

    -- Each sent value with the row in force in P_PERIOD_KEY
    CREATE OR REPLACE TEMPORARY TABLE APP.TMP_STAT_PARAM AS
    SELECT f.VALUE:param_code::TEXT    AS PARAM_CODE,
           f.VALUE:param_value::FLOAT  AS NEW_VALUE,
           sp.PARAM_CODE IS NOT NULL   AS FOUND,
           sp.VALID_FROM_PERIOD_KEY    AS OLD_FROM,
           sp.VALID_TO_PERIOD_KEY      AS OLD_TO,
           sp.PARAM_VALUE              AS OLD_VALUE,
           sp.UNIT, sp.DESCRIPTION, sp.LEGAL_REFERENCE
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_PARAMS))) f
    LEFT JOIN APP.T_P_STATUTORY_PARAMETER sp
           ON sp.PARAM_CODE = f.VALUE:param_code::TEXT
          AND :P_PERIOD_KEY BETWEEN sp.VALID_FROM_PERIOD_KEY AND COALESCE(sp.VALID_TO_PERIOD_KEY, 999912);

    SELECT COUNT(*),
           COUNT_IF(NOT FOUND OR NEW_VALUE IS NULL OR NEW_VALUE < 0 OR (UNIT = 'RATE' AND NEW_VALUE > 1)),
           COUNT(*) - COUNT(DISTINCT PARAM_CODE),
           COUNT_IF(FOUND AND ABS(NEW_VALUE - OLD_VALUE) > 1e-9)
      INTO :v_rows, :v_bad, :v_dupes, :v_changed
    FROM APP.TMP_STAT_PARAM;
    IF (v_rows = 0 OR v_bad > 0 OR v_dupes > 0) THEN
        DROP TABLE IF EXISTS APP.TMP_STAT_PARAM;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each parameter needs a known code and a value of 0 or more (rates at most 100%), with no duplicates.');
    END IF;
    IF (v_changed = 0) THEN
        DROP TABLE IF EXISTS APP.TMP_STAT_PARAM;
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'No changes to save.');
    END IF;
    DELETE FROM APP.TMP_STAT_PARAM WHERE ABS(NEW_VALUE - OLD_VALUE) <= 1e-9;

    -- Scenario periods from P_PERIOD_KEY on that take the new values
    CREATE OR REPLACE TEMPORARY TABLE APP.TMP_STAT_RECALC AS
    SELECT x.SCENARIO_ID, x.PERIOD_KEY, s.SCENARIO_TYPE
    FROM APP.T_F_SCENARIO_PERIOD x
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID
    WHERE x.PERIOD_KEY >= :P_PERIOD_KEY
      AND (   (s.SCENARIO_TYPE = 'ACTUAL' AND x.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'))
           OR (s.SCENARIO_TYPE = 'FORECAST' AND s.SCENARIO_STATUS = 'DRAFT' AND x.PERIOD_STATUS = 'DRAFT')
           OR (s.SCENARIO_TYPE = 'BUDGET' AND s.SCENARIO_STATUS IN ('DRAFT', 'REJECTED') AND x.PERIOD_STATUS = 'DRAFT'));
    SELECT COUNT(*) INTO :v_recalc FROM APP.TMP_STAT_RECALC;

    BEGIN TRANSACTION;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_P_STATUTORY_PARAMETER',
           OBJECT_CONSTRUCT('PARAM_CODE', PARAM_CODE, 'VALID_FROM_PERIOD_KEY', :P_PERIOD_KEY),
           IFF(OLD_FROM = :P_PERIOD_KEY, 'UPDATE', 'INSERT'),
           OBJECT_CONSTRUCT('PARAM_VALUE', OLD_VALUE, 'VALID_FROM_PERIOD_KEY', OLD_FROM),
           OBJECT_CONSTRUCT('PARAM_VALUE', NEW_VALUE, 'VALID_FROM_PERIOD_KEY', :P_PERIOD_KEY),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.TMP_STAT_PARAM;

    -- Started this month: change the value in place
    UPDATE APP.T_P_STATUTORY_PARAMETER sp
    SET PARAM_VALUE = t.NEW_VALUE, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM APP.TMP_STAT_PARAM t
    WHERE sp.PARAM_CODE = t.PARAM_CODE AND sp.VALID_FROM_PERIOD_KEY = :P_PERIOD_KEY
      AND t.OLD_FROM = :P_PERIOD_KEY;

    -- Started earlier: end it last month, new row from this month
    UPDATE APP.T_P_STATUTORY_PARAMETER sp
    SET VALID_TO_PERIOD_KEY = :v_prev_key, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM APP.TMP_STAT_PARAM t
    WHERE sp.PARAM_CODE = t.PARAM_CODE AND sp.VALID_FROM_PERIOD_KEY = t.OLD_FROM
      AND t.OLD_FROM < :P_PERIOD_KEY;

    INSERT INTO APP.T_P_STATUTORY_PARAMETER
        (PARAM_CODE, VALID_FROM_PERIOD_KEY, VALID_TO_PERIOD_KEY, PARAM_VALUE, UNIT, DESCRIPTION, LEGAL_REFERENCE, INSERT_BY, UPDATE_BY)
    SELECT PARAM_CODE, :P_PERIOD_KEY, OLD_TO, NEW_VALUE, UNIT, DESCRIPTION, LEGAL_REFERENCE, :P_USER_EMAIL, :P_USER_EMAIL
    FROM APP.TMP_STAT_PARAM
    WHERE OLD_FROM < :P_PERIOD_KEY;

    LET rs RESULTSET := (SELECT SCENARIO_ID, PERIOD_KEY, SCENARIO_TYPE FROM APP.TMP_STAT_RECALC ORDER BY SCENARIO_ID, PERIOD_KEY);
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        v_sid  := rec.SCENARIO_ID;
        v_pk   := rec.PERIOD_KEY;
        v_type := rec.SCENARIO_TYPE;
        IF (v_type = 'ACTUAL') THEN
            CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_sid, :v_pk, NULL, 'Statutory parameters changed');
        END IF;
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :v_sid, :v_pk);
    END FOR;

    COMMIT;
    DROP TABLE IF EXISTS APP.TMP_STAT_PARAM;
    DROP TABLE IF EXISTS APP.TMP_STAT_RECALC;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_changed || ' parameter(s) saved from ' || P_PERIOD_KEY || '; ' || v_recalc || ' month(s) recalculated.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        DROP TABLE IF EXISTS APP.TMP_STAT_PARAM;
        DROP TABLE IF EXISTS APP.TMP_STAT_RECALC;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
