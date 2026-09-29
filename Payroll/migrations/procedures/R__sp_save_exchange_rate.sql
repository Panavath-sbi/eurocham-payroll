/* =====================================================================================
   R - SP_SAVE_EXCHANGE_RATE
   Saves the NBC and NSSF exchange rates of a month.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   Monthly Inputs: Exchange Rates panel "Save".

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* Stores the published rates in CORE.T_P_FX_RATE. If the month is the open payroll
   month, the applied rates change too: approvals reset and the month is recalculated.
   A finalized month is refused. Role: PAYROLL_ADMIN. */
USE DATABASE PAYROLL_DB;
   
CREATE OR REPLACE PROCEDURE APP.SP_SAVE_EXCHANGE_RATE(P_USER_EMAIL TEXT, P_PERIOD_KEY INT, P_FX_RATE_NBC FLOAT, P_FX_RATE_NSSF FLOAT)
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
    FROM APP.T_D_APP_USER u
    JOIN APP.T_D_APP_USER_ROLE r ON r.USER_EMAIL = u.USER_EMAIL
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE AND r.ROLE_CODE IN ('PAYROLL_ADMIN');
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only a payroll admin can do this.');
    END IF;

    IF (P_FX_RATE_NBC IS NULL OR P_FX_RATE_NSSF IS NULL OR P_FX_RATE_NBC <= 0 OR P_FX_RATE_NSSF <= 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Both rates must be greater than 0.');
    END IF;
    SELECT COUNT(*) INTO :v_in_cal FROM CORE.T_D_PERIOD WHERE PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_in_cal = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || P_PERIOD_KEY || ' is not in the calendar.');
    END IF;

    SELECT MAX(s.SCENARIO_ID), MAX(x.PERIOD_STATUS) INTO :v_actual, :v_status
    FROM APP.T_D_SCENARIO s
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID AND x.PERIOD_KEY = :P_PERIOD_KEY
    WHERE s.SCENARIO_TYPE = 'ACTUAL';
    IF (v_status = 'FINALIZED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || P_PERIOD_KEY || ' is finalized; its rates cannot change.');
    END IF;

    SELECT MAX(IFF(RATE_TYPE = 'NBC', EXCHANGE_RATE, NULL)), MAX(IFF(RATE_TYPE = 'NSSF', EXCHANGE_RATE, NULL))
      INTO :v_old_nbc, :v_old_nssf
    FROM CORE.T_P_FX_RATE
    WHERE PERIOD_KEY = :P_PERIOD_KEY AND FROM_CURRENCY = 'USD' AND TO_CURRENCY = 'KHR';

    BEGIN TRANSACTION;

    MERGE INTO CORE.T_P_FX_RATE t
    USING (SELECT 'NBC' AS RATE_TYPE, :P_FX_RATE_NBC AS RATE UNION ALL SELECT 'NSSF', :P_FX_RATE_NSSF) s
       ON t.PERIOD_KEY = :P_PERIOD_KEY AND t.RATE_TYPE = s.RATE_TYPE AND t.FROM_CURRENCY = 'USD' AND t.TO_CURRENCY = 'KHR'
    WHEN MATCHED THEN UPDATE SET EXCHANGE_RATE = s.RATE, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHEN NOT MATCHED THEN INSERT (PERIOD_KEY, RATE_TYPE, FROM_CURRENCY, TO_CURRENCY, EXCHANGE_RATE, INSERT_BY, UPDATE_BY)
        VALUES (:P_PERIOD_KEY, s.RATE_TYPE, 'USD', 'KHR', s.RATE, :P_USER_EMAIL, :P_USER_EMAIL);

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'CORE.T_P_FX_RATE', OBJECT_CONSTRUCT('PERIOD_KEY', :P_PERIOD_KEY), 'UPDATE', OBJECT_CONSTRUCT('NBC', :v_old_nbc, 'NSSF', :v_old_nssf), OBJECT_CONSTRUCT('NBC', :P_FX_RATE_NBC, 'NSSF', :P_FX_RATE_NSSF), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_status = 'OPEN' OR v_status = 'IN_APPROVAL') THEN
        UPDATE APP.T_F_SCENARIO_PERIOD
        SET FX_RATE_NBC = :P_FX_RATE_NBC, FX_RATE_NSSF = :P_FX_RATE_NSSF, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :v_actual AND PERIOD_KEY = :P_PERIOD_KEY;
        CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_actual, :P_PERIOD_KEY, NULL, 'Exchange rates changed');
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :v_actual, :P_PERIOD_KEY);
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
