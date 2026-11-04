CREATE OR REPLACE PROCEDURE APP.SP_UNDO_APPROVAL(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT, P_STEP_ORDER INT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Undoes the approval of one step'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_type        TEXT;
    v_pk          INT;
    v_role        TEXT;
    v_step_status TEXT;
    v_in_progress INT;
    v_appr_status TEXT;
    v_allowed     INT;
    v_later       INT;
    v_remaining   INT;
BEGIN
    SELECT MAX(SCENARIO_TYPE) INTO :v_type FROM APP.T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' does not exist.');
    END IF;
    v_pk := IFF(v_type = 'ACTUAL', COALESCE(P_PERIOD_KEY, 0), 0);
    IF (v_type = 'ACTUAL' AND v_pk = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Give the payroll month.');
    END IF;

    SELECT MAX(APPROVER_ROLE), MAX(STEP_STATUS), MAX(IFF(IS_IN_PROGRESS, 1, 0)), MAX(APPROVAL_STATUS)
      INTO :v_role, :v_step_status, :v_in_progress, :v_appr_status
    FROM RPT.V_F_APPROVAL_PROGRESS
    WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND STEP_ORDER = :P_STEP_ORDER;
    IF (v_role IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No approval step ' || P_STEP_ORDER || ' found for this ' ||
                                IFF(v_type = 'ACTUAL', 'payroll month', 'budget') || '.');
    END IF;
    IF (v_in_progress = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This approval is not in progress (status ' || v_appr_status || ').');
    END IF;

    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE AND (u.ROLE_CODE = :v_role OR u.ROLE_CODE = 'ADMIN');
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only a user with role ' || v_role || ' (or ADMIN) can act on step ' || P_STEP_ORDER || '.');
    END IF;

    IF (v_step_status <> 'APPROVED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Step ' || P_STEP_ORDER || ' is not approved.');
    END IF;

    SELECT COUNT(*) INTO :v_later
    FROM RPT.V_F_APPROVAL_PROGRESS
    WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND STEP_ORDER > :P_STEP_ORDER AND STEP_STATUS = 'APPROVED';
    IF (v_later > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A later step is already approved. Undo that one first.');
    END IF;

    BEGIN TRANSACTION;

    UPDATE APP.T_F_APPROVAL
    SET STEP_STATUS = 'PENDING', LAST_ACTION = 'UNDO', ACTED_BY = :P_USER_EMAIL, ACTED_AT = CURRENT_TIMESTAMP,
        STEP_COMMENT = NULL, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND STEP_ORDER = :P_STEP_ORDER;

    IF (v_type = 'ACTUAL') THEN
        SELECT COUNT(*) INTO :v_remaining
        FROM APP.T_F_APPROVAL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND STEP_STATUS = 'APPROVED';
        IF (v_remaining = 0) THEN
            UPDATE APP.T_F_SCENARIO_PERIOD
            SET PERIOD_STATUS = 'OPEN', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
            WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :v_pk AND PERIOD_STATUS = 'IN_APPROVAL';
        END IF;
    END IF;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_APPROVAL',
           OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'PERIOD_KEY', :v_pk, 'STEP_ORDER', :P_STEP_ORDER), 'UPDATE',
           OBJECT_CONSTRUCT('STEP_STATUS', 'APPROVED'),
           OBJECT_CONSTRUCT('ACTION_TYPE', 'UNDO', 'STEP_STATUS', 'PENDING'),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Approval of step ' || P_STEP_ORDER || ' undone.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
