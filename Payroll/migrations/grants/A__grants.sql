/* =====================================================================================
   A - GRANTS FOR THE POWER APPS FLOW
   Gives the app's role, "SF_APA_PAYROLL-ETL", exactly what the "Payroll - SQL" flow needs:
     * SELECT on the 21 RPT views the app reads
     * USAGE (permission to call) on the 24 public procedures
   The procedures run with their owner's rights (EXECUTE AS OWNER), so calling them is
   enough to save data, and only through their checks.
   =====================================================================================

   HISTORY
   -------
   2026-10-05  Initial version (two app roles).
   2026-10-05  No grant on the database itself (USAGE on PAYROLL_DB is managed by IT;
               this file only grants on the schemas and their objects).
   2026-10-05  V_F_DASHBOARD_MONTH added (21 views).
   2026-10-05  V_F_PAYROLL_MONTH added (20 views).
   2026-10-05  SP_GET_EMPLOYEE_BANK added (24 public procedures).
   2026-10-05  One role only: "SF_APA_PAYROLL-ETL". Optional section 4 removes its direct
               rights on the APP tables.
   2026-10-06  SP_CREATE_SCENARIO granted with its new signature (sixth, optional parameter
               P_FX_RATE FLOAT).

   WHEN IT RUNS
   ------------
   "A__" = an always script: schemachange runs it on every deployment, after the V and R
   files, because re-creating a view or procedure (CREATE OR REPLACE) removes its grants.
   Run it by hand after a rebuild or after re-running a view or procedure file.
   Re-running it is harmless. Run it as the owner of the views and procedures
   (SF_APA_PAYROLL-DBA).

   NOT GRANTED ON PURPOSE
   ----------------------
   * The Power BI views (V_*_PBI_*): Power BI signs in on its own; V_D_PBI_EMPLOYEE_DETAILS
     and V_D_PBI_SIGNATURE hold data the app must not read.
   * SP_CALC_PERIOD and SP_RESET_APPROVALS: internal, only called by other procedures.
   ===================================================================================== */

/* -------------------------------------------------------------------------------------
   1. Start clean on views and procedures (removes anything granted earlier on them)
   ------------------------------------------------------------------------------------- */
REVOKE ALL PRIVILEGES ON ALL VIEWS      IN SCHEMA PAYROLL_DB.RPT FROM ROLE "SF_APA_PAYROLL-ETL";
REVOKE ALL PRIVILEGES ON ALL PROCEDURES IN SCHEMA PAYROLL_DB.APP FROM ROLE "SF_APA_PAYROLL-ETL";

/* -------------------------------------------------------------------------------------
   2. The views the app reads
   ------------------------------------------------------------------------------------- */
GRANT USAGE ON SCHEMA PAYROLL_DB.RPT TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_D_EMPLOYEE             TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_D_SCENARIO             TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_PAYROLL_SUMMARY      TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_COST_ALLOCATION      TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_APPROVAL_EVENT       TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_DASHBOARD_KPI        TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_SCENARIO_SUMMARY     TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_BUDGET_VS_ACTUAL     TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_COST_CENTER_SUMMARY  TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_APPROVAL_PROGRESS    TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_D_PERIOD               TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_SCENARIO_PERIOD      TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_PAYROLL_INPUT        TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_ALLOCATION           TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_D_SCENARIO_EMPLOYEE    TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_PAYROLL_LINE         TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_D_LOOKUP               TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_P_APPROVAL_STEP        TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_D_APP_USER             TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_PAYROLL_MONTH        TO ROLE "SF_APA_PAYROLL-ETL";
GRANT SELECT ON VIEW PAYROLL_DB.RPT.V_F_DASHBOARD_MONTH      TO ROLE "SF_APA_PAYROLL-ETL";

/* -------------------------------------------------------------------------------------
   3. The public procedures (Snowflake identifies a procedure by its name and parameter
      types, so each line lists the exact types)
   ------------------------------------------------------------------------------------- */
GRANT USAGE ON SCHEMA PAYROLL_DB.APP TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_APPROVE_STEP(TEXT, INT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_CALCULATE_PAYROLL(TEXT, INT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_CREATE_FORECAST(TEXT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_CREATE_SCENARIO(TEXT, TEXT, INT, INT, TEXT, FLOAT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_DELETE_PLANNED_HIRE(TEXT, INT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_DELETE_SCENARIO(TEXT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_FINALIZE_PAYROLL(TEXT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_GET_EMPLOYEE_BANK(TEXT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_OPEN_PAYROLL_PERIOD(TEXT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_REJECT_STEP(TEXT, INT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SAVE_APPROVAL_STEPS(TEXT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SAVE_DEPARTMENT_ALLOCATION(TEXT, INT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SAVE_EMPLOYEE(TEXT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SAVE_EMPLOYEE_CONTRACT(TEXT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SAVE_EXCHANGE_RATE(TEXT, INT, FLOAT, FLOAT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SAVE_FUND_ALLOCATION(TEXT, INT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SAVE_MONTHLY_INPUT(TEXT, INT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SAVE_PLANNED_HIRE(TEXT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SAVE_SCENARIO_EMPLOYEE(TEXT, INT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SAVE_WORKING_DAYS(TEXT, TEXT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SET_EMPLOYEE_ACTIVE(TEXT, INT, BOOLEAN) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SET_EMPLOYEE_CHECK(TEXT, INT, INT, TEXT, TEXT, TEXT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_SUBMIT_SCENARIO(TEXT, INT) TO ROLE "SF_APA_PAYROLL-ETL";
GRANT USAGE ON PROCEDURE PAYROLL_DB.APP.SP_UNDO_APPROVAL(TEXT, INT, INT, INT) TO ROLE "SF_APA_PAYROLL-ETL";

/* -------------------------------------------------------------------------------------
   4. OPTIONAL - remove the role's direct rights on the APP tables
   Recommended: then the flow can only read the views above and change data only through
   the procedures (bank details and the tables themselves are out of reach).
   Before switching it on, check that nothing else uses "SF_APA_PAYROLL-ETL" to read or
   write the APP tables directly (a data load, another tool), or it will stop working.
   If IT granted those rights, IT may have to revoke them.
   To switch it on, remove the "--" in front of the line below.
   ------------------------------------------------------------------------------------- */
-- REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA PAYROLL_DB.APP FROM ROLE "SF_APA_PAYROLL-ETL";

/* -------------------------------------------------------------------------------------
   5. Check. Expected: USAGE on RPT and APP (plus the database, from IT); SELECT on 21 views;
      USAGE on 24 procedures (plus table rights while section 4 is off).
   ------------------------------------------------------------------------------------- */
SHOW GRANTS TO ROLE "SF_APA_PAYROLL-ETL";