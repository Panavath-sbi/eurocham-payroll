-------------------------------------------------------------------------------
-- 03 ROLES - account roles, database roles, session policy, Entra OAuth, app role grants
-------------------------------------------------------------------------------
USE ROLE SECURITYADMIN;

-- 2. Create account role (no account-level privileges)
CREATE ROLE IF NOT EXISTS "SF_APA_PAYROLL-DBA"
    COMMENT = 'Database administrator role for DEV_PAYROLL_DB — scoped to database-level operations only, no account privileges';


-- 2. Create account role (no account-level privileges)
CREATE ROLE IF NOT EXISTS "SF_APA_PAYROLL-ETL"
    COMMENT = 'Database etl role for DEV_PAYROLL_DB — scoped to database-level operations only, no account privileges';


-- 3. Grant warehouse usage and database access to the account role
GRANT USAGE ON DATABASE DEV_PAYROLL_DB TO ROLE "SF_APA_PAYROLL-DBA";
--GRANT USAGE ON DATABASE DEV_PAYROLL_DB TO ROLE "SF_APA_PAYROLL-ETL";
GRANT MONITOR ON DATABASE DEV_PAYROLL_DB TO ROLE "SF_APA_PAYROLL-DBA";


-------------------------------------------------------------------------------
-- 4. Create DB_READER database role
-------------------------------------------------------------------------------
USE ROLE SYSADMIN;

CREATE DATABASE ROLE IF NOT EXISTS DEV_PAYROLL_DB.DB_READER
    COMMENT = 'Read-only access to all tables and views in DEV_PAYROLL_DB';

-- Schema access
GRANT USAGE ON ALL SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_READER;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_READER;

-- Read access on tables and views (current + future)
GRANT SELECT ON ALL TABLES IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_READER;
GRANT SELECT ON FUTURE TABLES IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_READER;
GRANT SELECT ON ALL VIEWS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_READER;
GRANT SELECT ON FUTURE VIEWS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_READER;

-------------------------------------------------------------------------------
-- 5. Create DB_WRITER database role (inherits DB_READER)
-------------------------------------------------------------------------------
CREATE DATABASE ROLE IF NOT EXISTS DEV_PAYROLL_DB.DB_WRITER
    COMMENT = 'Read-write access to DEV_PAYROLL_DB — inherits DB_READER, adds INSERT/UPDATE/DELETE/TRUNCATE and CREATE TABLE/VIEW';
GRANT DATABASE ROLE DEV_PAYROLL_DB.DB_READER TO DATABASE ROLE DEV_PAYROLL_DB.DB_WRITER;

-- Write access on tables (current + future)
GRANT INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_WRITER;
GRANT INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_WRITER;


-------------------------------------------------------------------------------
-- 6. Create DB_ADMIN database role (inherits DB_WRITER)
-------------------------------------------------------------------------------
CREATE DATABASE ROLE IF NOT EXISTS DEV_PAYROLL_DB.DB_ADMIN
    COMMENT = 'Full database administration for DEV_PAYROLL_DB — inherits DB_WRITER, adds CREATE SCHEMA and management of stages, functions, procedures, streams, tasks';
GRANT DATABASE ROLE DEV_PAYROLL_DB.DB_WRITER TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;

-- Schema management
GRANT CREATE SCHEMA ON DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT MODIFY ON ALL SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT MODIFY ON FUTURE SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT MONITOR ON ALL SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT MONITOR ON FUTURE SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;

-- Allow creating additional object types within schemas
GRANT CREATE STAGE ON ALL SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE STAGE ON FUTURE SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE FILE FORMAT ON ALL SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE FILE FORMAT ON FUTURE SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE SEQUENCE ON ALL SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE SEQUENCE ON FUTURE SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE FUNCTION ON ALL SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE FUNCTION ON FUTURE SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE PROCEDURE ON ALL SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE PROCEDURE ON FUTURE SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE STREAM ON ALL SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE STREAM ON FUTURE SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE TASK ON ALL SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE TASK ON FUTURE SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;

-------------------------------------------------------------------------------
-- 7. Wire the hierarchy: DB_ADMIN → account role
-------------------------------------------------------------------------------
USE ROLE SECURITYADMIN;

