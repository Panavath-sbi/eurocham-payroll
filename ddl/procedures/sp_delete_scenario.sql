-- depends_on: T_D_APP_USER, T_D_SCENARIO, T_F_APPROVAL, T_F_PAYROLL_LINE, T_F_FUND_ALLOCATION, T_F_DEPARTMENT_ALLOCATION, T_F_PAYROLL_INPUT, T_D_SCENARIO_EMPLOYEE, T_F_SCENARIO_PERIOD, T_D_EMPLOYEE, T_F_CHANGE_LOG
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   SP_DELETE_SCENARIO
   Deletes a budget or forecast scenario and everything in it.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  Deletes the scenario's APP.T_F_APPROVAL_STEP_STATE rows (the action log was dropped).
   2026-10-02  V1.5.0: approval rows in APP.T_F_APPROVAL; no request, employee-check,
               cost-allocation or adjustment tables any more; CORE -> APP; one role per user.
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Budget Input page: "Delete Budget"; Forecast page: delete a forecast.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   Refused for the ACTUAL scenario, a scenario IN_APPROVAL and the official budget.
   Deletes the scenario's pay lines, allocations, inputs, employee terms,
   planned hires, approval history and months, then the scenario itself.
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE APP.SP_DELETE_SCENARIO(P_USER_EMAIL TEXT, P_SCENARIO_ID INT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Deletes a budget or forecast scenario'
EXECUTE AS CALLER
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
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
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

    DELETE FROM APP.T_F_APPROVAL               WHERE SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM APP.T_F_PAYROLL_LINE          WHERE SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM APP.T_F_FUND_ALLOCATION        WHERE SCENARIO_ID = :P_SCENARIO_ID;
    DELETE FROM APP.T_F_DEPARTMENT_ALLOCATION  WHERE SCENARIO_ID = :P_SCENARIO_ID;
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
