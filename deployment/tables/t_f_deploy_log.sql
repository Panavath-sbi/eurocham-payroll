USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

-- 2026-10-26  Initial version: deployment log written by deploy.py (one row per run with RUN / --run).
-- CREATE TABLE IF NOT EXISTS: safe to run on every deployment; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS APP.T_F_DEPLOY_LOG (
    DEPLOY_ID             INT           IDENTITY(1,1) NOT NULL COMMENT 'Run number',
    ENV                   TEXT          NOT NULL COMMENT 'Environment block of config.yml: uat or prod',
    STATUS                TEXT          NOT NULL COMMENT 'CONFIRMED, NOT CONFIRMED (verification found problems) or FAILED (a statement failed)',
    SCRIPTS_RUN           INT                    COMMENT 'Scripts executed: all of DEPLOY_ORDER, or the ONLY subset',
    CHANGED_SCRIPTS       TEXT                   COMMENT 'Scripts changed in git since the last CONFIRMED deployment of this ENV; NULL outside a git checkout (Snowsight)',
    OBJECTS_ADDED_REMOVED TEXT                   COMMENT 'Tables / views / procedures that appeared or disappeared during the run, e.g. added: table T_NEW; removed: table T_OLD',
    FAILED_SCRIPT         TEXT                   COMMENT 'Script that stopped the run (FAILED only)',
    ERROR_MESSAGE         TEXT                   COMMENT 'First line of the Snowflake error, or the verification problems',
    VERIFY_SUMMARY        TEXT                   COMMENT 'Verification counts, e.g. tables in APP 22/22; views in RPT 30/30; ...; unexpected none',
    GIT_COMMIT            TEXT                   COMMENT 'Commit deployed (GitHub Actions); NULL from Snowsight',
    TRIGGERED_BY          TEXT                   COMMENT 'GitHub user who pushed / merged, or the Snowflake user outside GitHub Actions',
    RUN_URL               TEXT                   COMMENT 'Link to the GitHub Actions run',
    STARTED_AT            TIMESTAMP_NTZ          COMMENT 'Run start',
    FINISHED_AT           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP::TIMESTAMP_NTZ COMMENT 'Run end',
    DEPLOYED_BY           TEXT          DEFAULT CURRENT_USER COMMENT 'Snowflake user that ran the deployment',
    CONSTRAINT PK_T_F_DEPLOY_LOG PRIMARY KEY (DEPLOY_ID)
) COMMENT = 'Deployment log written by deploy.py: one row per deployment run, never deleted.';