GRANT DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN TO ROLE "SF_APA_PAYROLL-DBA";
GRANT DATABASE ROLE DEV_PAYROLL_DB.DB_WRITER TO ROLE "SF_APA_PAYROLL-ETL";

-------------------------------------------------------------------------------
-- 8. Session policy: disable secondary roles for payroll users
-------------------------------------------------------------------------------
CREATE OR REPLACE SESSION POLICY DEV_PAYROLL_DB.PUBLIC.PAYROLL_SESSION_POLICY
    SESSION_IDLE_TIMEOUT_MINS    = 60
    SESSION_UI_IDLE_TIMEOUT_MINS = 30
    ALLOWED_SECONDARY_ROLES      = ()
    COMMENT = 'Disables secondary roles for payroll users — ensures visibility is limited to DEV_PAYROLL_DB only';

ALTER SESSION POLICY DEV_PAYROLL_DB.PUBLIC.PAYROLL_SESSION_POLICY SET TAG
    SNOWFLAKE.TAGS.PROJECT = 'SBI-Payroll';


-- Assign to a specific user
ALTER USER "CHHENGLIENG.HENG@SBI-GROUP.COM" SET SESSION POLICY DEV_PAYROLL_DB.PUBLIC.PAYROLL_SESSION_POLICY;
ALTER USER "PANAVATH.DINSOPHARY@SBI-GROUP.COM" SET SESSION POLICY DEV_PAYROLL_DB.PUBLIC.PAYROLL_SESSION_POLICY;



-------------------------------------------------------------------------------
-- 9. External OAuth — Microsoft Entra ID (service principal / client credentials)
-------------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

-- 9a. Security integration: lets Snowflake validate tokens from the Entra tenant
CREATE SECURITY INTEGRATION IF NOT EXISTS ENTRA_PAYROLL_OAUTH
    TYPE                                    = EXTERNAL_OAUTH
    ENABLED                                 = TRUE
    EXTERNAL_OAUTH_TYPE                     = AZURE
    EXTERNAL_OAUTH_ISSUER                   = 'https://sts.windows.net/77fc8d6c-15ec-4aea-9bd6-cf77b407a763/'
    EXTERNAL_OAUTH_JWS_KEYS_URL            = 'https://login.microsoftonline.com/77fc8d6c-15ec-4aea-9bd6-cf77b407a763/discovery/v2.0/keys'
    EXTERNAL_OAUTH_AUDIENCE_LIST            = ('api://a02caaa7-bf94-43e4-a619-79f457f7e635')
    EXTERNAL_OAUTH_TOKEN_USER_MAPPING_CLAIM = 'sub'
    EXTERNAL_OAUTH_SNOWFLAKE_USER_MAPPING_ATTRIBUTE = 'login_name'
    EXTERNAL_OAUTH_ALLOWED_ROLES_LIST = ('SF_APA_PAYROLL-ETL')
  ;

GRANT USAGE ON INTEGRATION ENTRA_PAYROLL_OAUTH TO ROLE "SF_APA_PAYROLL-ETL";

-- 9b. Service user: LOGIN_NAME must match the "sub" claim in the Entra token
--     (the Object ID of the Enterprise Application / service principal)
USE ROLE USERADMIN;
CREATE USER IF NOT EXISTS SBI_PAYROLL_SERVICE_USER
    LOGIN_NAME    = 'db392826-8418-4528-b697-2c60ecfdbae9'
    DISPLAY_NAME  = 'Payroll Entra Service Principal'
    DEFAULT_ROLE  = "SF_APA_PAYROLL-ETL"
    DEFAULT_WAREHOUSE  = "SANDBOX_WH"
    DEFAULT_NAMESPACE  = "DEV_PAYROLL_DB.APP"
    TYPE          = SERVICE
    COMMENT       = 'Service user for programmatic Entra ID OAuth access to payroll data';

-- 9c. Grant the required role
USE ROLE SECURITYADMIN;
GRANT ROLE "SF_APA_PAYROLL-ETL" TO USER SBI_PAYROLL_SERVICE_USER;

