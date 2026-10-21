/* =================================================================
   SBI Payroll - Snowflake Setup 05: GRANTS (single source of truth)
   -----------------------------------------------------------------
   Run after 01-04 (every role, user and integration must exist).
   Idempotent (re-run any time). Sections are grouped by GRANTOR role.
   ================================================================= */

/* -----------------------------------------------------------------
   1. SECURITYADMIN (global MANAGE GRANTS)
   ----------------------------------------------------------------- */
USE ROLE SECURITYADMIN;

-- 1a. Role hierarchy
GRANT DATABASE ROLE {{ database }}.DB_READER TO DATABASE ROLE {{ database }}.DB_WRITER;
GRANT DATABASE ROLE {{ database }}.DB_WRITER TO DATABASE ROLE {{ database }}.DB_ADMIN;
GRANT DATABASE ROLE {{ database }}.DB_ADMIN  TO ROLE "{{ role_dba }}";

-- 1b. Ownership: schemas -> DBA (the database stays with SYSADMIN).
--     Must run before section 2, where DBA grants as schema owner.
GRANT OWNERSHIP ON SCHEMA {{ database }}.MART TO ROLE "{{ role_dba }}" COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA {{ database }}.UAT  TO ROLE "{{ role_dba }}" COPY CURRENT GRANTS;

-- 1c. DB_READER
GRANT USAGE  ON ALL SCHEMAS    IN DATABASE {{ database }} TO DATABASE ROLE {{ database }}.DB_READER;
GRANT USAGE  ON FUTURE SCHEMAS IN DATABASE {{ database }} TO DATABASE ROLE {{ database }}.DB_READER;
GRANT SELECT ON ALL TABLES     IN DATABASE {{ database }} TO DATABASE ROLE {{ database }}.DB_READER;
GRANT SELECT ON FUTURE TABLES  IN DATABASE {{ database }} TO DATABASE ROLE {{ database }}.DB_READER;
GRANT SELECT ON ALL VIEWS      IN DATABASE {{ database }} TO DATABASE ROLE {{ database }}.DB_READER;
GRANT SELECT ON FUTURE VIEWS   IN DATABASE {{ database }} TO DATABASE ROLE {{ database }}.DB_READER;
-- Schema-level FUTURE grants override database-level ones for the same object type.
-- MART/UAT have schema-level FUTURE VIEWS (section 2), so DB_READER must be repeated here.
GRANT SELECT ON FUTURE VIEWS   IN SCHEMA {{ database }}.MART TO DATABASE ROLE {{ database }}.DB_READER;
GRANT SELECT ON FUTURE VIEWS   IN SCHEMA {{ database }}.UAT  TO DATABASE ROLE {{ database }}.DB_READER;

-- 1d. DB_WRITER
GRANT INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES    IN DATABASE {{ database }} TO DATABASE ROLE {{ database }}.DB_WRITER;
GRANT INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN DATABASE {{ database }} TO DATABASE ROLE {{ database }}.DB_WRITER;

-- 1e. DB_ADMIN
GRANT CREATE SCHEMA, MONITOR ON DATABASE {{ database }} TO DATABASE ROLE {{ database }}.DB_ADMIN;
GRANT CREATE FILE FORMAT, CREATE FUNCTION, CREATE PROCEDURE, CREATE SEQUENCE, CREATE STAGE, CREATE STREAM, CREATE TASK, MODIFY, MONITOR
    ON ALL SCHEMAS IN DATABASE {{ database }} TO DATABASE ROLE {{ database }}.DB_ADMIN;
GRANT CREATE FILE FORMAT, CREATE FUNCTION, CREATE PROCEDURE, CREATE SEQUENCE, CREATE STAGE, CREATE STREAM, CREATE TASK, MODIFY, MONITOR
    ON FUTURE SCHEMAS IN DATABASE {{ database }} TO DATABASE ROLE {{ database }}.DB_ADMIN;

-- 1f. Account roles -> database + warehouse
GRANT USAGE ON DATABASE  {{ database }} TO ROLE "{{ role_dba }}";
GRANT USAGE ON DATABASE  {{ database }} TO ROLE "{{ role_app }}";
GRANT USAGE ON WAREHOUSE {{ warehouse }}     TO ROLE "{{ role_dba }}";   -- shared, created elsewhere
GRANT USAGE ON WAREHOUSE {{ warehouse }}     TO ROLE "{{ role_app }}";   -- service user's DEFAULT_WAREHOUSE

-- 1g. Integrations
GRANT USAGE ON INTEGRATION {{ oauth_integration }} TO ROLE "{{ role_app }}";

-- 1h. Roles -> users
GRANT ROLE "{{ role_app }}" TO USER {{ service_user }};

/* -----------------------------------------------------------------
   2. {{ role_dba }} (schema owner) -> app role, per schema
   FUTURE grants cover objects dbt re-creates (CREATE OR REPLACE view/procedure), so this
   does NOT need re-running after a build. ALL grants cover what exists today.
   Tables are deliberately not granted: the app writes only through SP_ procedures.
   TODO decision: the procedures are EXECUTE AS CALLER, so ETL still needs table DML to run them
   (either switch them to EXECUTE AS OWNER, or grant DML on tables here).
   ----------------------------------------------------------------- */
USE ROLE "{{ role_dba }}";

GRANT USAGE  ON SCHEMA                   {{ database }}.MART TO ROLE "{{ role_app }}";
GRANT SELECT ON ALL VIEWS         IN SCHEMA {{ database }}.MART TO ROLE "{{ role_app }}";
GRANT SELECT ON FUTURE VIEWS      IN SCHEMA {{ database }}.MART TO ROLE "{{ role_app }}";
GRANT USAGE  ON ALL PROCEDURES    IN SCHEMA {{ database }}.MART TO ROLE "{{ role_app }}";
GRANT USAGE  ON FUTURE PROCEDURES IN SCHEMA {{ database }}.MART TO ROLE "{{ role_app }}";

GRANT USAGE  ON SCHEMA                   {{ database }}.UAT TO ROLE "{{ role_app }}";
GRANT SELECT ON ALL VIEWS         IN SCHEMA {{ database }}.UAT TO ROLE "{{ role_app }}";
GRANT SELECT ON FUTURE VIEWS      IN SCHEMA {{ database }}.UAT TO ROLE "{{ role_app }}";
GRANT USAGE  ON ALL PROCEDURES    IN SCHEMA {{ database }}.UAT TO ROLE "{{ role_app }}";
GRANT USAGE  ON FUTURE PROCEDURES IN SCHEMA {{ database }}.UAT TO ROLE "{{ role_app }}";
