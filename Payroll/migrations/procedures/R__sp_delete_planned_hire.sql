/* =====================================================================================
   R - SP_DELETE_PLANNED_HIRE
   Removes a planned hire from its budget or forecast scenario.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  V1.5.0: no cost-allocation table to clean any more (it is a view); CORE -> APP;
               one role per user.
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   Budget Input and Forecast pages: delete a new hire.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.
   ===================================================================================== */

/* Only planned hires (IS_PLANNED = TRUE) of this scenario can be removed; actual employees
   never can. All the hire's rows in the scenario are deleted, then the planned employee.
   Roles: PAYROLL_ADMIN or BUDGET_EDITOR. */
USE DATABASE PAYROLL_DB;
   
CREATE OR REPLACE PROCEDURE APP.SP_DELETE_PLANNED_HIRE(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_EMPLOYEE_ID INT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Removes a planned hire'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_allowed     INT;
    v_type        TEXT;
    v_scen_status TEXT;
    v_found       INT;
    v_old         TEXT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE AND u.ROLE_CODE IN ('PAYROLL_ADMIN', 'BUDGET_EDITOR');
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not allowed to manage budgets and forecasts.');
    END IF;
    SELECT MAX(SCENARIO_TYPE), MAX(SCENARIO_STATUS) INTO :v_type, :v_scen_status
    FROM APP.T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL OR v_type = 'ACTUAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' is not a budget or forecast.');
    END IF;
    IF (v_scen_status <> 'DRAFT' AND v_scen_status <> 'REJECTED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This scenario is ' || v_scen_status || ' and cannot be edited.');
    END IF;

    SELECT COUNT(*) INTO :v_found FROM APP.T_D_EMPLOYEE
    WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID AND IS_PLANNED AND PLANNED_SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_found = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only planned hires of this scenario can be removed. Actual employees cannot be deleted.');
    END IF;

    BEGIN TRANSACTION;

    SELECT TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL(*)) INTO :v_old
    FROM APP.T_D_SCENARIO_EMPLOYEE WHERE SCENARIO_ID = :P_SCENARIO_ID AND EMPLOYEE_ID = :P_EMPLOYEE_ID;

    DELETE FROM APP.T_F_PAYROLL_LINE          WHERE SCENARIO_ID = :P_SCENARIO_ID AND EMPLOYEE_ID = :P_EMPLOYEE_ID;
    DELETE FROM APP.T_F_FUND_ALLOCATION        WHERE SCENARIO_ID = :P_SCENARIO_ID AND EMPLOYEE_ID = :P_EMPLOYEE_ID;
    DELETE FROM APP.T_F_DEPARTMENT_ALLOCATION  WHERE SCENARIO_ID = :P_SCENARIO_ID AND EMPLOYEE_ID = :P_EMPLOYEE_ID;
    DELETE FROM APP.T_F_PAYROLL_INPUT          WHERE SCENARIO_ID = :P_SCENARIO_ID AND EMPLOYEE_ID = :P_EMPLOYEE_ID;
    DELETE FROM APP.T_D_SCENARIO_EMPLOYEE      WHERE SCENARIO_ID = :P_SCENARIO_ID AND EMPLOYEE_ID = :P_EMPLOYEE_ID;
    DELETE FROM APP.T_D_EMPLOYEE               WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID AND IS_PLANNED;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_SCENARIO_EMPLOYEE', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'EMPLOYEE_ID', :P_EMPLOYEE_ID), 'DELETE', PARSE_JSON(:v_old), NULL, :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Planned hire removed.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
