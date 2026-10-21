/* =================================================================
   SBI Payroll - Snowflake Setup 02: ROLES (create only)
   -----------------------------------------------------------------
   Run after 01_environments.sql. Idempotent (re-run any time).
   All privileges, hierarchy and ownership live in 05_grants.sql.

   Model (what Snowsight shows under Access):
     {{ database }}   owner SYSADMIN
       DB_READER < DB_WRITER < DB_ADMIN    database roles, database-wide (ALL + FUTURE)
     {{ schema_app }}, {{ schema_rpt }}  owner {{ role_dba }} (schema owner creates tables/views/procs, so no CREATE TABLE/VIEW grants)

     {{ role_dba }}   = DB_ADMIN + owns the schemas -> dbt deploy role, owns everything dbt builds
     {{ role_app }}   = app role (Power Automate)   -> USAGE on schema, SELECT on views, USAGE on procedures
   ================================================================= */

/* -----------------------------------------------------------------
   1. ACCOUNT ROLES (no account-level privileges)
   ----------------------------------------------------------------- */
USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS "{{ role_dba }}"
    COMMENT = 'Database administrator role for {{ database }} - database-level operations only, no account privileges';
CREATE ROLE IF NOT EXISTS "{{ role_app }}"
    COMMENT = 'Application role (Power Apps / Power Automate) - runs the SP_ procedures, reads the V_ views';

/* -----------------------------------------------------------------
   2. DATABASE ROLES (created by the database owner)
   ----------------------------------------------------------------- */
USE ROLE SYSADMIN;

CREATE DATABASE ROLE IF NOT EXISTS {{ database }}.DB_READER
    COMMENT = 'Read-only access to all tables and views in {{ database }}';
CREATE DATABASE ROLE IF NOT EXISTS {{ database }}.DB_WRITER
    COMMENT = 'DB_READER + INSERT/UPDATE/DELETE/TRUNCATE on all tables in {{ database }}';
CREATE DATABASE ROLE IF NOT EXISTS {{ database }}.DB_ADMIN
    COMMENT = 'DB_WRITER + CREATE SCHEMA and management of stages, functions, procedures, streams, tasks';
