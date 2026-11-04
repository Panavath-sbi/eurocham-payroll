CREATE OR REPLACE PROCEDURE APP.SP_CALCULATE_PAYROLL(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Recalculates one or all editable periods of a scenario'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_type    TEXT;
    v_allowed INT;
    v_pk      INT;
    v_done    INT DEFAULT 0;
BEGIN
    SELECT MAX(SCENARIO_TYPE) INTO :v_type FROM APP.T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' does not exist.');
    END IF;

    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    BEGIN TRANSACTION;

    LET rs RESULTSET := (
        SELECT PERIOD_KEY
        FROM APP.T_F_SCENARIO_PERIOD
        WHERE SCENARIO_ID = :P_SCENARIO_ID
          AND (:P_PERIOD_KEY IS NULL OR PERIOD_KEY = :P_PERIOD_KEY)
          AND PERIOD_STATUS NOT IN ('FINALIZED', 'LOCKED')
        ORDER BY PERIOD_KEY);
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        v_pk := rec.PERIOD_KEY;
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :v_pk);
        v_done := v_done + 1;
    END FOR;

    COMMIT;

    IF (v_done = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Nothing calculated: the period does not exist or is finalized / locked.');
    END IF;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_done || ' period(s) calculated.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
