-- depends_on: T_D_PERIOD
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

-- 2026-10-21  Initial version: one row per actual payroll month whose payslips were sent (or were being sent)
--             by the payslip flow. Written only by SP_START_PAYSLIP_RUN and SP_FINISH_PAYSLIP_RUN.
-- CREATE TABLE IF NOT EXISTS: safe to run on every deployment; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS APP.T_F_PAYSLIP_RUN (
    PERIOD_KEY      INT       NOT NULL COMMENT 'Actual payroll month whose payslips were sent (YYYYMM)',
    RUN_STATUS      TEXT      NOT NULL COMMENT 'SENDING (every PDF was ready, emails going out), SENT (every email sent) or FAILED (sending stopped part way; the flow does not retry, an admin decides)',
    EMPLOYEE_COUNT  INT       NOT NULL COMMENT 'Number of employees whose payslip was prepared for the month',
    STARTED_AT      TIMESTAMP NOT NULL COMMENT 'When sending started (every PDF was ready)',
    FINISHED_AT     TIMESTAMP          COMMENT 'When the run ended as SENT or FAILED; NULL while SENDING',
    RUN_MESSAGE     TEXT               COMMENT 'Error reported by the flow when the run FAILED; NULL otherwise',
    INSERT_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE     TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row (the flow''s system user)',
    UPDATE_BY       TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row (the flow''s system user)',
    CONSTRAINT PK_T_F_PAYSLIP_RUN PRIMARY KEY (PERIOD_KEY),
    CONSTRAINT FK_PAYSLIP_RUN_PERIOD FOREIGN KEY (PERIOD_KEY) REFERENCES APP.T_D_PERIOD (PERIOD_KEY)
) COMMENT = 'Payslip run log: one row per actual payroll month once its payslips start going out. A month with a row is never sent again automatically; deleting the row lets the flow send the whole month again.';
