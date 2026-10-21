-------------------------------------------------------------------------------
-- 01 ENVIRONMENT - SBI Payroll: warehouse, database, schemas 
-------------------------------------------------------------------------------
USE ROLE SYSADMIN;

-------------------------------------------------------------------------------
-- 2. DATABASE
-------------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS DEV_PAYROLL_DB
    COMMENT = 'Payroll data development database for SBI APAC and customer payroll processing';

-------------------------------------------------------------------------------
-- 3. SCHEMAS (PUBLIC is kept: the session policy in 02_rbac_roles.sql lives there)
-------------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS DEV_PAYROLL_DB.MART
    COMMENT = 'SBI Payroll - development (dbt target dev)';
CREATE SCHEMA IF NOT EXISTS DEV_PAYROLL_DB.UAT
    COMMENT = 'SBI Payroll - user acceptance testing (dbt target uat)';