SELECT
    QUERY_TEXT,
    ERROR_CODE,
    ERROR_MESSAGE,
    EXECUTION_STATUS,
    START_TIME,
    WAREHOUSE_NAME,
    ROLE_NAME
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE USER_NAME = 'SBI_PAYROLL_SERVICE_USER'
  AND START_TIME >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC
LIMIT 30;

DESCRIBE INTEGRATION ENTRA_PAYROLL_OAUTH;
ALTER SECURITY INTEGRATION ENTRA_PAYROLL_OAUTH
    SET EXTERNAL_OAUTH_ALLOWED_ROLES_LIST = ('ANALYST', 'SF_APA_PAYROLL-DBA');

    USE ROLE ACCOUNTADMIN;

ALTER SECURITY INTEGRATION ENTRA_PAYROLL_OAUTH
    SET EXTERNAL_OAUTH_ALLOWED_ROLES_LIST = ('SF_APA_PAYROLL-ETL');

-------------------------------------------------------------------------------
-- 10. App role (SF_APA_PAYROLL-ETL) grants - re-run after every dbt build (was grants/grants.sql)
--     Written for dev (APP / RPT). For uat use APP_UAT / RPT_UAT.
-------------------------------------------------------------------------------
USE ROLE "SF_APA_PAYROLL-DBA";

/* =====================================================================================
   GRANTS FOR THE POWER APPS FLOW
   Gives the app's role, "SF_APA_PAYROLL-ETL", exactly what the "Payroll - SQL" flow needs:
     * SELECT on the 22 RPT views the app reads
     * USAGE (permission to call) on the 24 public procedures
   The procedures run with their owner's rights (EXECUTE AS OWNER), so calling them is
   enough to save data, and only through their checks.
   =====================================================================================

   HISTORY
   -------
   2026-10-05  Initial version (two app roles).
   2026-10-05  No grant on the database itself (USAGE on PAYROLL_DB is managed by IT;
               this file only grants on the schemas and their objects).
   2026-10-05  V_F_DASHBOARD_MONTH added (21 views).
   2026-10-05  V_F_PAYROLL_MONTH added (20 views).
   2026-10-05  SP_GET_EMPLOYEE_BANK added (24 public procedures).
   2026-10-05  One role only: "SF_APA_PAYROLL-ETL". Optional section 4 removes its direct
               rights on the APP tables.
   2026-10-06  SP_CREATE_SCENARIO granted with its new signature (sixth, optional parameter
               P_FX_RATE FLOAT).
   2026-10-19  Moved to grants/grants.sql for DLSync: PAYROLL_DB replaced by ${DB} (the deploy
               workflow substitutes DEV_PAYROLL_DB / PROD_PAYROLL_DB). SP_GET_EMPLOYEE_BANK retired:
               23 public procedures.
   2026-10-20  V_P_STATUTORY_PARAMETER and SP_SAVE_STATUTORY_PARAMETER added (22 views,
               24 public procedures).

   WHEN IT RUNS
   ------------
   Run by the deploy workflow after every DLSync deploy. Views and procedures carry
   COPY GRANTS, so a replaced object keeps its grants; this file also gives a grant to a
   new view or procedure. Run it by hand after a manual rebuild.
   Re-running it is harmless. Run it as the owner of the views and procedures
   (SF_APA_PAYROLL-DBA). ${DB} is DEV_PAYROLL_DB or PROD_DEV_PAYROLL_DB.

   NOT GRANTED ON PURPOSE
   ----------------------
   * The Power BI views (V_*_PBI_*): Power BI signs in on its own; V_D_PBI_EMPLOYEE_DETAILS
     and V_D_PBI_SIGNATURE hold data the app must not read.
   * SP_CALC_PERIOD and SP_RESET_APPROVALS: internal, only called by other procedures.
   ===================================================================================== */

/* -------------------------------------------------------------------------------------
   1. Start clean on views and procedures (removes anything granted earlier on them)
   ------------------------------------------------------------------------------------- */
REVOKE ALL PRIVILEGES ON ALL VIEWS      IN SCHEMA DEV_PAYROLL_DB.RPT FROM ROLE "SF_APA_PAYROLL-ETL";
REVOKE ALL PRIVILEGES ON ALL PROCEDURES IN SCHEMA DEV_PAYROLL_DB.APP FROM ROLE "SF_APA_PAYROLL-ETL";

