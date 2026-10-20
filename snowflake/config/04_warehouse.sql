-------------------------------------------------------------------------------
-- 04 WAREHOUSE - SANDBOX_WH is shared and already exists (not created here); usage grants only.
-------------------------------------------------------------------------------
USE ROLE SECURITYADMIN;

GRANT USAGE ON WAREHOUSE SANDBOX_WH TO ROLE "SF_APA_PAYROLL-DBA";
GRANT USAGE ON WAREHOUSE SANDBOX_WH TO ROLE "SF_APA_PAYROLL-ETL";
