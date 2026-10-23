-- depends_on: T_D_APP_USER, T_D_EMPLOYEE, T_D_SCENARIO, T_F_SCENARIO_PERIOD, T_D_PERIOD, T_D_EMPLOYEE_CONTRACT, T_D_ENTITY, T_F_CHANGE_LOG, SP_RESET_APPROVALS, SP_CALC_PERIOD
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   SP_SAVE_EMPLOYEE_CONTRACT
   Changes an employee's pay terms from a given month (new contract version).
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-10-02  V1.5.0: CORE tables moved to APP; role check reads T_D_APP_USER.ROLE_CODE (one role per user).
   2026-10-05  Accepts non_resident_from / non_resident_to (null clears; both are cleared
               when the tax status is RESIDENT).
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.

   CALLED FROM
   -----------
   Employee Register: pay fields of "Edit Employee Info", including Pay Adjustments.

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate), checks the
     user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
   * Validations run before any write; writes run in one transaction.

   P_EFFECTIVE_PERIOD_KEY: first month the new terms apply (default: the open payroll
   month). Must be after the last finalized month.
   P_CONTRACT: JSON with any of position, employment_type, contract_type, entity_code,
   monthly_salary_usd, tax_status, dependant_children, dependant_spouse, insurance_usd,
   visa_usd, work_permit_usd, fringe_benefit_usd, change_reason, non_resident_from,
   non_resident_to (dates YYYY-MM-DD). Keys left out keep the value of the version in
   force that month; a date key set to null clears it. RESIDENT clears both dates.
   If the version in force already starts that month, it is corrected in place; otherwise
   it is closed the month before and a new version is added.
   If the change reaches the open month, its approvals reset and it is recalculated.
   Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3).
   ===================================================================================== */
