CREATE OR REPLACE PROCEDURE APP.SP_FINALIZE_PAYROLL(P_USER_EMAIL TEXT, P_PERIOD_KEY INT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Finalizes (locks) a fully approved actual payroll month'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed INT;
    v_scen    INT;
    v_status  TEXT;
    v_steps   INT;
    v_pending INT;
    v_lines   INT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT MAX(SCENARIO_ID) INTO :v_scen FROM APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'ACTUAL';

    SELECT MAX(PERIOD_STATUS) INTO :v_status
    FROM APP.T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_status IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' does not exist.');
    END IF;
    IF (v_status = 'FINALIZED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' is already finalized.');
    END IF;

    SELECT COUNT(*), COUNT_IF(STEP_STATUS <> 'APPROVED') INTO :v_steps, :v_pending
    FROM RPT.V_F_APPROVAL_PROGRESS WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_steps = 0 OR v_pending > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_pending || ' approval step(s) are not approved yet.');
    END IF;

    SELECT COUNT(*) INTO :v_lines
    FROM APP.T_F_PAYROLL_LINE WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_lines = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' has no calculated payroll.');
    END IF;

    BEGIN TRANSACTION;

    UPDATE APP.T_F_SCENARIO_PERIOD
    SET PERIOD_STATUS = 'FINALIZED', FINALIZED_AT = CURRENT_TIMESTAMP, FINALIZED_BY = :P_USER_EMAIL,
        UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHERE SCENARIO_ID = :v_scen AND PERIOD_KEY = :P_PERIOD_KEY;


    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_SCENARIO_PERIOD',
           OBJECT_CONSTRUCT('SCENARIO_ID', :v_scen, 'PERIOD_KEY', :P_PERIOD_KEY),
           'UPDATE',
           OBJECT_CONSTRUCT('PERIOD_STATUS', :v_status),
           OBJECT_CONSTRUCT('PERIOD_STATUS', 'FINALIZED'),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Payroll ' || P_PERIOD_KEY || ' finalized.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
