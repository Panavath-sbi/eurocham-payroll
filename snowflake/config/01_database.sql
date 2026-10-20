-------------------------------------------------------------------------------
-- 01 DATABASE - EuroCham Payroll (run once, SYSADMIN)
-- Run order: 01 -> 03 (roles) -> 04 (warehouse) -> 02 (schemas, needs SF_APA_PAYROLL-DBA)
-------------------------------------------------------------------------------
USE ROLE SYSADMIN;

-- 1. Create the database
CREATE DATABASE IF NOT EXISTS DEV_PAYROLL_DB
    COMMENT = 'Payroll data development database for SBI APAC and customer payroll processing';
