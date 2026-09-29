/* =====================================================================================
   REBUILD DEV - !!! DELETES ALL DATA !!!
   Drops the APP, CORE and RPT schemas and rebuilds everything from the repository:
   tables, reference data, views, procedures and the dummy data.
   FOR DEVELOPMENT ONLY. NEVER RUN IT ON A DATABASE WITH REAL PAYROLL DATA.
   The guard below stops the script unless the current database is the one named in
   v_allowed. Run it with "Run All"; it stops at the first error.
   =====================================================================================

   HISTORY
   -------
   2026-09-30  Initial version.
   ===================================================================================== */

-- ---------------------------------------------------------------------------------
-- SETUP (once): replace @PAYROLL_DB.PUBLIC.PAYROLL_REPO everywhere in this file with your
-- Git repository object (find it with SHOW GIT REPOSITORIES;), and 'main' if you deploy
-- another branch. The paths assume the project sits in the payroll-snowflake folder.
-- ---------------------------------------------------------------------------------

USE DATABASE PAYROLL_DB;
-- The Git repository object must NOT live in the APP, CORE or RPT schemas
-- (rebuild_dev.sql drops them).

-- Get the latest commits from GitHub before running the files
ALTER GIT REPOSITORY PAYROLL_DB.PUBLIC.PAYROLL_REPO FETCH;

-- ---------------------------------------------------------------------------------
-- GUARD: only the database named here may be rebuilt. Never put a production name here.
-- ---------------------------------------------------------------------------------
EXECUTE IMMEDIATE $$
DECLARE
    v_allowed TEXT DEFAULT 'PAYROLL_DB';
    e_wrong_db EXCEPTION (-20100, 'REBUILD STOPPED: the current database is not the allowed dev database.');
BEGIN
    IF (CURRENT_DATABASE() IS NULL OR CURRENT_DATABASE() <> v_allowed) THEN
        RAISE e_wrong_db;
    END IF;
    RETURN 'Guard passed: rebuilding ' || CURRENT_DATABASE();
END;
$$;

-- 1. Start clean (removes every table, view and procedure of the model)
DROP SCHEMA IF EXISTS RPT CASCADE;
DROP SCHEMA IF EXISTS APP CASCADE;
DROP SCHEMA IF EXISTS CORE CASCADE;

-- 2. Schemas and tables (versioned files, in version order)
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/tables/V1.0.0__create_schemas.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/tables/V1.0.1__create_tables_core_dims_params.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/tables/V1.0.2__create_tables_app.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/tables/V1.0.3__create_tables_core_facts.sql;

-- 3. Reference data, then later versioned changes
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/data/V1.1.0__load_reference_data.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/tables/V1.2.0__approval_action_send_back.sql;

-- 4. Views and procedures
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/views/R__views_core.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/views/R__views_rpt.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/views/R__views_pbi.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_calc_period.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_reset_approvals.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_approve_step.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_calculate_payroll.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_create_forecast.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_create_scenario.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_delete_planned_hire.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_delete_scenario.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_finalize_payroll.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_open_payroll_period.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_reject_step.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_save_approval_steps.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_save_department_allocation.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_save_employee.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_save_employee_contract.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_save_exchange_rate.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_save_fund_allocation.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_save_monthly_input.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_save_payroll_adjustment.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_save_planned_hire.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_save_scenario_employee.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_save_working_days.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_set_employee_active.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_set_employee_check.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_submit_scenario.sql;
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/migrations/procedures/R__sp_undo_approval.sql;

-- 5. Dummy data (dev only), including its check queries
EXECUTE IMMEDIATE FROM @PAYROLL_DB.PUBLIC.PAYROLL_REPO/branches/main/payroll-snowflake/dev_data/load_dummy_data.sql;

-- 6. Quick check: expect 192 periods and the dummy row counts listed in load_dummy_data.sql
SELECT COUNT(*) AS PERIODS FROM CORE.T_D_PERIOD;
SELECT COUNT(*) AS EMPLOYEES FROM APP.T_D_EMPLOYEE;
SELECT COUNT(*) AS PAY_LINES FROM CORE.T_F_PAYROLL_LINE;

-- Next: run tests/test_01_payroll_cycle.sql, then tests/test_02_remaining_procedures.sql,
-- top to bottom, comparing each result with its expected value.

-- End of script