/* =====================================================================================
   R - SP_SAVE_PAYROLL_ADJUSTMENT
   Adds, changes or removes a one-off adjustment in the open payroll month.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   Monthly Inputs: corrections for closed months (and other one-off amounts).

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* New:    P_ADJUSTMENT_ID = NULL, P_AMOUNT_USD <> 0, P_REASON required.
   Change: P_ADJUSTMENT_ID given, P_AMOUNT_USD <> 0.
   Remove: P_ADJUSTMENT_ID given, P_AMOUNT_USD = NULL.
   P_REFERENCE_PERIOD_KEY: the finalized month being corrected (optional).
   Adjustments are taxable earnings, paid as one ADJUSTMENT line. The open month's
   approvals reset for the employee and it is recalculated. Role: PAYROLL_ADMIN. */
USE DATABASE PAYROLL_DB;
   
CREATE OR REPLACE PROCEDURE APP.SP_SAVE_PAYROLL_ADJUSTMENT(P_USER_EMAIL TEXT, P_ADJUSTMENT_ID INT, P_PERIOD_KEY INT,
                                                           P_EMPLOYEE_ID INT, P_AMOUNT_USD FLOAT,
                                                           P_REFERENCE_PERIOD_KEY INT, P_REASON TEXT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Adds, changes or removes a payroll adjustment'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_allowed  INT;
    v_actual   INT;
    v_status   TEXT;
    v_in       INT;
    v_ref_stat TEXT;
    v_found    INT;
    v_emp      INT;
    v_old      TEXT;
    v_action   TEXT;
    v_ids      TEXT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    JOIN APP.T_D_APP_USER_ROLE r ON r.USER_EMAIL = u.USER_EMAIL
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE AND r.ROLE_CODE IN ('PAYROLL_ADMIN');
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only a payroll admin can do this.');
    END IF;

    SELECT MAX(s.SCENARIO_ID), MAX(x.PERIOD_STATUS) INTO :v_actual, :v_status
    FROM APP.T_D_SCENARIO s
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID AND x.PERIOD_KEY = :P_PERIOD_KEY
    WHERE s.SCENARIO_TYPE = 'ACTUAL';
    IF (v_status IS NULL OR (v_status <> 'OPEN' AND v_status <> 'IN_APPROVAL')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Adjustments can only be added to the open payroll month.');
    END IF;

    v_emp := P_EMPLOYEE_ID;
    IF (P_ADJUSTMENT_ID IS NOT NULL) THEN
        SELECT COUNT(*), MAX(EMPLOYEE_ID) INTO :v_found, :v_emp
        FROM APP.T_F_PAYROLL_ADJUSTMENT
        WHERE ADJUSTMENT_ID = :P_ADJUSTMENT_ID AND SCENARIO_ID = :v_actual AND PERIOD_KEY = :P_PERIOD_KEY;
        IF (v_found = 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Adjustment ' || P_ADJUSTMENT_ID || ' is not in month ' || P_PERIOD_KEY || '.');
        END IF;
        SELECT TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL(*)) INTO :v_old
        FROM APP.T_F_PAYROLL_ADJUSTMENT WHERE ADJUSTMENT_ID = :P_ADJUSTMENT_ID;
    END IF;

    IF (P_ADJUSTMENT_ID IS NULL OR P_AMOUNT_USD IS NOT NULL) THEN
        IF (P_AMOUNT_USD IS NULL OR P_AMOUNT_USD = 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The amount must not be 0.');
        END IF;
        IF (P_ADJUSTMENT_ID IS NULL AND COALESCE(TRIM(P_REASON), '') = '') THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A reason is required.');
        END IF;
        SELECT COUNT(*) INTO :v_in FROM APP.T_F_PAYROLL_INPUT
        WHERE SCENARIO_ID = :v_actual AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :v_emp AND INCLUDE_IN_PAYROLL;
        IF (v_in = 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The employee is not in this payroll month.');
        END IF;
        IF (P_REFERENCE_PERIOD_KEY IS NOT NULL) THEN
            SELECT MAX(PERIOD_STATUS) INTO :v_ref_stat FROM APP.T_F_SCENARIO_PERIOD
            WHERE SCENARIO_ID = :v_actual AND PERIOD_KEY = :P_REFERENCE_PERIOD_KEY;
            IF (v_ref_stat IS NULL OR v_ref_stat <> 'FINALIZED' OR P_REFERENCE_PERIOD_KEY >= P_PERIOD_KEY) THEN
                RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The reference month must be an earlier, finalized month.');
            END IF;
        END IF;
    END IF;

    BEGIN TRANSACTION;

    IF (P_ADJUSTMENT_ID IS NULL) THEN
        INSERT INTO APP.T_F_PAYROLL_ADJUSTMENT
            (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, PAY_COMPONENT_CODE, AMOUNT_USD, REFERENCE_PERIOD_KEY, REASON, INSERT_BY, UPDATE_BY)
        SELECT :v_actual, :P_PERIOD_KEY, :v_emp, 'ADJUSTMENT', :P_AMOUNT_USD, :P_REFERENCE_PERIOD_KEY, :P_REASON,
               :P_USER_EMAIL, :P_USER_EMAIL;
        v_action := 'INSERT';
    ELSEIF (P_AMOUNT_USD IS NULL) THEN
        DELETE FROM APP.T_F_PAYROLL_ADJUSTMENT WHERE ADJUSTMENT_ID = :P_ADJUSTMENT_ID;
        v_action := 'DELETE';
    ELSE
        UPDATE APP.T_F_PAYROLL_ADJUSTMENT
        SET AMOUNT_USD = :P_AMOUNT_USD,
            REFERENCE_PERIOD_KEY = COALESCE(:P_REFERENCE_PERIOD_KEY, REFERENCE_PERIOD_KEY),
            REASON = COALESCE(NULLIF(TRIM(:P_REASON), ''), REASON),
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE ADJUSTMENT_ID = :P_ADJUSTMENT_ID;
        v_action := 'UPDATE';
    END IF;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_PAYROLL_ADJUSTMENT',
           OBJECT_CONSTRUCT('ADJUSTMENT_ID', :P_ADJUSTMENT_ID, 'PERIOD_KEY', :P_PERIOD_KEY, 'EMPLOYEE_ID', :v_emp),
           :v_action, PARSE_JSON(:v_old),
           OBJECT_CONSTRUCT('AMOUNT_USD', :P_AMOUNT_USD, 'REFERENCE_PERIOD_KEY', :P_REFERENCE_PERIOD_KEY, 'REASON', :P_REASON),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    v_ids := '[' || v_emp || ']';
    CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_actual, :P_PERIOD_KEY, :v_ids, 'Adjustment changed');
    CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :v_actual, :P_PERIOD_KEY);

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Adjustment ' || IFF(v_action = 'INSERT', 'added', IFF(v_action = 'DELETE', 'removed', 'updated')) || '.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
