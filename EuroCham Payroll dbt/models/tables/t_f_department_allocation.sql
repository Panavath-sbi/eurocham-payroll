-- depends_on: {{ ref('t_f_scenario_period') }}, {{ ref('t_d_employee') }}, {{ ref('t_d_department') }}
-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created by V1.0.2).
-- CREATE TABLE IF NOT EXISTS: dbt runs this on every build; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS {{ app() }}.T_F_DEPARTMENT_ALLOCATION (
    SCENARIO_ID      INT       NOT NULL COMMENT 'Scenario',
    PERIOD_KEY       INT       NOT NULL COMMENT 'Period',
    EMPLOYEE_ID      INT       NOT NULL COMMENT 'Employee',
    DEPARTMENT_CODE  TEXT      NOT NULL COMMENT 'Department charged',
    SHARE_PCT        FLOAT     NOT NULL COMMENT 'Share of cost charged to the department (0-100); shares per employee must total 100',
    INSERT_DATE      TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE      TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY        TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY        TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    CONSTRAINT PK_T_F_DEPARTMENT_ALLOCATION PRIMARY KEY (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, DEPARTMENT_CODE),
    CONSTRAINT FK_DEPT_ALLOC_SP FOREIGN KEY (SCENARIO_ID, PERIOD_KEY) REFERENCES {{ app() }}.T_F_SCENARIO_PERIOD (SCENARIO_ID, PERIOD_KEY),
    CONSTRAINT FK_DEPT_ALLOC_EMP FOREIGN KEY (EMPLOYEE_ID) REFERENCES {{ app() }}.T_D_EMPLOYEE (EMPLOYEE_ID),
    CONSTRAINT FK_DEPT_ALLOC_DEPT FOREIGN KEY (DEPARTMENT_CODE) REFERENCES {{ app() }}.T_D_DEPARTMENT (DEPARTMENT_CODE)
) COMMENT = 'Department split per employee and period, as percentages. Replaces the PCT_* columns.';
