-- ============================================================================
-- SERVER-SIDE ENFORCEMENT: block the "Approved Closed / Closed without approval"
-- bypass on ctpa_state — the GC USER permission lockdown (OBS-1191), database tier.
-- ============================================================================
-- WHY THIS EXISTS
--   The app has no server of its own: the SPA talks straight to PostgREST with the
--   anon key, and RLS on ctpa_state is fully permissive. The database therefore
--   cannot see the app-level role of the caller (every request is the anon role).
--   What it CAN enforce is a role-INDEPENDENT workflow INVARIANT that holds no
--   matter who calls (frontend, REST, RPC, psql):
--
--     An observation may not TRANSITION into Closed / Approved Closed unless it
--     carries BOTH a real GC Manager sign-off (clientApprovedRole + clientApprovedBy)
--     AND a real PMC Manager sign-off (lpApprovedRole + lpApprovedBy).
--
--   That is exactly "Approved Closed only after BOTH GC and PMC approvals", and it
--   rejects any direct API / RPC / DB write that flips an open observation to
--   Closed/Approved-Closed while skipping the two-manager workflow.
--
-- TRANSITION-BASED — WHY IT DOES NOT TOUCH EXISTING DATA
--   ctpa_state stores ALL observations as one JSONB array in a single row (id
--   'bkk22'); every save rewrites the whole array. A naive "reject any closed row
--   without both sign-offs" would reject virtually every save, because 1,130+ of the
--   ~1,186 currently-closed records are legacy closes with no role sign-offs.
--   So the guard fires ONLY on a *state transition*: it rejects an element that is
--   closed-ish in NEW, lacks both sign-offs, and whose SAME-ID element in OLD was
--   NOT closed-ish. Consequences:
--     * Every already-closed record (the ~1,130 legacy + the fully-approved ones)
--       is grandfathered — it was closed-ish in OLD, so it is never re-validated.
--       No existing observation, photo, history, audit row, or record is modified.
--     * Brand-new ids (not present in OLD) are allowed — this preserves the Excel
--       import of historical already-closed rows.
--     * The real workflow is unaffected: GC-approve leaves the row PENDING (not
--       closed-ish); PMC-approve writes BOTH sign-off roles before Closed, so it
--       passes. delete-last-After-photo reset and rejection both move the row OUT
--       of closed-ish (to IN_PROGRESS / OPEN), which is always allowed.
--     * Only a NEW, unauthorised close of a previously-open observation is rejected.
--
-- NULL-SAFETY (validated the hard way): brand-new OPEN records may omit the
--   approvalStatus key entirely. Comparing a missing key with = yields SQL NULL, and
--   `IF NOT (… OR NULL)` falls through instead of skipping — which would wrongly
--   reject open records. Every status/approvalStatus test below is therefore wrapped
--   in coalesce(…, '') so a missing key reads as "not closed-ish".
--
-- SCOPE / SAFETY
--   * NO ALTER TABLE, NO column added/removed/changed, NO schema change to any table.
--   * NO read/write/update/delete/move of any existing row, element, or photo.
--   * A BEFORE UPDATE trigger only — it validates the candidate NEW value and either
--     allows the write unchanged or raises. It never rewrites data.
--   * Scoped to array payloads; a non-array data value passes through untouched.
--
-- BLAST RADIUS — READ BEFORE APPLYING LIVE
--   Because every app save updates this one row, this trigger sits in the path of
--   100% of production writes. It has been validated against a session-local clone
--   of the live blob (temp table, ON COMMIT DROP — production never written) proving:
--     no-op re-save = allowed (all legacy closes grandfathered),
--     unauthorised open->Approved-Closed = REJECTED,
--     real GC+PMC close = allowed, Excel-import new closed row = allowed,
--     edit of an open record = allowed.
--   Apply during low traffic, keep the DROP statement ready, and re-run the
--   validation harness first. See the ROLLBACK section at the bottom.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Guard function
-- ---------------------------------------------------------------------------
create or replace function public.ctpa_state_close_guard()
returns trigger
language plpgsql
as $function$
declare
  old_ids    jsonb;   -- set of ids present in OLD
  old_closed jsonb;   -- set of ids that were ALREADY closed-ish in OLD (grandfathered)
  e          jsonb;
begin
  -- Only guard the observation-list payload (a JSONB array). Anything else passes.
  if NEW.data is null or jsonb_typeof(NEW.data) <> 'array' then
    return NEW;
  end if;

  select coalesce(jsonb_object_agg(o->>'id', true), '{}'::jsonb)
    into old_ids
  from jsonb_array_elements(coalesce(OLD.data, '[]'::jsonb)) o
  where o->>'id' is not null;

  select coalesce(jsonb_object_agg(o->>'id', true), '{}'::jsonb)
    into old_closed
  from jsonb_array_elements(coalesce(OLD.data, '[]'::jsonb)) o
  where o->>'id' is not null
    and ( coalesce(o->>'status','')          = 'CLOSED'
       or coalesce(o->>'approvalStatus','')  = 'APPROVED CLOSED' );

  for e in select value from jsonb_array_elements(NEW.data) t(value)
  loop
    if e->>'id' is null then
      continue;
    end if;

    -- Not closed-ish in NEW → nothing to enforce (NULL-safe).
    if not ( coalesce(e->>'status','')         = 'CLOSED'
          or coalesce(e->>'approvalStatus','') = 'APPROVED CLOSED' ) then
      continue;
    end if;

    -- Carries BOTH real sign-offs → this is a legitimate approved close. Allowed.
    if ( nullif(e->>'clientApprovedRole','') is not null
         and nullif(e->>'clientApprovedBy','') is not null
         and nullif(e->>'lpApprovedRole','')  is not null
         and nullif(e->>'lpApprovedBy','')    is not null ) then
      continue;
    end if;

    -- Was ALREADY closed-ish in OLD → grandfathered (legacy / historical). Allowed,
    -- and existing data is never touched.
    if old_closed ? (e->>'id') then
      continue;
    end if;

    -- Brand-new id (absent from OLD) → allow (e.g. Excel import of a historical
    -- already-closed observation). The realistic bypass is a transition on an
    -- EXISTING open observation, handled by the raise below.
    if not (old_ids ? (e->>'id')) then
      continue;
    end if;

    -- Reaching here: NEW element is closed-ish, lacks both sign-offs, and its OLD
    -- counterpart existed and was NOT closed-ish → an unauthorised close/approval
    -- that skips the GC + PMC workflow. Reject the entire write.
    raise exception
      'CTPA workflow guard: observation % cannot transition to Closed / Approved Closed without GC Manager and PMC Manager approval sign-offs. The two-stage approval workflow cannot be bypassed.',
      e->>'id'
      using errcode = 'check_violation';
  end loop;

  return NEW;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Trigger — BEFORE UPDATE on the single observation-blob table
-- ---------------------------------------------------------------------------
drop trigger if exists ctpa_state_close_guard_trg on public.ctpa_state;
create trigger ctpa_state_close_guard_trg
  before update on public.ctpa_state
  for each row
  execute function public.ctpa_state_close_guard();

-- ============================================================================
-- ROLLBACK (instant, non-destructive — removes the guard, touches no data):
--   drop trigger if exists ctpa_state_close_guard_trg on public.ctpa_state;
--   drop function if exists public.ctpa_state_close_guard();
-- ============================================================================
