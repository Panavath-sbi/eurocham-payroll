/* =====================================================================================
   R - SP_GET_EMPLOYEE_BANK
   Returns one employee's bank details to any active app user.
   =====================================================================================

   HISTORY
   -------
   2026-10-05  Initial version. Bank details are in no view (every app user reads through
               the same connection), so the Employee Register gets them from here.
   2026-10-06  V1.7.0 roles: any active app user may call this (ADMIN or LEVEL_1-3);
               only approvals are limited by role.
   Repeatable file: re-deployed whenever it changes (CREATE OR REPLACE).

   CALLED FROM
   -----------
   Employee Register: opening Edit Employee Info (bank fields).

   CONVENTIONS
   -----------
   * Takes P_USER_EMAIL (the Power Apps user, passed by Power Automate) and checks the
     user role. Reads only: nothing is written, so no change log entry.
   * Returns a VARIANT: {"status": "OK" | "ERROR", "message": "...", plus the bank fields}.
   ===================================================================================== */

/* Role: any active app user (ADMIN, LEVEL_1, LEVEL_2 or LEVEL_3). Unknown or inactive users get an ERROR and no bank details.
   OK result: {"status": "OK", "message": "", "bank_name": ..., "bank_account_name": ...,
   "bank_account_number": ...}; a field that is empty is left out. */
USE DATABASE PAYROLL_DB;

CREATE OR REPLACE PROCEDURE APP.SP_GET_EMPLOYEE_BANK(P_USER_EMAIL TEXT, P_EMPLOYEE_ID INT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Returns an employee''s bank details to an active app user'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_allowed INT;
    v_found   INT;
    v_bank    TEXT;
    v_holder  TEXT;
    v_number  TEXT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT COUNT(*), MAX(BANK_NAME), MAX(BANK_ACCOUNT_NAME), MAX(BANK_ACCOUNT_NUMBER)
      INTO :v_found, :v_bank, :v_holder, :v_number
    FROM APP.T_D_EMPLOYEE
    WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID;
    IF (v_found = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || P_EMPLOYEE_ID || ' does not exist.');
    END IF;

    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', '',
                            'bank_name', v_bank, 'bank_account_name', v_holder, 'bank_account_number', v_number);
END;
$$;
