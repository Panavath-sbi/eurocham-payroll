-- depends_on: T_F_SCENARIO_PERIOD, T_D_EMPLOYEE
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.2; V1.5.0 added CHECK_STATUS, CHECK_COMMENT and CHECKED_BY).
-- CREATE TABLE IF NOT EXISTS: safe to run on every deployment; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS {{ schema_app }}.T_F_PAYROLL_INPUT (
    SCENARIO_ID          INT       NOT NULL COMMENT 'Scenario (actual, budget or forecast)',
    PERIOD_KEY           INT       NOT NULL COMMENT 'Period',
    EMPLOYEE_ID          INT       NOT NULL COMMENT 'Employee',
    INCLUDE_IN_PAYROLL   BOOLEAN   NOT NULL DEFAULT TRUE COMMENT 'FALSE excludes the employee from this period',
    ABSENCE_DAYS         FLOAT     NOT NULL DEFAULT 0 COMMENT 'Unpaid absence days',
    OVERTIME_DAYS        FLOAT     NOT NULL DEFAULT 0 COMMENT 'Overtime expressed in days',
    OUTSTANDING_DAYS     FLOAT     NOT NULL DEFAULT 0 COMMENT 'Unused paid leave days paid out at the daily rate',
    BONUS_USD            FLOAT     NOT NULL DEFAULT 0 COMMENT 'Bonus paid in this period (USD)',
    SALARY_OVERRIDE_USD  FLOAT              COMMENT 'Budget/forecast only: replaces the scenario salary for this one month; NULL = use scenario terms',
    FRINGE_BENEFIT_OVERRIDE_USD FLOAT       COMMENT 'Budget/forecast only: replaces the scenario fringe benefit for this one month; NULL = use scenario terms',
    NOTES                TEXT               COMMENT 'Free-text note for reviewers',
    INSERT_DATE          TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE          TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY            TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY            TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CHECK_STATUS         TEXT      DEFAULT 'PENDING' COMMENT 'Actual payroll only: PENDING, CHECKED or REJECTED by the approval step that checks employees (step 2). Back to PENDING when the employee''s numbers change.',
    CHECK_COMMENT        TEXT               COMMENT 'Actual payroll only: reason the employee was rejected, or another note from the checker',
    CHECKED_BY           TEXT               COMMENT 'Actual payroll only: app user who checked or rejected the employee; NULL while PENDING',
    CONSTRAINT PK_T_F_PAYROLL_INPUT PRIMARY KEY (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID),
    CONSTRAINT FK_INPUT_SP FOREIGN KEY (SCENARIO_ID, PERIOD_KEY) REFERENCES {{ schema_app }}.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY),
    CONSTRAINT FK_INPUT_EMPLOYEE FOREIGN KEY (EMPLOYEE_ID) REFERENCES {{ schema_app }}.T_D_EMPLOYEE (EMPLOYEE_ID)
) COMMENT = 'Monthly variable inputs per employee, plus (actual payroll) the employee check made during approval. For forecasts, rows act as user overrides on top of the projection.';
