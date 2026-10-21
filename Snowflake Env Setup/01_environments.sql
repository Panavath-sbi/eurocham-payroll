-------------------------------------------------------------------------------
-- 01 ENVIRONMENT - SBI Payroll: database, schemas
-- Warehouse {{ warehouse }} is shared and created elsewhere.
-------------------------------------------------------------------------------
USE ROLE SYSADMIN;

-------------------------------------------------------------------------------
-- 1. DATABASE
-------------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS {{ database }}
    COMMENT = 'Payroll data development database for SBI APAC and customer payroll processing';

-------------------------------------------------------------------------------
-- 2. SCHEMAS
-------------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS {{ database }}.{{ schema_app }}
    COMMENT = 'EuroCham Payroll - UAT tables and procedures (dbt target uat)';
CREATE SCHEMA IF NOT EXISTS {{ database }}.{{ schema_rpt }}
    COMMENT = 'EuroCham Payroll - UAT views (dbt target uat)';
