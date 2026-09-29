/* =====================================================================================
   R - SP_DELETE_SCENARIO
   Deletes a budget or forecast scenario and everything in it.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   Budget Input page: "Delete Budget"; Forecast page: delete a forecast.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* Refused for the ACTUAL scenario, a scenario IN_APPROVAL and the official budget.
   Deletes the scenario's pay lines, allocations, inputs, adjustments, employee terms,
   planned hires, approval history and months, then the scenario itself.
   Roles: PAYROLL_ADMIN or BUDGET_EDITOR. */
USE DATABASE PAYROLL_DB;
   
CREATE OR REPLACE PROCEDURE APP.SP_DELETE_SCENARIO(P_USER_EMAIL TEXT, P_SCENARIO_ID INT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Deletes a budget or forecast scenario'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_allowed  INT;
    v_type     TEXT;
    v_status   TEXT;
    v_official BOOLEAN;
    v_name     TEXT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    JOIN APP.T_D_APP_USER_ROLE r ON r.USER_EMAIL = u.USER_EMAIL
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE AND r.ROLE_CODE IN ('PAYROLL_ADMIN', 'BUDGET_EDITOR');
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not allowed to manage budgets and forecasts.');
    END IF;

    SELECT MAX(SCENARIO_TYPE), MAX(SCENARIO_STATUS), MAX(IS_OFFICIAL), MAX(SCENARIO_NAME)
      INTO :v_type, :v_status, :v_official, :v_name
    FROM APP.T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' does not exist.');
    END IF;
    IF (v_type = 'ACTUAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The actual payroll cannot be deleted.');
    END IF;
    IF (v_status = 'IN_APPROVAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The scenario is in approval. Reject it first.');
    END IF;
    IF (v_official) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This is the official budget and cannot be deleted.');
    END IF;

    BEGIN TRANSACTION;

    DELETE FROM APP.T_F_APPROVAL_EMPLOYEE_CHECK
    WHERE REQUEST_ID IN (SELECT REQUEST_ID FROM APP.T_F_APPROVAL_REQUEST WHERE SCENARIO_ID = :P_SCENARIO_ID);
    DELETE FROM APP.T_F_APPROVAL_ACTION
    WHERE REQUEST_ID IN (SELECT REQUEST_ID FROM APP.T_F_APPROVAL_REQUEST WHERE SCENARIO_ID = :P_SCENARIO_ID);
    DELETE FROM APP.T_F_APPROVAL_REQUEST       WHERE SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM CORE.T_F_PAYROLL_LINE          WHERE SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM CORE.T_F_COST_ALLOCATION       WHERE SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM APP.T_F_FUND_ALLOCATION        WHERE SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM APP.T_F_DEPARTMENT_ALLOCATION  WHERE SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM APP.T_F_PAYROLL_ADJUSTMENT     WHERE SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM APP.T_F_PAYROLL_INPUT          WHERE SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM APP.T_D_SCENARIO_EMPLOYEE      WHERE SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM APP.T_F_SCENARIO_PERIOD        WHERE SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM APP.T_D_EMPLOYEE               WHERE IS_PLANNED AND PLANNED_SCENARIO_ID = :P_SCENARIO_ID;

    UPDATE APP.T_D_SCENARIO SET BASE_SCENARIO_ID = NULL, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHERE BASE_SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM APP.T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_SCENARIO', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID), 'DELETE', OBJECT_CONSTRUCT('SCENARIO_NAME', :v_name, 'SCENARIO_TYPE', :v_type, 'SCENARIO_STATUS', :v_status), NULL, :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Scenario ' || v_name || ' deleted.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