CREATE OR REPLACE PROCEDURE {{ schema_app }}.SP_SAVE_EMPLOYEE_CONTRACT(P_USER_EMAIL TEXT, P_EMPLOYEE_ID INT, P_EFFECTIVE_PERIOD_KEY INT, P_CONTRACT TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Adds or corrects an employee contract version'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_allowed    INT;
    v_exists     INT;
    v_planned    BOOLEAN;
    v_actual     INT;
    v_open       INT;
    v_last_final INT;
    v_eff        INT;
    v_prev       INT;
    v_cur_id     INT;
    v_cur_from   INT;
    v_cur_to     INT;
    v_ids        TEXT;
    v_bad        INT;
    v_old        TEXT;
    v_new        TEXT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM {{ schema_app }}.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT COUNT(*), MAX(IS_PLANNED) INTO :v_exists, :v_planned FROM {{ schema_app }}.T_D_EMPLOYEE WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID;
    IF (v_exists = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || P_EMPLOYEE_ID || ' does not exist.');
    END IF;
    IF (v_planned) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Planned hires are edited on the Budget / Forecast pages.');
    END IF;

    SELECT MAX(s.SCENARIO_ID), MAX(IFF(x.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'), x.PERIOD_KEY, NULL)),
           MAX(IFF(x.PERIOD_STATUS = 'FINALIZED', x.PERIOD_KEY, NULL))
      INTO :v_actual, :v_open, :v_last_final
    FROM {{ schema_app }}.T_D_SCENARIO s
    LEFT JOIN {{ schema_app }}.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID
    WHERE s.SCENARIO_TYPE = 'ACTUAL';

    v_eff := COALESCE(P_EFFECTIVE_PERIOD_KEY, v_open);
    IF (v_eff IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No payroll month is open; give the effective month.');
    END IF;
    IF (v_eff <= COALESCE(v_last_final, 0)) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || v_eff || ' is finalized. Pay changes must start after ' || v_last_final || '.');
    END IF;

    SELECT MAX(TO_NUMBER(TO_CHAR(DATEADD(MONTH, -1, PERIOD_START_DATE), 'YYYYMM'))) INTO :v_prev
    FROM {{ schema_app }}.T_D_PERIOD WHERE PERIOD_KEY = :v_eff;
    IF (v_prev IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || v_eff || ' is not in the calendar.');
    END IF;

    SELECT MAX(CONTRACT_ID), MAX(VALID_FROM_PERIOD_KEY), MAX(VALID_TO_PERIOD_KEY) INTO :v_cur_id, :v_cur_from, :v_cur_to
    FROM {{ schema_app }}.T_D_EMPLOYEE_CONTRACT
    WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID
      AND :v_eff BETWEEN VALID_FROM_PERIOD_KEY AND COALESCE(VALID_TO_PERIOD_KEY, 999912);
    IF (v_cur_id IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The employee has no contract in force in ' || v_eff || '. Create one with SP_SAVE_EMPLOYEE.');
    END IF;

    -- New terms = current version overlaid with the JSON (DDL: before the transaction)
    CREATE OR REPLACE TEMPORARY TABLE {{ schema_app }}.TMP_CONTRACT AS
    SELECT
        COALESCE(x.D:position::TEXT,           c.POSITION)           AS POSITION,
        COALESCE(x.D:employment_type::TEXT,    c.EMPLOYMENT_TYPE)    AS EMPLOYMENT_TYPE,
        COALESCE(x.D:contract_type::TEXT,      c.CONTRACT_TYPE)      AS CONTRACT_TYPE,
        COALESCE(x.D:entity_code::TEXT,        c.ENTITY_CODE)        AS ENTITY_CODE,
        COALESCE(x.D:monthly_salary_usd::FLOAT, c.MONTHLY_SALARY_USD) AS MONTHLY_SALARY_USD,
        COALESCE(x.D:tax_status::TEXT,         c.TAX_STATUS)         AS TAX_STATUS,
        COALESCE(x.D:dependant_children::INT,  c.DEPENDANT_CHILDREN) AS DEPENDANT_CHILDREN,
        COALESCE(x.D:dependant_spouse::INT,    c.DEPENDANT_SPOUSE)   AS DEPENDANT_SPOUSE,
        COALESCE(x.D:insurance_usd::FLOAT,     c.INSURANCE_USD)      AS INSURANCE_USD,
        COALESCE(x.D:visa_usd::FLOAT,          c.VISA_USD)           AS VISA_USD,
        COALESCE(x.D:work_permit_usd::FLOAT,   c.WORK_PERMIT_USD)    AS WORK_PERMIT_USD,
        COALESCE(x.D:fringe_benefit_usd::FLOAT, c.FRINGE_BENEFIT_USD) AS FRINGE_BENEFIT_USD,
        COALESCE(x.D:change_reason::TEXT, 'Contract change')         AS CHANGE_REASON,
        IFF(COALESCE(x.D:tax_status::TEXT, c.TAX_STATUS) = 'RESIDENT', NULL,
            IFF(IS_NULL_VALUE(x.D:non_resident_from), NULL,
                COALESCE(x.D:non_resident_from::DATE, c.NON_RESIDENT_FROM)))  AS NON_RESIDENT_FROM,
        IFF(COALESCE(x.D:tax_status::TEXT, c.TAX_STATUS) = 'RESIDENT', NULL,
            IFF(IS_NULL_VALUE(x.D:non_resident_to), NULL,
                COALESCE(x.D:non_resident_to::DATE, c.NON_RESIDENT_TO)))      AS NON_RESIDENT_TO
    FROM {{ schema_app }}.T_D_EMPLOYEE_CONTRACT c, (SELECT PARSE_JSON(:P_CONTRACT) AS D) x
    WHERE c.CONTRACT_ID = :v_cur_id;

    SELECT COUNT_IF(t.MONTHLY_SALARY_USD < 0 OR t.INSURANCE_USD < 0 OR t.VISA_USD < 0 OR t.WORK_PERMIT_USD < 0
                    OR t.FRINGE_BENEFIT_USD < 0 OR t.DEPENDANT_CHILDREN < 0 OR t.DEPENDANT_SPOUSE NOT IN (0, 1)
                    OR t.TAX_STATUS NOT IN ('RESIDENT', 'NON_RESIDENT') OR e.ENTITY_CODE IS NULL)
      INTO :v_bad
    FROM {{ schema_app }}.TMP_CONTRACT t
    LEFT JOIN {{ schema_app }}.T_D_ENTITY e ON e.ENTITY_CODE = t.ENTITY_CODE AND e.IS_ACTIVE;
    IF (v_bad > 0) THEN
        DROP TABLE IF EXISTS {{ schema_app }}.TMP_CONTRACT;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Invalid values: amounts must be >= 0, spouse 0 or 1, tax status RESIDENT / NON_RESIDENT, and the chamber must exist.');
    END IF;

    BEGIN TRANSACTION;

    SELECT TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL(*)) INTO :v_old FROM {{ schema_app }}.T_D_EMPLOYEE_CONTRACT WHERE CONTRACT_ID = :v_cur_id;

    IF (v_cur_from = v_eff) THEN
        -- Same starting month: correct the version in place
        UPDATE {{ schema_app }}.T_D_EMPLOYEE_CONTRACT c
        SET POSITION = t.POSITION, EMPLOYMENT_TYPE = t.EMPLOYMENT_TYPE, CONTRACT_TYPE = t.CONTRACT_TYPE,
            ENTITY_CODE = t.ENTITY_CODE, MONTHLY_SALARY_USD = t.MONTHLY_SALARY_USD, TAX_STATUS = t.TAX_STATUS,
            DEPENDANT_CHILDREN = t.DEPENDANT_CHILDREN, DEPENDANT_SPOUSE = t.DEPENDANT_SPOUSE,
            INSURANCE_USD = t.INSURANCE_USD, VISA_USD = t.VISA_USD, WORK_PERMIT_USD = t.WORK_PERMIT_USD,
            FRINGE_BENEFIT_USD = t.FRINGE_BENEFIT_USD, CHANGE_REASON = t.CHANGE_REASON,
            NON_RESIDENT_FROM = t.NON_RESIDENT_FROM, NON_RESIDENT_TO = t.NON_RESIDENT_TO,
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        FROM {{ schema_app }}.TMP_CONTRACT t
        WHERE c.CONTRACT_ID = :v_cur_id;
    ELSE
        -- Close the version in force the month before, add the new version
        UPDATE {{ schema_app }}.T_D_EMPLOYEE_CONTRACT
        SET VALID_TO_PERIOD_KEY = :v_prev, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE CONTRACT_ID = :v_cur_id;

        INSERT INTO {{ schema_app }}.T_D_EMPLOYEE_CONTRACT
            (EMPLOYEE_ID, VALID_FROM_PERIOD_KEY, VALID_TO_PERIOD_KEY, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
             MONTHLY_SALARY_USD, TAX_STATUS, DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD,
             WORK_PERMIT_USD, FRINGE_BENEFIT_USD, CHANGE_REASON, NON_RESIDENT_FROM, NON_RESIDENT_TO, INSERT_BY, UPDATE_BY)
        SELECT :P_EMPLOYEE_ID, :v_eff, :v_cur_to, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
               MONTHLY_SALARY_USD, TAX_STATUS, DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD,
               WORK_PERMIT_USD, FRINGE_BENEFIT_USD, CHANGE_REASON, NON_RESIDENT_FROM, NON_RESIDENT_TO, :P_USER_EMAIL, :P_USER_EMAIL
        FROM {{ schema_app }}.TMP_CONTRACT;
    END IF;

    SELECT TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL(*)) INTO :v_new
    FROM {{ schema_app }}.T_D_EMPLOYEE_CONTRACT
    WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID
      AND :v_eff BETWEEN VALID_FROM_PERIOD_KEY AND COALESCE(VALID_TO_PERIOD_KEY, 999912);
    INSERT INTO {{ schema_app }}.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_EMPLOYEE_CONTRACT', OBJECT_CONSTRUCT('EMPLOYEE_ID', :P_EMPLOYEE_ID, 'EFFECTIVE_PERIOD_KEY', :v_eff), 'UPDATE', PARSE_JSON(:v_old), PARSE_JSON(:v_new), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_open IS NOT NULL AND v_open >= v_eff) THEN
        v_ids := '[' || P_EMPLOYEE_ID || ']';
        CALL {{ schema_app }}.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_actual, :v_open, :v_ids, 'Contract changed');
        CALL {{ schema_app }}.SP_CALC_PERIOD(:P_USER_EMAIL, :v_actual, :v_open);
    END IF;

    COMMIT;
    DROP TABLE IF EXISTS {{ schema_app }}.TMP_CONTRACT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Contract saved from ' || v_eff || '.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        DROP TABLE IF EXISTS {{ schema_app }}.TMP_CONTRACT;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
