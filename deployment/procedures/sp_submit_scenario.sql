-- depends_on: T_D_APP_USER, T_D_SCENARIO, T_D_SCENARIO_EMPLOYEE, T_F_SCENARIO_PERIOD, SP_CALC_PERIOD, T_F_APPROVAL, T_P_APPROVAL_STEP, T_F_CHANGE_LOG
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   SP_SUBMIT_SCENARIO
   Submits a budget scenario for approval.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  Also creates the request's approval step rows (APP.T_F_APPROVAL_STEP_STATE, PENDING).
   2026-10-02  V1.5.0: no request; the budget's approval rows (APP.T_F_APPROVAL, period 0)
               are created PENDING, replacing those of an earlier, rejected submission
               (its history stays in T_F_CHANGE_LOG); CORE -> APP; one role per user.
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Budget Input page: submit for approval.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   The scenario must be a DRAFT or REJECTED budget. It is recalculated, its approval
   starts (one PENDING row per approval step, period 0) and the scenario becomes
   IN_APPROVAL (locked for editing).
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE {{ schema_app }}.SP_SUBMIT_SCENARIO(P_USER_EMAIL TEXT, P_SCENARIO_ID INT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Submits a budget scenario for approval'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed     INT;
    v_type        TEXT;
    v_scen_status TEXT;
    v_emps        INT;
    v_pk          INT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM {{ schema_app }}.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;
    SELECT MAX(SCENARIO_TYPE), MAX(SCENARIO_STATUS) INTO :v_type, :v_scen_status
    FROM {{ schema_app }}.T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL OR v_type = 'ACTUAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' is not a budget or forecast.');
    END IF;
    IF (v_scen_status <> 'DRAFT' AND v_scen_status <> 'REJECTED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This scenario is ' || v_scen_status || ' and cannot be edited.');
    END IF;

    IF (v_type <> 'BUDGET') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only budget scenarios go through approval.');
    END IF;
    SELECT COUNT(*) INTO :v_emps FROM {{ schema_app }}.T_D_SCENARIO_EMPLOYEE WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_emps = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The scenario has no employees.');
    END IF;

    BEGIN TRANSACTION;

    LET rs_calc RESULTSET := (
        SELECT PERIOD_KEY FROM {{ schema_app }}.T_F_SCENARIO_PERIOD
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_STATUS NOT IN ('FINALIZED', 'LOCKED')
        ORDER BY PERIOD_KEY);
    LET cur_calc CURSOR FOR rs_calc;
    FOR rec IN cur_calc DO
        v_pk := rec.PERIOD_KEY;
        CALL {{ schema_app }}.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :v_pk);
    END FOR;

    -- The approval starts over: one PENDING row per approval step in force for the budget year
    DELETE FROM {{ schema_app }}.T_F_APPROVAL WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = 0;

    INSERT INTO {{ schema_app }}.T_F_APPROVAL (SCENARIO_ID, PERIOD_KEY, STEP_ORDER, STEP_STATUS, INSERT_BY, UPDATE_BY)
    SELECT DISTINCT sc.SCENARIO_ID, 0, st.STEP_ORDER, 'PENDING', :P_USER_EMAIL, :P_USER_EMAIL
    FROM {{ schema_app }}.T_D_SCENARIO sc
    JOIN {{ schema_app }}.T_P_APPROVAL_STEP st
      ON st.IS_ACTIVE
     AND st.APPLIES_TO IN ('ALL', sc.SCENARIO_TYPE)
     AND sc.FISCAL_YEAR * 100 + 1 BETWEEN st.VALID_FROM_PERIOD_KEY AND COALESCE(st.VALID_TO_PERIOD_KEY, 999912)
    WHERE sc.SCENARIO_ID = :P_SCENARIO_ID;

    UPDATE {{ schema_app }}.T_D_SCENARIO
    SET SCENARIO_STATUS = 'IN_APPROVAL', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHERE SCENARIO_ID = :P_SCENARIO_ID;

    INSERT INTO {{ schema_app }}.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_SCENARIO', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID), 'UPDATE', OBJECT_CONSTRUCT('SCENARIO_STATUS', :v_scen_status), OBJECT_CONSTRUCT('SCENARIO_STATUS', 'IN_APPROVAL'), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Scenario submitted for approval.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
