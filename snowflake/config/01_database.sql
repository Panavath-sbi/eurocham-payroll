-------------------------------------------------------------------------------
-- 01 DATABASE - EuroCham Payroll (run once, SYSADMIN)
-------------------------------------------------------------------------------
USE ROLE SYSADMIN;

-- 1. Create the database
CREATE DATABASE IF NOT EXISTS <PROD>_PAYROLL_DB
    COMMENT = 'Payroll data development database for SBI APAC and customer payroll processing';
