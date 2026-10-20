-------------------------------------------------------------------------------
-- 02 SCHEMAS - per dbt target in "EuroCham Payroll dbt/profiles.yml" (same database, only the schemas differ)
--   dev -> DEV_PAYROLL_DB.APP + RPT      uat -> DEV_PAYROLL_DB.APP_UAT + RPT_UAT
--   (tables + procedures in APP*, views in RPT*: macros/generate_schema_name.sql)
-- Run as SF_APA_PAYROLL-DBA (CREATE SCHEMA via DB_ADMIN) so it owns the schemas and everything dbt builds in them.
-------------------------------------------------------------------------------
USE ROLE "SF_APA_PAYROLL-DBA";

CREATE SCHEMA IF NOT EXISTS DEV_PAYROLL_DB.APP
    COMMENT = 'EuroCham Payroll - development: tables and procedures (dbt target dev)';
CREATE SCHEMA IF NOT EXISTS DEV_PAYROLL_DB.RPT
    COMMENT = 'EuroCham Payroll - development: views (dbt target dev)';
CREATE SCHEMA IF NOT EXISTS DEV_PAYROLL_DB.APP_UAT
    COMMENT = 'EuroCham Payroll - user acceptance testing: tables and procedures (dbt target uat)';
CREATE SCHEMA IF NOT EXISTS DEV_PAYROLL_DB.RPT_UAT
    COMMENT = 'EuroCham Payroll - user acceptance testing: views (dbt target uat)';
