/* =====================================================================================
   OPTIONAL - MASK BANK DETAILS
   Requires Snowflake Enterprise Edition or higher. Uncomment and run manually.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   ===================================================================================== */

/* =====================================================================================
   7. OPTIONAL - MASK BANK DETAILS (requires Snowflake Enterprise Edition or higher)
   ===================================================================================== */

-- CREATE OR REPLACE MASKING POLICY APP.MP_BANK_ACCOUNT AS (VAL TEXT) RETURNS TEXT ->
--     CASE WHEN IS_ROLE_IN_SESSION('PAYROLL_ADMIN') THEN VAL
--          ELSE '****' || RIGHT(VAL, 4) END;
-- ALTER TABLE APP.T_D_EMPLOYEE MODIFY COLUMN BANK_ACCOUNT_NUMBER SET MASKING POLICY APP.MP_BANK_ACCOUNT;
