-- 06 VERIFY - read-only checks after 01-05
USE ROLE SECURITYADMIN;

SHOW GRANTS TO ROLE "{{ role_app }}";
SHOW GRANTS TO ROLE "{{ role_dba }}";
SHOW GRANTS ON DATABASE {{ database }};
SHOW GRANTS TO USER {{ service_user }};
SHOW FUTURE GRANTS IN SCHEMA {{ database }}.MART;
SHOW FUTURE GRANTS IN SCHEMA {{ database }}.UAT;
