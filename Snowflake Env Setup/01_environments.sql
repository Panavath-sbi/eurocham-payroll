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
CREATE SCHEMA IF NOT EXISTS {{ database }}.MART
    COMMENT = 'SBI Payroll - development (dbt target dev)';
CREATE SCHEMA IF NOT EXISTS {{ database }}.UAT
    COMMENT = 'SBI Payroll - user acceptance testing (dbt target uat)';
