-- depends_on: T_D_APP_USER
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_D_APP_USER - Users of the payroll app with their one role
   =====================================================================================

   HISTORY
   -------
   2026-10-05  Initial version: V_D_PERIOD, V_F_SCENARIO_PERIOD, V_F_PAYROLL_INPUT,
               V_F_ALLOCATION, V_D_SCENARIO_EMPLOYEE, V_F_PAYROLL_LINE, V_D_LOOKUP,
               V_P_APPROVAL_STEP, V_D_APP_USER.
   2026-10-19  Own file for DLSync (was in R__views_rpt_app.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.

   NOTES
   -----
   * No view here contains bank details or signature images: every app user reads through
     the same Snowflake connection, so anything in a view is visible to all of them.
   * Column comments: views inherit the meaning of the APP columns they show; only new or
     calculated columns are described.
   ===================================================================================== */
/* -------------------------------------------------------------------------------------
   App users and their role (no signature image): Settings, showing names
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW {{ schema_rpt }}.V_D_APP_USER (
    USER_EMAIL, DISPLAY_NAME, ROLE_CODE, IS_ACTIVE,
    HAS_SIGNATURE COMMENT 'TRUE when an e-signature image is stored for the user'
)
COPY GRANTS
COMMENT = 'Users of the payroll app with their one role. The signature image itself is not shown.'
AS
SELECT USER_EMAIL, DISPLAY_NAME, ROLE_CODE, IS_ACTIVE, SIGNATURE_IMAGE IS NOT NULL
FROM {{ schema_app }}.T_D_APP_USER;
