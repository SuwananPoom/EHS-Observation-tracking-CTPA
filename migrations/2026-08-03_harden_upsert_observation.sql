-- ============================================================================
-- HARDENING: upsert_observation() — GC/PMC approval must be EXPLICIT
-- ============================================================================
-- APPLIED as a FUNCTION-BODY REDEFINITION ONLY (CREATE OR REPLACE FUNCTION),
-- executed as raw SQL — NOT through the migration system, so NO migration is
-- recorded. It performs:
--   * NO ALTER TABLE / NO column added, removed, or changed
--   * NO schema change to any table
--   * NO read, write, update, delete, or move of any row / photo / id
-- The `observations` table is empty (0 rows) AND is NOT used by the running
-- app (the app persists to `ctpa_state`; it never calls upsert_observation),
-- so this change has zero effect on production data or behaviour. It only
-- makes the latent RPC safe for the day the app migrates to this table.
--
-- Root cause fixed: the previous body derived approval from the mere PRESENCE
-- of an approver NAME:
--     gc_manager_approved =
--       COALESCE((payload->>'clientApprovedBy') IS NOT NULL
--                AND (payload->>'clientApprovedBy') != '', FALSE)
-- so a backfilled/legacy closer name flipped gc_manager_approved to TRUE.
--
-- New logic == EXACTLY the current app workflow's "real approval" test:
--   a GC/PMC approval is recognised ONLY when the approval ROLE is present —
--   the role (clientApprovedRole / lpApprovedRole) is written ONLY by the
--   authorized GC/PMC "Approve" action, together with the approver name, user
--   id and timestamp. A NAME ALONE (no role) NEVER sets approval true.
--
-- NOTE ON USER ID: the approver's user id is part of the approval fingerprint
-- (clientApprovedById / lpApprovedById) and is retained in the app record. It
-- is intentionally NOT persisted to a new column here, to honour the
-- "no schema change" requirement. Existing columns only are written.
-- ============================================================================

create or replace function public.upsert_observation(payload jsonb)
returns observations
language plpgsql
security definer
as $function$
declare
  result observations;
  -- Same test the app uses for a real sign-off (see isUnapprovedClosed /
  -- effAp in index.html): the approval ROLE is present AND the approver name is
  -- present. The role is set only by the authorized Approve action.
  v_gc  boolean := nullif(payload->>'clientApprovedRole','') is not null
                   and nullif(payload->>'clientApprovedBy','') is not null;
  v_pmc boolean := nullif(payload->>'lpApprovedRole','') is not null
                   and nullif(payload->>'lpApprovedBy','') is not null;
begin
  -- EVIDENCE RULE (UAT OBS-1036): an observation can never be persisted as
  -- Closed / Approved Closed with zero After photos.
  if (coalesce(payload->>'status','') = 'CLOSED'
      or coalesce(payload->>'approvalStatus','') = 'APPROVED CLOSED')
     and jsonb_array_length(coalesce(payload->'pa','[]'::jsonb)) = 0 then
    raise exception 'CTPA validation: observation % cannot be saved as Closed/Approved Closed with zero After photos',
      coalesce(payload->>'id','(new)');
  end if;
  insert into observations (
    id, obs_date, week, obs_type,
    zone, floor, area,
    responsible_company, category, finding_category, risk_level,
    status, due_date, raised_by,
    hazard_description, corrective_action,
    before_photos, after_photos,
    closed_date, closed_by,
    gc_manager_approved,  gc_manager_approved_by,  gc_manager_approved_date,
    pmc_manager_approved, pmc_manager_approved_by, pmc_manager_approved_date,
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
    -- GC approval — role-gated. name/date recorded ONLY when actually approved.
    coalesce(v_gc, false),
    case when v_gc then payload->>'clientApprovedBy' else null end,
    case when v_gc then nullif(payload->>'clientApprovedDate','')::timestamptz else null end,
    -- PMC approval — role-gated.
    coalesce(v_pmc, false),
    case when v_pmc then payload->>'lpApprovedBy' else null end,
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
    gc_manager_approved_date=excluded.gc_manager_approved_date,
    pmc_manager_approved=excluded.pmc_manager_approved,
    pmc_manager_approved_by=excluded.pmc_manager_approved_by,
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
