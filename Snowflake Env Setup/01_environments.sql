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
USE DATABASE {{ database }};

CREATE SCHEMA IF NOT EXISTS APP
    COMMENT = 'EuroCham Payroll - Tables and procedures';
CREATE SCHEMA IF NOT EXISTS RPT
    COMMENT = 'EuroCham Payroll - views';
