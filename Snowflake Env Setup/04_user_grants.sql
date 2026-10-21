-- Service user: LOGIN_NAME must match the "sub" claim in the Entra token
--     (the Object ID of the Enterprise Application / service principal)
USE ROLE USERADMIN;

CREATE USER IF NOT EXISTS SBI_PAYROLL_SERVICE_USER
    LOGIN_NAME    = 'db392826-8418-4528-b697-2c60ecfdbae9'
    DISPLAY_NAME  = 'Payroll Entra Service Principal'
    DEFAULT_ROLE  = "SF_APA_PAYROLL-ETL"
    DEFAULT_WAREHOUSE  = "SANDBOX_WH"
    DEFAULT_NAMESPACE  = "DEV_PAYROLL_DB.APP"
    TYPE          = SERVICE
    COMMENT       = 'Service user for programmatic Entra ID OAuth access to payroll data';

GRANT ROLE "SF_APA_PAYROLL-ETL" TO USER SBI_PAYROLL_SERVICE_USER;
