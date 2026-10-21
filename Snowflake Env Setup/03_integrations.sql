USE ROLE ACCOUNTADMIN;

--  Security integration: lets Snowflake validate tokens from the Entra tenant
CREATE SECURITY INTEGRATION IF NOT EXISTS ENTRA_PAYROLL_OAUTH
    TYPE                                    = EXTERNAL_OAUTH
    ENABLED                                 = TRUE
    EXTERNAL_OAUTH_TYPE                     = AZURE
    EXTERNAL_OAUTH_ISSUER                   = 'https://sts.windows.net/77fc8d6c-15ec-4aea-9bd6-cf77b407a763/'
    EXTERNAL_OAUTH_JWS_KEYS_URL            = 'https://login.microsoftonline.com/77fc8d6c-15ec-4aea-9bd6-cf77b407a763/discovery/v2.0/keys'
    EXTERNAL_OAUTH_AUDIENCE_LIST            = ('api://a02caaa7-bf94-43e4-a619-79f457f7e635')
    EXTERNAL_OAUTH_TOKEN_USER_MAPPING_CLAIM = 'sub'
    EXTERNAL_OAUTH_SNOWFLAKE_USER_MAPPING_ATTRIBUTE = 'login_name'
    EXTERNAL_OAUTH_ALLOWED_ROLES_LIST = ('SF_APA_PAYROLL-ETL')
  ;

GRANT USAGE ON INTEGRATION ENTRA_PAYROLL_OAUTH TO ROLE "SF_APA_PAYROLL-ETL";
