-- depends_on: {{ ref('t_d_app_user') }}, {{ ref('t_f_payslip_run') }}, {{ ref('t_f_change_log') }}
/* =====================================================================================
   SP_FINISH_PAYSLIP_RUN
   Logs the end of a month's payslip run: SENT, or FAILED with the error.
   =====================================================================================

   HISTORY
   -------
   2026-10-21  Initial version.

   CALLED FROM
   -----------
   The payslip flow (Power Automate): SENT after the last email, FAILED from the flow's
   error branch when sending stopped part way. P_USER_EMAIL is the flow's system user
   (payslip-flow@system).

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL, checks that it is an active app user, writes UPDATE_BY and
     T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   P_PERIOD_KEY: the month (YYYYMM). P_RUN_STATUS: 'SENT' or 'FAILED'.
   P_MESSAGE (optional): the error reported by the flow; stored for FAILED only.
   Rules: the month's run is SENDING (started by SP_START_PAYSLIP_RUN, not finished yet).
   A FAILED month is not retried by the flow: an admin deletes the row (the whole month
   is sent again) or sets it to SENT by hand.
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE {{ app() }}.SP_FINISH_PAYSLIP_RUN(P_USER_EMAIL TEXT, P_PERIOD_KEY INT, P_RUN_STATUS TEXT, P_MESSAGE TEXT DEFAULT NULL)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Logs the end of a month''s payslip run (SENT or FAILED)'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_allowed INT;
    v_status  TEXT;
    v_run     TEXT;
    v_message TEXT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM {{ app() }}.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    v_status := UPPER(TRIM(P_RUN_STATUS));
    IF (v_status IS NULL OR (v_status <> 'SENT' AND v_status <> 'FAILED')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Run status must be SENT or FAILED.');
    END IF;
    v_message := NULL;
    IF (v_status = 'FAILED') THEN
        v_message := COALESCE(NULLIF(TRIM(P_MESSAGE), ''), 'No error message from the flow.');
    END IF;

    SELECT MAX(RUN_STATUS) INTO :v_run
    FROM {{ app() }}.T_F_PAYSLIP_RUN WHERE PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_run IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No payslip run of ' || P_PERIOD_KEY || ' was started.');
    END IF;
    IF (v_run <> 'SENDING') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The payslip run of ' || P_PERIOD_KEY || ' already ended (' || v_run || ').');
    END IF;

    BEGIN TRANSACTION;

    UPDATE {{ app() }}.T_F_PAYSLIP_RUN
    SET RUN_STATUS = :v_status, FINISHED_AT = CURRENT_TIMESTAMP, RUN_MESSAGE = :v_message,
        UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHERE PERIOD_KEY = :P_PERIOD_KEY;

    INSERT INTO {{ app() }}.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_PAYSLIP_RUN',
           OBJECT_CONSTRUCT('PERIOD_KEY', :P_PERIOD_KEY),
           'UPDATE',
           OBJECT_CONSTRUCT('RUN_STATUS', 'SENDING'),
           OBJECT_CONSTRUCT('RUN_STATUS', :v_status, 'RUN_MESSAGE', :v_message),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Payslip run of ' || P_PERIOD_KEY || ' logged as ' || v_status || '.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