/* -------------------------------------------------------------------------------------
   2. The 22 views the app reads
   ------------------------------------------------------------------------------------- */
GRANT USAGE ON SCHEMA DEV_PAYROLL_DB.RPT TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_D_EMPLOYEE             TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_D_SCENARIO             TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_PAYROLL_SUMMARY      TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_COST_ALLOCATION      TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_APPROVAL_EVENT       TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_DASHBOARD_KPI        TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_SCENARIO_SUMMARY     TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_BUDGET_VS_ACTUAL     TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_COST_CENTER_SUMMARY  TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_APPROVAL_PROGRESS    TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_D_PERIOD               TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_SCENARIO_PERIOD      TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_PAYROLL_INPUT        TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_ALLOCATION           TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_D_SCENARIO_EMPLOYEE    TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_PAYROLL_LINE         TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_D_LOOKUP               TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_P_APPROVAL_STEP        TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_D_APP_USER             TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_PAYROLL_MONTH        TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_F_DASHBOARD_MONTH      TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW DEV_PAYROLL_DB.RPT.V_P_STATUTORY_PARAMETER  TO ROLE "SF_APA_PAYROLL-ETL";

/* -------------------------------------------------------------------------------------
   3. The 24 public procedures (Snowflake identifies a procedure by its name and parameter
      types, so each line lists the exact types)
   ------------------------------------------------------------------------------------- */
GRANT USAGE ON SCHEMA DEV_PAYROLL_DB.APP TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_APPROVE_STEP(TEXT, INT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_CALCULATE_PAYROLL(TEXT, INT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_CREATE_FORECAST(TEXT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_CREATE_SCENARIO(TEXT, TEXT, INT, INT, TEXT, FLOAT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_DELETE_PLANNED_HIRE(TEXT, INT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_DELETE_SCENARIO(TEXT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_FINALIZE_PAYROLL(TEXT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_OPEN_PAYROLL_PERIOD(TEXT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_REJECT_STEP(TEXT, INT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SAVE_APPROVAL_STEPS(TEXT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SAVE_DEPARTMENT_ALLOCATION(TEXT, INT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SAVE_EMPLOYEE(TEXT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SAVE_EMPLOYEE_CONTRACT(TEXT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SAVE_EXCHANGE_RATE(TEXT, INT, FLOAT, FLOAT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SAVE_FUND_ALLOCATION(TEXT, INT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SAVE_MONTHLY_INPUT(TEXT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SAVE_PLANNED_HIRE(TEXT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SAVE_SCENARIO_EMPLOYEE(TEXT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SAVE_STATUTORY_PARAMETER(TEXT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SAVE_WORKING_DAYS(TEXT, TEXT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SET_EMPLOYEE_ACTIVE(TEXT, INT, BOOLEAN) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SET_EMPLOYEE_CHECK(TEXT, INT, INT, TEXT, TEXT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_SUBMIT_SCENARIO(TEXT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE DEV_PAYROLL_DB.APP.SP_UNDO_APPROVAL(TEXT, INT, INT, INT) TO ROLE "SF_APA_PAYROLL-ETL";

/* -------------------------------------------------------------------------------------
   4. OPTIONAL - remove the role's direct rights on the APP tables
   Recommended: then the flow can only read the views above and change data only through
   the procedures (bank details and the tables themselves are out of reach).
   Before switching it on, check that nothing else uses "SF_APA_PAYROLL-ETL" to read or
   write the APP tables directly (a data load, another tool), or it will stop working.
   If IT granted those rights, IT may have to revoke them.
   To switch it on, remove the "--" in front of the line below.
   ------------------------------------------------------------------------------------- */
-- REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA DEV_PAYROLL_DB.APP FROM ROLE "SF_APA_PAYROLL-ETL";

/* -------------------------------------------------------------------------------------
   5. Check. Expected: USAGE on RPT and APP (plus the database, from IT); SELECT on 22 views;
      USAGE on 24 procedures (plus table rights while section 4 is off).
   ------------------------------------------------------------------------------------- */
SHOW GRANTS TO ROLE "SF_APA_PAYROLL-ETL";