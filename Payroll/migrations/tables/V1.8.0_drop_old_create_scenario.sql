/* =====================================================================================
   V1.8.0 - DROP THE OLD 5-PARAMETER SP_CREATE_SCENARIO
   =====================================================================================

   HISTORY
   -------
   2026-10-06  Initial version. R__sp_create_scenario.sql gained a sixth, optional
               parameter (P_FX_RATE FLOAT DEFAULT NULL). CREATE OR REPLACE with a different
               parameter list creates a second procedure instead of replacing the first,
               and a 5-argument call would then be ambiguous. This drops the old version.
               Safe to run before or after the R file, and on a fresh database (IF EXISTS).
   Versioned file: never edit after deployment.
   ===================================================================================== */

DROP PROCEDURE IF EXISTS APP.SP_CREATE_SCENARIO(TEXT, TEXT, INT, INT, TEXT);