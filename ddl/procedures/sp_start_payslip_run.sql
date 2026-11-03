CREATE OR REPLACE PROCEDURE APP.SP_START_PAYSLIP_RUN(P_USER_EMAIL TEXT, P_PERIOD_KEY INT, P_EMPLOYEE_COUNT INT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Logs that a month''s payslips start going out (SENDING)'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed INT;
    v_run     TEXT;
    v_action  TEXT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    IF (P_EMPLOYEE_COUNT IS NULL OR P_EMPLOYEE_COUNT <= 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No payslips were prepared for ' || P_PERIOD_KEY || '.');
    END IF;

    SELECT MAX(RUN_STATUS) INTO :v_run
    FROM APP.T_F_PAYSLIP_RUN WHERE PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_run IS NOT NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Payslips of ' || P_PERIOD_KEY || ' were already sent or are being sent (' || v_run || ').');
    END IF;

    SELECT MAX(ACTION) INTO :v_action
    FROM RPT.V_F_PAYSLIP_DUE WHERE PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_action IS NULL OR v_action <> 'SEND') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Payslips of ' || P_PERIOD_KEY || ' are not due today (' || COALESCE(v_action, 'month not in the payslip schedule') || ').');
    END IF;

    BEGIN TRANSACTION;

    INSERT INTO APP.T_F_PAYSLIP_RUN (PERIOD_KEY, RUN_STATUS, EMPLOYEE_COUNT, STARTED_AT, INSERT_BY, UPDATE_BY)
    VALUES (:P_PERIOD_KEY, 'SENDING', :P_EMPLOYEE_COUNT, CURRENT_TIMESTAMP, :P_USER_EMAIL, :P_USER_EMAIL);

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_PAYSLIP_RUN',
           OBJECT_CONSTRUCT('PERIOD_KEY', :P_PERIOD_KEY),
           'INSERT',
           NULL,
           OBJECT_CONSTRUCT('RUN_STATUS', 'SENDING', 'EMPLOYEE_COUNT', :P_EMPLOYEE_COUNT),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Sending ' || P_EMPLOYEE_COUNT || ' payslips of ' || P_PERIOD_KEY || '.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
