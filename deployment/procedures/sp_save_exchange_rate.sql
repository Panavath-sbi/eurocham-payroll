-- depends_on: T_D_APP_USER, T_D_PERIOD, T_D_SCENARIO, T_F_SCENARIO_PERIOD, T_F_CHANGE_LOG, SP_RESET_APPROVALS, SP_CALC_PERIOD
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   SP_SAVE_EXCHANGE_RATE
   Saves the NBC and NSSF exchange rates of a month.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  V1.5.0: rates stored on APP.T_D_PERIOD (FX_RATE_NBC, FX_RATE_NSSF) instead of
               T_P_FX_RATE; one role per user.
   2026-10-02  Fix: v_old_nssf was declared twice.
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Monthly Inputs: Exchange Rates panel "Save".

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   Stores the published rates on the month in APP.T_D_PERIOD. If the month is the open payroll
   month, the applied rates change too: approvals reset and the month is recalculated.
   A finalized month is refused. Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE {{ schema_app }}.SP_SAVE_EXCHANGE_RATE(P_USER_EMAIL TEXT, P_PERIOD_KEY INT, P_FX_RATE_NBC FLOAT, P_FX_RATE_NSSF FLOAT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Saves the NBC and NSSF exchange rates of a month'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_allowed  INT;
    v_in_cal   INT;
    v_actual   INT;
    v_status   TEXT;
    v_old_nbc  FLOAT;
    v_old_nssf FLOAT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM {{ schema_app }}.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    IF (P_FX_RATE_NBC IS NULL OR P_FX_RATE_NSSF IS NULL OR P_FX_RATE_NBC <= 0 OR P_FX_RATE_NSSF <= 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Both rates must be greater than 0.');
    END IF;
    SELECT COUNT(*) INTO :v_in_cal FROM {{ schema_app }}.T_D_PERIOD WHERE PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_in_cal = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || P_PERIOD_KEY || ' is not in the calendar.');
    END IF;

    SELECT MAX(s.SCENARIO_ID), MAX(x.PERIOD_STATUS) INTO :v_actual, :v_status
    FROM {{ schema_app }}.T_D_SCENARIO s
    LEFT JOIN {{ schema_app }}.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID AND x.PERIOD_KEY = :P_PERIOD_KEY
    WHERE s.SCENARIO_TYPE = 'ACTUAL';
    IF (v_status = 'FINALIZED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || P_PERIOD_KEY || ' is finalized; its rates cannot change.');
    END IF;

    SELECT MAX(FX_RATE_NBC), MAX(FX_RATE_NSSF) INTO :v_old_nbc, :v_old_nssf
    FROM {{ schema_app }}.T_D_PERIOD WHERE PERIOD_KEY = :P_PERIOD_KEY;

    BEGIN TRANSACTION;

    UPDATE {{ schema_app }}.T_D_PERIOD
    SET FX_RATE_NBC = :P_FX_RATE_NBC, FX_RATE_NSSF = :P_FX_RATE_NSSF,
        UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHERE PERIOD_KEY = :P_PERIOD_KEY;

    INSERT INTO {{ schema_app }}.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_PERIOD', OBJECT_CONSTRUCT('PERIOD_KEY', :P_PERIOD_KEY), 'UPDATE', OBJECT_CONSTRUCT('FX_RATE_NBC', :v_old_nbc, 'FX_RATE_NSSF', :v_old_nssf), OBJECT_CONSTRUCT('FX_RATE_NBC', :P_FX_RATE_NBC, 'FX_RATE_NSSF', :P_FX_RATE_NSSF), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_status = 'OPEN' OR v_status = 'IN_APPROVAL') THEN
        UPDATE {{ schema_app }}.T_F_SCENARIO_PERIOD
        SET FX_RATE_NBC = :P_FX_RATE_NBC, FX_RATE_NSSF = :P_FX_RATE_NSSF, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :v_actual AND PERIOD_KEY = :P_PERIOD_KEY;
        CALL {{ schema_app }}.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_actual, :P_PERIOD_KEY, NULL, 'Exchange rates changed');
        CALL {{ schema_app }}.SP_CALC_PERIOD(:P_USER_EMAIL, :v_actual, :P_PERIOD_KEY);
    END IF;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Exchange rates saved for ' || P_PERIOD_KEY ||
                            IFF(v_status = 'OPEN' OR v_status = 'IN_APPROVAL', '; payroll recalculated.', '.'));
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
