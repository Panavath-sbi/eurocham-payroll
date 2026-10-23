-- depends_on: T_D_APP_USER, T_D_EMPLOYEE, T_D_SCENARIO, T_F_SCENARIO_PERIOD, T_D_EMPLOYEE_CONTRACT, T_F_PAYROLL_INPUT, SP_RESET_APPROVALS, SP_CALC_PERIOD, T_F_CHANGE_LOG
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   SP_SET_EMPLOYEE_ACTIVE
   Activates or deactivates an employee from the open month onwards (never deleted).
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  V1.5.0: role check reads T_D_APP_USER.ROLE_CODE (one role per user).
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Employee Register: the Active toggle.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   Deactivate: the employee leaves the open payroll month immediately (INCLUDE_IN_PAYROLL
   = FALSE) and is not added to later months until reactivated.
   Activate: the employee rejoins the open month (if their contract covers it) and later months.
   Finalized months, budgets and forecasts are not changed.
   If the open month changes, its approvals reset and it is recalculated.
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE APP.SP_SET_EMPLOYEE_ACTIVE(P_USER_EMAIL TEXT, P_EMPLOYEE_ID INT, P_IS_ACTIVE BOOLEAN)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Activates or deactivates an employee from the open month onwards'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed    INT;
    v_exists     INT;
    v_current    BOOLEAN;
    v_planned    BOOLEAN;
    v_actual     INT;
    v_open       INT;
    v_last_final INT;
    v_contract   INT DEFAULT 0;
    v_ids        TEXT;
    v_reason     TEXT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    IF (P_IS_ACTIVE IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'P_IS_ACTIVE must be TRUE or FALSE.');
    END IF;

    SELECT COUNT(*), MAX(IS_ACTIVE), MAX(IS_PLANNED) INTO :v_exists, :v_current, :v_planned
    FROM APP.T_D_EMPLOYEE WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID;
    IF (v_exists = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || P_EMPLOYEE_ID || ' does not exist.');
    END IF;
    IF (v_planned) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Planned hires are managed on the Budget / Forecast pages.');
    END IF;
    IF (v_current = P_IS_ACTIVE) THEN
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'No change.');
    END IF;

    SELECT MAX(s.SCENARIO_ID), MAX(IFF(x.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'), x.PERIOD_KEY, NULL)),
           MAX(IFF(x.PERIOD_STATUS = 'FINALIZED', x.PERIOD_KEY, NULL))
      INTO :v_actual, :v_open, :v_last_final
    FROM APP.T_D_SCENARIO s
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID
    WHERE s.SCENARIO_TYPE = 'ACTUAL';

    IF (v_open IS NOT NULL) THEN
        SELECT COUNT(*) INTO :v_contract FROM APP.T_D_EMPLOYEE_CONTRACT
        WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID
          AND :v_open BETWEEN VALID_FROM_PERIOD_KEY AND COALESCE(VALID_TO_PERIOD_KEY, 999912);
    END IF;

    BEGIN TRANSACTION;

    UPDATE APP.T_D_EMPLOYEE
    SET IS_ACTIVE = :P_IS_ACTIVE, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID;

    -- The open month changes immediately
    IF (v_open IS NOT NULL AND (NOT P_IS_ACTIVE OR v_contract > 0)) THEN
        MERGE INTO APP.T_F_PAYROLL_INPUT t
        USING (SELECT :v_actual AS SCENARIO_ID, :v_open AS PERIOD_KEY, :P_EMPLOYEE_ID AS EMPLOYEE_ID) s
           ON t.SCENARIO_ID = s.SCENARIO_ID AND t.PERIOD_KEY = s.PERIOD_KEY AND t.EMPLOYEE_ID = s.EMPLOYEE_ID
        WHEN MATCHED THEN UPDATE SET INCLUDE_IN_PAYROLL = :P_IS_ACTIVE, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHEN NOT MATCHED AND :P_IS_ACTIVE THEN INSERT (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, INCLUDE_IN_PAYROLL, INSERT_BY, UPDATE_BY)
            VALUES (s.SCENARIO_ID, s.PERIOD_KEY, s.EMPLOYEE_ID, TRUE, :P_USER_EMAIL, :P_USER_EMAIL);

        v_ids := '[' || P_EMPLOYEE_ID || ']';
        v_reason := IFF(P_IS_ACTIVE, 'Employee reactivated', 'Employee deactivated');
        CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_actual, :v_open, :v_ids, :v_reason);
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :v_actual, :v_open);
    END IF;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_EMPLOYEE', OBJECT_CONSTRUCT('EMPLOYEE_ID', :P_EMPLOYEE_ID), 'UPDATE', OBJECT_CONSTRUCT('IS_ACTIVE', :v_current), OBJECT_CONSTRUCT('IS_ACTIVE', :P_IS_ACTIVE, 'FROM_PERIOD_KEY', :v_open), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Employee ' ||
        IFF(P_IS_ACTIVE, 'activated', 'deactivated') ||
        IFF(v_open IS NULL, '.', ' from ' || v_open || ' onwards.'));
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
