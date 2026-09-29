/* =====================================================================================
   V1.0.0 - CREATE SCHEMAS
   APP (operational), CORE (dimensional model), RPT (reporting views).
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   ===================================================================================== */

CREATE SCHEMA IF NOT EXISTS APP  COMMENT = 'Operational layer used by the Power Apps application';
CREATE SCHEMA IF NOT EXISTS CORE COMMENT = 'Dimensional model: dimensions, parameters and facts';
CREATE SCHEMA IF NOT EXISTS RPT  COMMENT = 'Reporting views for dashboards and analysis';
