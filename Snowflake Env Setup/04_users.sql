-- 04 USERS (create only - role grants live in 05_grants.sql)
-- Service user: LOGIN_NAME must match the "sub" claim in the Entra token
--     (the Object ID of the Enterprise Application / service principal)
USE ROLE USERADMIN;

CREATE USER IF NOT EXISTS {{ service_user }}
    LOGIN_NAME    = '{{ service_user_login }}'
    DISPLAY_NAME  = 'Payroll Entra Service Principal'
    DEFAULT_ROLE  = "{{ role_app }}"
    DEFAULT_WAREHOUSE  = "{{ warehouse }}"
    DEFAULT_NAMESPACE  = "{{ database }}.{{ service_user_schema }}"
    TYPE          = SERVICE
    COMMENT       = 'Service user for programmatic Entra ID OAuth access to payroll data';
