-- ============================================================================
-- HARDENING: upsert_observation() — GC/PMC approval must be EXPLICIT
-- ============================================================================
-- STATUS: REVIEW-ONLY. This file is NOT auto-applied by the workflow fix.
--         Apply it manually (Supabase SQL editor / CLI) only AFTER review,
--         and only if/when the app migrates from ctpa_state to the
--         `observations` table.
--
-- Why this is safe to apply:
--   * The `observations` table is currently UNUSED (0 rows). The ~1,147
--     historical observations live in `ctpa_state` (a JSON blob) and are NOT
--     referenced, touched, migrated, backfilled, or modified here.
--   * The two ALTER TABLE statements only ADD nullable columns to that empty
--     table, so no existing row can be affected.
--
-- What it fixes (root cause of "auto Approved by GC"):
--   The previous RPC derived approval from the mere PRESENCE of an approver
--   NAME:
--       gc_manager_approved =
--         COALESCE((payload->>'clientApprovedBy') IS NOT NULL
--                  AND (payload->>'clientApprovedBy') != '', FALSE)
--   A backfilled/legacy closer name therefore flipped gc_manager_approved to
--   TRUE. This version NEVER derives approval from a name. Approval is TRUE
--   only when the manual approval action's full fingerprint is present:
--     - an explicit approval flag (gcApproved/pmcApproved = true) OR the
--       approval ROLE that only the Approve button sets, AND
--     - approver name, AND approver user id, AND approval timestamp.
-- ============================================================================

-- Record the approver's USER ID (additive, nullable; empty table → no row touched)
alter table public.observations add column if not exists gc_manager_approved_by_id  text;
alter table public.observations add column if not exists pmc_manager_approved_by_id text;

create or replace function public.upsert_observation(payload jsonb)
returns observations
language plpgsql
security definer
as $function$
declare
  result observations;
  -- The approval ACTION's fingerprint: an explicit approval value set true by
  -- the action (gcApproved), or the approval ROLE that only the Approve button
  -- writes. A name alone provides neither, so it can never approve.
  v_gc_explicit  boolean := coalesce((payload->>'gcApproved')::boolean, false)
                            or nullif(payload->>'clientApprovedRole','') is not null;
  v_pmc_explicit boolean := coalesce((payload->>'pmcApproved')::boolean, false)
                            or nullif(payload->>'lpApprovedRole','') is not null;
  -- Approval is recorded ONLY when the explicit action + user id + name +
  -- timestamp are all present.
  v_gc  boolean := v_gc_explicit
                   and nullif(payload->>'clientApprovedBy','')   is not null
                   and nullif(payload->>'clientApprovedById','') is not null
                   and nullif(payload->>'clientApprovedDate','') is not null;
  v_pmc boolean := v_pmc_explicit
                   and nullif(payload->>'lpApprovedBy','')   is not null
                   and nullif(payload->>'lpApprovedById','') is not null
                   and nullif(payload->>'lpApprovedDate','') is not null;
begin
  insert into observations (
    id, obs_date, week, obs_type,
    zone, floor, area,
    responsible_company, category, finding_category, risk_level,
    status, due_date, raised_by,
    hazard_description, corrective_action,
    before_photos, after_photos,
    closed_date, closed_by,
    gc_manager_approved,  gc_manager_approved_by,  gc_manager_approved_by_id,  gc_manager_approved_date,
    pmc_manager_approved, pmc_manager_approved_by, pmc_manager_approved_by_id, pmc_manager_approved_date,
    approval_status, approved_by, approved_date, approval_comment,
    rejected_by, rejected_date,
    submitted_for_closure_by, submitted_for_closure_date,
    created_by
  ) values (
    payload->>'id',
    (payload->>'date')::date,
    payload->>'week',
    coalesce((payload->>'obsType')::obs_type, 'UNSAFE_ACT'),
    payload->>'zone',
    payload->>'floor',
    payload->>'area',
    payload->>'company',
    payload->>'cat',
    payload->>'fc',
    coalesce((payload->>'risk')::obs_risk_level, 'MINOR'),
    coalesce((payload->>'status')::obs_status, 'OPEN'),
    nullif(payload->>'due','')::date,
    payload->>'by',
    payload->>'desc',
    payload->>'rect',
    coalesce(payload->'pb', '[]'::jsonb),
    coalesce(payload->'pa', '[]'::jsonb),
    nullif(payload->>'closed','')::date,
    payload->>'closedBy',
    -- GC approval — EXPLICIT ONLY. Approver name/id/date recorded only if approved.
    coalesce(v_gc, false),
    case when v_gc then payload->>'clientApprovedBy'   else null end,
    case when v_gc then payload->>'clientApprovedById' else null end,
    case when v_gc then nullif(payload->>'clientApprovedDate','')::timestamptz else null end,
    -- PMC approval — EXPLICIT ONLY.
    coalesce(v_pmc, false),
    case when v_pmc then payload->>'lpApprovedBy'   else null end,
    case when v_pmc then payload->>'lpApprovedById' else null end,
    case when v_pmc then nullif(payload->>'lpApprovedDate','')::timestamptz else null end,
    coalesce((payload->>'approvalStatus')::obs_approval_status, 'NONE'),
    payload->>'approvedBy',
    nullif(payload->>'approvedDate','')::timestamptz,
    payload->>'approvalComment',
    payload->>'rejectedBy',
    nullif(payload->>'rejectedDate','')::timestamptz,
    payload->>'submittedForClosureBy',
    nullif(payload->>'submittedForClosureDate','')::timestamptz,
    payload->>'by'
  )
  on conflict (id) do update set
    obs_date=excluded.obs_date, week=excluded.week, obs_type=excluded.obs_type,
    zone=excluded.zone, floor=excluded.floor, area=excluded.area,
    responsible_company=excluded.responsible_company, category=excluded.category,
    finding_category=excluded.finding_category, risk_level=excluded.risk_level,
    status=excluded.status, due_date=excluded.due_date, raised_by=excluded.raised_by,
    hazard_description=excluded.hazard_description, corrective_action=excluded.corrective_action,
    before_photos=excluded.before_photos, after_photos=excluded.after_photos,
    closed_date=excluded.closed_date, closed_by=excluded.closed_by,
    gc_manager_approved=excluded.gc_manager_approved,
    gc_manager_approved_by=excluded.gc_manager_approved_by,
    gc_manager_approved_by_id=excluded.gc_manager_approved_by_id,
    gc_manager_approved_date=excluded.gc_manager_approved_date,
    pmc_manager_approved=excluded.pmc_manager_approved,
    pmc_manager_approved_by=excluded.pmc_manager_approved_by,
    pmc_manager_approved_by_id=excluded.pmc_manager_approved_by_id,
    pmc_manager_approved_date=excluded.pmc_manager_approved_date,
    approval_status=excluded.approval_status, approved_by=excluded.approved_by,
    approved_date=excluded.approved_date, approval_comment=excluded.approval_comment,
    rejected_by=excluded.rejected_by, rejected_date=excluded.rejected_date,
    submitted_for_closure_by=excluded.submitted_for_closure_by,
    submitted_for_closure_date=excluded.submitted_for_closure_date
  returning * into result;
  return result;
end;
$function$;
