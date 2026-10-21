/* =================================================================
   SBI Payroll - Snowflake Setup 02: RBAC
   -----------------------------------------------------------------
   Run after 01_environment.sql. Idempotent (re-run any time).
   Run as: a user who can use USERADMIN, SYSADMIN, SECURITYADMIN, SF_APA_PAYROLL-DBA.

   Model (what Snowsight shows under Access):
     DEV_PAYROLL_DB   owner SYSADMIN
       DB_READER < DB_WRITER < DB_ADMIN    database roles, database-wide (ALL + FUTURE)
     MART, UAT        owner SF_APA_PAYROLL-DBA (schema owner creates tables/views/procs, so no CREATE TABLE/VIEW grants)

     SF_APA_PAYROLL-DBA   = DB_ADMIN + owns the schemas -> dbt deploy role, owns everything dbt builds
     SF_APA_PAYROLL-ETL   = app role (Power Automate)   -> USAGE on schema, SELECT on views, USAGE on procedures
   ================================================================= */

/* -----------------------------------------------------------------
   1. ACCOUNT ROLES (no account-level privileges)
   ----------------------------------------------------------------- */
USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS "SF_APA_PAYROLL-DBA"
    COMMENT = 'Database administrator role for DEV_PAYROLL_DB - database-level operations only, no account privileges';
CREATE ROLE IF NOT EXISTS "SF_APA_PAYROLL-ETL"
    COMMENT = 'Application role (Power Apps / Power Automate) - runs the SP_ procedures, reads the V_ views';

/* -----------------------------------------------------------------
   2. DATABASE ROLES (created by the database owner)
   ----------------------------------------------------------------- */
USE ROLE SYSADMIN;

CREATE DATABASE ROLE IF NOT EXISTS DEV_PAYROLL_DB.DB_READER
    COMMENT = 'Read-only access to all tables and views in DEV_PAYROLL_DB';
CREATE DATABASE ROLE IF NOT EXISTS DEV_PAYROLL_DB.DB_WRITER
    COMMENT = 'DB_READER + INSERT/UPDATE/DELETE/TRUNCATE on all tables in DEV_PAYROLL_DB';
CREATE DATABASE ROLE IF NOT EXISTS DEV_PAYROLL_DB.DB_ADMIN
    COMMENT = 'DB_WRITER + CREATE SCHEMA and management of stages, functions, procedures, streams, tasks';

/* -----------------------------------------------------------------
   3. HIERARCHY + OWNERSHIP + PRIVILEGES (SECURITYADMIN: global MANAGE GRANTS)
   ----------------------------------------------------------------- */
USE ROLE SECURITYADMIN;

GRANT DATABASE ROLE DEV_PAYROLL_DB.DB_READER TO DATABASE ROLE DEV_PAYROLL_DB.DB_WRITER;
GRANT DATABASE ROLE DEV_PAYROLL_DB.DB_WRITER TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN  TO ROLE "SF_APA_PAYROLL-DBA";

-- Schemas -> DBA (the database stays with SYSADMIN)
GRANT OWNERSHIP ON SCHEMA DEV_PAYROLL_DB.MART TO ROLE "SF_APA_PAYROLL-DBA" COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA DEV_PAYROLL_DB.UAT  TO ROLE "SF_APA_PAYROLL-DBA" COPY CURRENT GRANTS;

-- DB_READER
GRANT USAGE  ON ALL SCHEMAS    IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_READER;
GRANT USAGE  ON FUTURE SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_READER;
GRANT SELECT ON ALL TABLES     IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_READER;
GRANT SELECT ON FUTURE TABLES  IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_READER;
GRANT SELECT ON ALL VIEWS      IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_READER;
GRANT SELECT ON FUTURE VIEWS   IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_READER;

-- DB_WRITER
GRANT INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES    IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_WRITER;
GRANT INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_WRITER;

-- DB_ADMIN
GRANT CREATE SCHEMA, MONITOR ON DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE FILE FORMAT, CREATE FUNCTION, CREATE PROCEDURE, CREATE SEQUENCE, CREATE STAGE, CREATE STREAM, CREATE TASK, MODIFY, MONITOR
    ON ALL SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;
GRANT CREATE FILE FORMAT, CREATE FUNCTION, CREATE PROCEDURE, CREATE SEQUENCE, CREATE STAGE, CREATE STREAM, CREATE TASK, MODIFY, MONITOR
    ON FUTURE SCHEMAS IN DATABASE DEV_PAYROLL_DB TO DATABASE ROLE DEV_PAYROLL_DB.DB_ADMIN;

-- Account roles must reach the database (the ETL role had no database access before) and a warehouse
GRANT USAGE ON DATABASE DEV_PAYROLL_DB TO ROLE "SF_APA_PAYROLL-DBA";
GRANT USAGE ON DATABASE DEV_PAYROLL_DB TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON WAREHOUSE SANDBOX_WH    TO ROLE "SF_APA_PAYROLL-DBA";   -- shared, created elsewhere

/* -----------------------------------------------------------------
   4. APP ROLE (SF_APA_PAYROLL-ETL), per schema, granted by the schema owner
   FUTURE grants cover objects dbt re-creates (CREATE OR REPLACE view/procedure), so this
   does NOT need re-running after a build. ALL grants cover what exists today.
   Tables are deliberately not granted: the app writes only through SP_ procedures.
   TODO decision: the procedures are EXECUTE AS CALLER, so ETL still needs table DML to run them
   (either switch them to EXECUTE AS OWNER, or grant DML on tables here).
   ----------------------------------------------------------------- */
USE ROLE "SF_APA_PAYROLL-DBA";

GRANT USAGE  ON SCHEMA                DEV_PAYROLL_DB.MART TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON ALL VIEWS       IN SCHEMA DEV_PAYROLL_DB.MART TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON FUTURE VIEWS    IN SCHEMA DEV_PAYROLL_DB.MART TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE  ON ALL PROCEDURES  IN SCHEMA DEV_PAYROLL_DB.MART TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE  ON FUTURE PROCEDURES IN SCHEMA DEV_PAYROLL_DB.MART TO ROLE "SF_APA_PAYROLL-ETL";

GRANT USAGE  ON SCHEMA                DEV_PAYROLL_DB.UAT TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON ALL VIEWS       IN SCHEMA DEV_PAYROLL_DB.UAT TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON FUTURE VIEWS    IN SCHEMA DEV_PAYROLL_DB.UAT TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE  ON ALL PROCEDURES  IN SCHEMA DEV_PAYROLL_DB.UAT TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE  ON FUTURE PROCEDURES IN SCHEMA DEV_PAYROLL_DB.UAT TO ROLE "SF_APA_PAYROLL-ETL";


/* -----------------------------------------------------------------
   Check
   ----------------------------------------------------------------- */
SHOW GRANTS TO ROLE "SF_APA_PAYROLL-ETL";
SHOW GRANTS TO ROLE "SF_APA_PAYROLL-DBA";
SHOW GRANTS ON DATABASE DEV_PAYROLL_DB;
