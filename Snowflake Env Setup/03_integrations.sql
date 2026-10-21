-- 03 INTEGRATIONS
USE ROLE ACCOUNTADMIN;

--  Security integration: lets Snowflake validate tokens from the Entra tenant
CREATE SECURITY INTEGRATION IF NOT EXISTS {{ oauth_integration }}
    TYPE                                    = EXTERNAL_OAUTH
    ENABLED                                 = TRUE
    EXTERNAL_OAUTH_TYPE                     = AZURE
    EXTERNAL_OAUTH_ISSUER                   = 'https://sts.windows.net/{{ entra_tenant_id }}/'
    EXTERNAL_OAUTH_JWS_KEYS_URL            = 'https://login.microsoftonline.com/{{ entra_tenant_id }}/discovery/v2.0/keys'
    EXTERNAL_OAUTH_AUDIENCE_LIST            = ('{{ entra_audience }}')
    EXTERNAL_OAUTH_TOKEN_USER_MAPPING_CLAIM = 'sub'
    EXTERNAL_OAUTH_SNOWFLAKE_USER_MAPPING_ATTRIBUTE = 'login_name'
    EXTERNAL_OAUTH_ALLOWED_ROLES_LIST = ('{{ role_app }}')
  ;
