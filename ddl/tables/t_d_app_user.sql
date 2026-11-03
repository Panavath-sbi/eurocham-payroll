-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.2; V1.5.0 added ROLE_CODE and SIGNATURE_IMAGE, V1.7.0 set the final ROLE_CODE comment).
-- 2026-10-21  Table name qualified with the app() schema macro like the other table files (was unqualified).
--             Reference row added: the payslip flow's system user (below).
-- CREATE OR REPLACE TABLE: safe to run on every deployment; an existing table keeps its rows.
CREATE OR REPLACE TABLE APP.T_D_APP_USER (
    USER_EMAIL           TEXT      NOT NULL                            COMMENT 'Login email of the app user',
    DISPLAY_NAME         TEXT      NOT NULL                            COMMENT 'Name shown on approvals and audit screens',
    IS_ACTIVE            BOOLEAN   NOT NULL DEFAULT TRUE               COMMENT 'Inactive users cannot act in the app',
    INSERT_DATE          TIMESTAMP          DEFAULT CURRENT_TIMESTAMP  COMMENT 'Row creation timestamp',
    UPDATE_DATE          TIMESTAMP          DEFAULT CURRENT_TIMESTAMP  COMMENT 'Last update timestamp',
    INSERT_BY            TEXT               DEFAULT CURRENT_USER       COMMENT 'User who created the row',
    UPDATE_BY            TEXT               DEFAULT CURRENT_USER       COMMENT 'User who last updated the row',
    ROLE_CODE            TEXT                                          COMMENT 'The user''s one role: ADMIN (every approval step; set in Snowflake only), LEVEL_1, LEVEL_2 or LEVEL_3 (approves that step). Every active user may use every other function.',
    SIGNATURE_IMAGE      TEXT                                          COMMENT 'E-signature image as Base64 (PNG), used by the Power BI report; NULL = no signature',
    
    CONSTRAINT PK_T_D_APP_USER PRIMARY KEY (USER_EMAIL)
) 
COMMENT = 'Users of the payroll app, with their one role (checked by the procedures) and their e-signature.';