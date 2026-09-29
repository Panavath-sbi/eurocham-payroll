/* =====================================================================================
   V1.2.0 - APPROVAL ACTION TYPE SEND_BACK
   Documents the new SEND_BACK action written by SP_REJECT_STEP.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version. Rejecting a step now sends the approval back one step
               instead of cancelling it; the previous step receives a SEND_BACK action.
   Versioned file: never edit after deployment.
   ===================================================================================== */

ALTER TABLE APP.T_F_APPROVAL_ACTION ALTER COLUMN ACTION_TYPE
    COMMENT 'APPROVE, REJECT (step sends the work back), SEND_BACK (previous step must re-check), UNDO, or RESET (written by the system when data changes)';

ALTER TABLE APP.T_F_APPROVAL_REQUEST ALTER COLUMN REQUEST_STATUS
    COMMENT 'IN_PROGRESS, APPROVED, REJECTED (budget sent back to the preparer), CANCELLED';
