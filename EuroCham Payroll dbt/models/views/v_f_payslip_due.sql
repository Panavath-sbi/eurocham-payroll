-- depends_on: {{ ref('t_d_period') }}, {{ ref('t_d_scenario') }}, {{ ref('t_f_scenario_period') }}, {{ ref('t_f_payslip_run') }}
/* =====================================================================================
   V_F_PAYSLIP_DUE - What the payslip flow must do today, per actual payroll month
   =====================================================================================

   HISTORY
   -------
   2026-10-21  Initial version: pay date, reminder window and the action of the day for
               the daily payslip flow.

   NOTES
   -----
   * Every date is Phnom Penh time. The Snowflake account runs on US Pacific time, so
     "today" and FINALIZED_AT are converted. FINALIZED_AT is stored without a time zone
     in the session time zone of the app's connection; it is read back in the session
     time zone of the flow's connection (the same account default).
   * Months from 202610 (START_PERIOD_KEY below) up to the current month. Earlier months
     are never sent or reminded about.
   * Pay date = the last Monday-Friday of the month (no holiday calendar: pay only ever
     moves earlier, so a payslip sent after this date is always after the pay).
   * Reminders start 5 working days before the pay date (= 7 calendar days, since the
     pay date is a weekday) and are sent on weekdays only.
   * Payslips are sent from the day after the pay date, once the month is finalized,
     only if it was finalized before today (the Power BI model refreshes at 00:00, so
     the payslip report has the final figures), and only if the month has no row in
     APP.T_F_PAYSLIP_RUN yet.

   ACTION
   ------
   SEND         Send the month's payslips now.
   REMIND       Not finalized, pay date within the next 5 working days (weekdays only).
   OVERDUE      Not finalized and the pay date has passed (weekdays only).
   RUN_PROBLEM  A run of this month is still SENDING from an earlier day, or FAILED:
                the flow does not retry; it tells the admin every day until the row is
                fixed (deleted to send again, or set to SENT by hand).
   NONE         Nothing to do today (too early, waiting for the pay date, waiting for the
                next model refresh, already sent, or a weekend).
   ===================================================================================== */
CREATE OR REPLACE VIEW {{ rpt() }}.V_F_PAYSLIP_DUE (
    PERIOD_KEY                    COMMENT 'Actual payroll month (YYYYMM)',
    PERIOD_LABEL                  COMMENT 'Month and year, e.g. October 2026',
    PAY_DATE                      COMMENT 'Last Monday-Friday of the month',
    REMIND_FROM                   COMMENT 'First reminder day: 5 working days before the pay date',
    PERIOD_STATUS                 COMMENT 'NOT_OPENED, OPEN, IN_APPROVAL or FINALIZED',
    FINALIZED_AT_LOCAL            COMMENT 'When the month was finalized, Phnom Penh time; NULL if not finalized',
    RUN_STATUS                    COMMENT 'Status in APP.T_F_PAYSLIP_RUN (SENDING, SENT, FAILED); NULL = not sent yet',
    RUN_STARTED_AT                COMMENT 'When the logged run started (Snowflake account time); NULL = not sent yet',
    TODAY_LOCAL                   COMMENT 'Today in Phnom Penh',
    ACTION                        COMMENT 'SEND, REMIND, OVERDUE, RUN_PROBLEM or NONE (see the file header)'
)
COPY GRANTS
COMMENT = 'Payslip flow: one row per actual payroll month from 202610 to the current month, with its pay date and what the flow must do today.'
AS
WITH today AS (
    SELECT CONVERT_TIMEZONE('Asia/Phnom_Penh', CURRENT_TIMESTAMP())::DATE AS D
),
months AS (
    SELECT p.PERIOD_KEY, p.MONTH_NAME || ' ' || p.YEAR AS PERIOD_LABEL,
           CASE DAYOFWEEKISO(p.PERIOD_END_DATE)
               WHEN 6 THEN DATEADD('day', -1, p.PERIOD_END_DATE)
               WHEN 7 THEN DATEADD('day', -2, p.PERIOD_END_DATE)
               ELSE p.PERIOD_END_DATE
           END AS PAY_DATE
    FROM {{ app() }}.T_D_PERIOD p, today t
    WHERE p.PERIOD_KEY >= 202610                       -- START_PERIOD_KEY
      AND p.PERIOD_START_DATE <= t.D
),
state AS (
    SELECT m.PERIOD_KEY, m.PERIOD_LABEL, m.PAY_DATE,
           DATEADD('day', -7, m.PAY_DATE)                                            AS REMIND_FROM,
           COALESCE(sp.PERIOD_STATUS, 'NOT_OPENED')                                  AS PERIOD_STATUS,
           CONVERT_TIMEZONE('Asia/Phnom_Penh', sp.FINALIZED_AT::TIMESTAMP_LTZ)::TIMESTAMP_NTZ AS FINALIZED_AT_LOCAL,
           r.RUN_STATUS,
           r.STARTED_AT                                                              AS RUN_STARTED_AT,
           CONVERT_TIMEZONE('Asia/Phnom_Penh', r.STARTED_AT::TIMESTAMP_LTZ)::DATE   AS RUN_STARTED_LOCAL,
           t.D                                                                       AS TODAY_LOCAL
    FROM months m
    CROSS JOIN today t
    LEFT JOIN {{ app() }}.T_D_SCENARIO s ON s.SCENARIO_TYPE = 'ACTUAL'
    LEFT JOIN {{ app() }}.T_F_SCENARIO_PERIOD sp ON sp.SCENARIO_ID = s.SCENARIO_ID AND sp.PERIOD_KEY = m.PERIOD_KEY
    LEFT JOIN {{ app() }}.T_F_PAYSLIP_RUN r      ON r.PERIOD_KEY = m.PERIOD_KEY
)
SELECT
    PERIOD_KEY, PERIOD_LABEL, PAY_DATE, REMIND_FROM, PERIOD_STATUS, FINALIZED_AT_LOCAL,
    RUN_STATUS, RUN_STARTED_AT, TODAY_LOCAL,
    CASE
        WHEN RUN_STATUS = 'FAILED'
          OR (RUN_STATUS = 'SENDING' AND RUN_STARTED_LOCAL < TODAY_LOCAL)            THEN 'RUN_PROBLEM'
        WHEN RUN_STATUS IS NOT NULL                                                    THEN 'NONE'
        WHEN PERIOD_STATUS = 'FINALIZED'
         AND TODAY_LOCAL > PAY_DATE
         AND FINALIZED_AT_LOCAL::DATE < TODAY_LOCAL                                    THEN 'SEND'
        WHEN PERIOD_STATUS = 'FINALIZED'                                               THEN 'NONE'
        WHEN DAYOFWEEKISO(TODAY_LOCAL) > 5                                             THEN 'NONE'
        WHEN TODAY_LOCAL > PAY_DATE                                                    THEN 'OVERDUE'
        WHEN TODAY_LOCAL >= REMIND_FROM                                                THEN 'REMIND'
        ELSE 'NONE'
    END AS ACTION
FROM state;
