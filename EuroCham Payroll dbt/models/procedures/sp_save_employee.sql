-- depends_on: {{ ref('t_d_app_user') }}, {{ ref('t_d_employee') }}, {{ ref('t_d_scenario') }}, {{ ref('t_f_scenario_period') }}, {{ ref('t_d_entity') }}, {{ ref('t_d_employee_contract') }}, {{ ref('t_f_change_log') }}, {{ ref('t_f_payroll_input') }}, {{ ref('sp_reset_approvals') }}, {{ ref('sp_calc_period') }}
/* =====================================================================================
   SP_SAVE_EMPLOYEE
   Creates an employee (with a first contract) or updates identity fields.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-09-29  Fix: "INTO clause is not allowed in this context" - the create-validation
               SELECT INTO no longer contains a subquery; the chamber is checked separately.
   2026-10-02  V1.5.0: CORE tables moved to APP; role check reads T_D_APP_USER.ROLE_CODE (one role per user).
   2026-10-05  Create: accepts non_resident_from / non_resident_to for the first contract.
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Employee Register: "Add employee" and the identity fields of "Edit Employee Info".

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   P_EMPLOYEE is a JSON object.
   Create (no employee_id): resource_code, first_name, last_name, entity_code,
     monthly_salary_usd and employment_start_date are required. Optional: email, phone,
     nationality, bank_name, bank_account_name, bank_account_number, employment_end_date,
     position, employment_type, contract_type, tax_status, dependant_children,
     dependant_spouse, insurance_usd, visa_usd, work_permit_usd, fringe_benefit_usd,
     non_resident_from, non_resident_to (non-residents only),
     valid_from_period_key (default: the open payroll month, else the start-date month).
     If the new contract starts on or before the open month, the employee is added to it.
   Update (employee_id given): identity fields only; keys left out keep their value;
     "employment_end_date": null clears the end date. Pay terms change through
     SP_SAVE_EMPLOYEE_CONTRACT; activity through SP_SET_EMPLOYEE_ACTIVE.
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE {{ app() }}.SP_SAVE_EMPLOYEE(P_USER_EMAIL TEXT, P_EMPLOYEE TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Creates an employee or updates identity fields'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed    INT;
    v_emp        INT;
    v_code       TEXT;
    v_exists     INT;
    v_planned    BOOLEAN;
    v_dupe       INT;
    v_missing    INT;
    v_entity     TEXT;
    v_entity_ok  INT;
    v_from       INT;
    v_actual     INT;
    v_open       INT;
    v_last_final INT;
    v_old        TEXT;
    v_new        TEXT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM {{ app() }}.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT D:employee_id::INT, TRIM(D:resource_code::TEXT) INTO :v_emp, :v_code
    FROM (SELECT PARSE_JSON(:P_EMPLOYEE) AS D);

    IF (v_code IS NOT NULL) THEN
        SELECT COUNT(*) INTO :v_dupe FROM {{ app() }}.T_D_EMPLOYEE
        WHERE UPPER(RESOURCE_CODE) = UPPER(:v_code) AND EMPLOYEE_ID <> COALESCE(:v_emp, -1);
        IF (v_dupe > 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Resource ID ' || v_code || ' is already used by another employee.');
        END IF;
    END IF;

    SELECT MAX(s.SCENARIO_ID), MAX(IFF(x.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'), x.PERIOD_KEY, NULL)),
           MAX(IFF(x.PERIOD_STATUS = 'FINALIZED', x.PERIOD_KEY, NULL))
      INTO :v_actual, :v_open, :v_last_final
    FROM {{ app() }}.T_D_SCENARIO s
    LEFT JOIN {{ app() }}.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID
    WHERE s.SCENARIO_TYPE = 'ACTUAL';

    IF (v_emp IS NULL) THEN
        -- ---------------- CREATE ----------------
        -- Required fields and the contract start month (plain SELECT INTO, no subquery in the select list)
        SELECT IFF(D:resource_code IS NULL OR D:first_name IS NULL OR D:last_name IS NULL OR D:entity_code IS NULL
                   OR D:monthly_salary_usd IS NULL OR D:employment_start_date IS NULL
                   OR D:monthly_salary_usd::FLOAT < 0, 1, 0),
               D:entity_code::TEXT,
               COALESCE(D:valid_from_period_key::INT, :v_open,
                        TO_NUMBER(TO_CHAR(D:employment_start_date::DATE, 'YYYYMM')))
          INTO :v_missing, :v_entity, :v_from
        FROM (SELECT PARSE_JSON(:P_EMPLOYEE) AS D);

        SELECT COUNT(*) INTO :v_entity_ok
        FROM {{ app() }}.T_D_ENTITY
        WHERE ENTITY_CODE = :v_entity AND IS_ACTIVE;

        IF (v_missing = 1) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'resource_code, first_name, last_name, entity_code, monthly_salary_usd (>= 0) and employment_start_date are required.');
        END IF;
        IF (v_entity_ok = 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Unknown or inactive chamber (entity_code).');
        END IF;
        IF (v_from <= COALESCE(v_last_final, 0)) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The contract cannot start in a finalized month (' || v_from || ').');
        END IF;

        BEGIN TRANSACTION;

        INSERT INTO {{ app() }}.T_D_EMPLOYEE
            (RESOURCE_CODE, FIRST_NAME, LAST_NAME, EMAIL, PHONE, NATIONALITY, EMPLOYMENT_START_DATE, EMPLOYMENT_END_DATE,
             IS_ACTIVE, BANK_NAME, BANK_ACCOUNT_NAME, BANK_ACCOUNT_NUMBER, IS_PLANNED, INSERT_BY, UPDATE_BY)
        SELECT :v_code, D:first_name::TEXT, D:last_name::TEXT, D:email::TEXT, D:phone::TEXT, D:nationality::TEXT,
               D:employment_start_date::DATE, D:employment_end_date::DATE, TRUE,
               D:bank_name::TEXT, D:bank_account_name::TEXT, D:bank_account_number::TEXT, FALSE,
               :P_USER_EMAIL, :P_USER_EMAIL
        FROM (SELECT PARSE_JSON(:P_EMPLOYEE) AS D);

        SELECT MAX(EMPLOYEE_ID) INTO :v_emp FROM {{ app() }}.T_D_EMPLOYEE WHERE RESOURCE_CODE = :v_code;

        INSERT INTO {{ app() }}.T_D_EMPLOYEE_CONTRACT
            (EMPLOYEE_ID, VALID_FROM_PERIOD_KEY, VALID_TO_PERIOD_KEY, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
             MONTHLY_SALARY_USD, TAX_STATUS, DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD,
             WORK_PERMIT_USD, FRINGE_BENEFIT_USD, CHANGE_REASON, NON_RESIDENT_FROM, NON_RESIDENT_TO, INSERT_BY, UPDATE_BY)
        SELECT :v_emp, :v_from, NULL, D:position::TEXT, COALESCE(D:employment_type::TEXT, 'FULL_TIME'),
               D:contract_type::TEXT, D:entity_code::TEXT, D:monthly_salary_usd::FLOAT,
               COALESCE(D:tax_status::TEXT, 'RESIDENT'), COALESCE(D:dependant_children::INT, 0),
               COALESCE(D:dependant_spouse::INT, 0), COALESCE(D:insurance_usd::FLOAT, 0), COALESCE(D:visa_usd::FLOAT, 0),
               COALESCE(D:work_permit_usd::FLOAT, 0), COALESCE(D:fringe_benefit_usd::FLOAT, 0), 'New employee',
               IFF(COALESCE(D:tax_status::TEXT, 'RESIDENT') = 'NON_RESIDENT', D:non_resident_from::DATE, NULL),
               IFF(COALESCE(D:tax_status::TEXT, 'RESIDENT') = 'NON_RESIDENT', D:non_resident_to::DATE, NULL),
               :P_USER_EMAIL, :P_USER_EMAIL
        FROM (SELECT PARSE_JSON(:P_EMPLOYEE) AS D);

        SELECT TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL(*)) INTO :v_new FROM {{ app() }}.T_D_EMPLOYEE WHERE EMPLOYEE_ID = :v_emp;
        INSERT INTO {{ app() }}.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_EMPLOYEE', OBJECT_CONSTRUCT('EMPLOYEE_ID', :v_emp), 'INSERT', NULL, PARSE_JSON(:v_new), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

        -- Join the open month if the contract already applies to it
        IF (v_open IS NOT NULL AND v_from <= v_open) THEN
            INSERT INTO {{ app() }}.T_F_PAYROLL_INPUT (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, INSERT_BY, UPDATE_BY)
            SELECT :v_actual, :v_open, :v_emp, :P_USER_EMAIL, :P_USER_EMAIL;
            CALL {{ app() }}.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_actual, :v_open, NULL, 'New employee added');
            CALL {{ app() }}.SP_CALC_PERIOD(:P_USER_EMAIL, :v_actual, :v_open);
        END IF;

        COMMIT;
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Employee ' || v_code || ' created.', 'employee_id', v_emp);
    END IF;

    -- ---------------- UPDATE ----------------
    SELECT COUNT(*), MAX(IS_PLANNED) INTO :v_exists, :v_planned FROM {{ app() }}.T_D_EMPLOYEE WHERE EMPLOYEE_ID = :v_emp;
    IF (v_exists = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || v_emp || ' does not exist.');
    END IF;
    IF (v_planned) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Planned hires are edited on the Budget / Forecast pages.');
    END IF;

    BEGIN TRANSACTION;

    SELECT TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL(*)) INTO :v_old FROM {{ app() }}.T_D_EMPLOYEE WHERE EMPLOYEE_ID = :v_emp;

    UPDATE {{ app() }}.T_D_EMPLOYEE e
    SET RESOURCE_CODE         = COALESCE(:v_code, e.RESOURCE_CODE),
        FIRST_NAME            = COALESCE(x.D:first_name::TEXT, e.FIRST_NAME),
        LAST_NAME             = COALESCE(x.D:last_name::TEXT, e.LAST_NAME),
        EMAIL                 = COALESCE(x.D:email::TEXT, e.EMAIL),
        PHONE                 = COALESCE(x.D:phone::TEXT, e.PHONE),
        NATIONALITY           = COALESCE(x.D:nationality::TEXT, e.NATIONALITY),
        EMPLOYMENT_START_DATE = COALESCE(x.D:employment_start_date::DATE, e.EMPLOYMENT_START_DATE),
        EMPLOYMENT_END_DATE   = IFF(IS_NULL_VALUE(x.D:employment_end_date), NULL,
                                    COALESCE(x.D:employment_end_date::DATE, e.EMPLOYMENT_END_DATE)),
        BANK_NAME             = COALESCE(x.D:bank_name::TEXT, e.BANK_NAME),
        BANK_ACCOUNT_NAME     = COALESCE(x.D:bank_account_name::TEXT, e.BANK_ACCOUNT_NAME),
        BANK_ACCOUNT_NUMBER   = COALESCE(x.D:bank_account_number::TEXT, e.BANK_ACCOUNT_NUMBER),
        UPDATE_DATE           = CURRENT_TIMESTAMP,
        UPDATE_BY             = :P_USER_EMAIL
    FROM (SELECT PARSE_JSON(:P_EMPLOYEE) AS D) x
    WHERE e.EMPLOYEE_ID = :v_emp;

    SELECT TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL(*)) INTO :v_new FROM {{ app() }}.T_D_EMPLOYEE WHERE EMPLOYEE_ID = :v_emp;
    INSERT INTO {{ app() }}.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_EMPLOYEE', OBJECT_CONSTRUCT('EMPLOYEE_ID', :v_emp), 'UPDATE', PARSE_JSON(:v_old), PARSE_JSON(:v_new), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Employee ' || v_emp || ' updated.', 'employee_id', v_emp);
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
