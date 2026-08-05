-- ============================================================================
-- SERVER-SIDE APPROVAL AUTHORIZATION (Issue 4) — role-verified sign-offs on
-- ctpa_state. Supersedes 2026-08-04_ctpa_state_close_guard.sql by REPLACING the
-- guard function body (same name/trigger), so it now enforces BOTH:
--
--   (A) CLOSE INVARIANT (unchanged): an observation may not TRANSITION into
--       Closed / Approved Closed without BOTH a GC and a PMC sign-off role.
--       Transition-based → every existing closed record is grandfathered; Excel
--       import of new closed rows is allowed; only a NEW unauthorised close is
--       rejected. No existing data is read-modified.
--
--   (B) ROLE AUTHORIZATION (new): when a write ADDS or CHANGES an approval sign-off
--       ROLE on an observation, the CALLER's real authenticated role is verified:
--         * a GC Manager sign-off (clientApprovedRole) requires the caller to be a
--           GC Manager (lm_gc / ritta_gc) or Admin (dayone_admin);
--         * a PMC Manager sign-off (lpApprovedRole) requires the caller to be the
--           PMC Manager (pmc_manager) or Admin.
--       The caller is identified from the request JWT (auth.uid()) and looked up in
--       ctpa_user_profiles — so the check uses the caller's ACTUAL role, NOT the role
--       string in the JSON payload. A GC USER (lm_user / ritta_user) — or any manual
--       API / RPC / psql caller who is not a manager/admin — is therefore REJECTED
--       (errcode insufficient_privilege → PostgREST returns an error, i.e. 403-like)
--       even if they craft a payload that fills in "clientApprovedRole":"GC Manager".
--
-- WHY ROLE-CHANGE-SCOPED (not "any row with a role"): the SPA rewrites the whole
--   observation array on every save. A sign-off already present in OLD is unchanged
--   in NEW → NOT re-checked, so a GC USER creating an observation (or any no-op
--   re-save) writes a blob full of OTHER people's existing sign-offs and passes.
--   Only a sign-off role that is newly added / changed vs the same-id OLD element is
--   authorized. Client-side load transforms (ctpaMigrate / stripPhotos) never write
--   the ROLE fields, so ordinary saves never trip (B).
--
-- SECURITY DEFINER: the function reads ctpa_user_profiles to resolve the caller's
--   role, which is RLS-protected; running as owner lets the lookup succeed while the
--   fixed search_path prevents search-path hijacking. It only READS that table.
--
-- SCOPE / SAFETY: BEFORE UPDATE trigger only; NO schema change; NO read-modify of any
--   existing observation, photo, history, audit row, or record. Role-level check
--   (contractor-scoping of GC approval remains a frontend rule). Validated against a
--   session-local clone of live data with simulated callers for every role
--   (GC USER add-GC = blocked, GC Mgr add-GC = allowed, PMC add-PMC = allowed,
--   GC Mgr add-PMC = blocked, GC USER create-open = allowed, admin full-close =
--   allowed, forge-close = blocked, no-op = allowed) — production never written.
--
-- ROLLBACK (non-destructive): restore the close-only guard by re-running
--   2026-08-04_ctpa_state_close_guard.sql, or drop entirely:
--     drop trigger if exists ctpa_state_close_guard_trg on public.ctpa_state;
--     drop function if exists public.ctpa_state_close_guard();
-- ============================================================================

create or replace function public.ctpa_state_close_guard()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  old_ids     jsonb;   -- ids present in OLD
  old_closed  jsonb;   -- ids already closed-ish in OLD (grandfathered)
  old_gcrole  jsonb;   -- id -> OLD clientApprovedRole (where non-empty)
  old_pmcrole jsonb;   -- id -> OLD lpApprovedRole (where non-empty)
  e           jsonb;
  eid         text;
  caller_uid  text;
  caller_role text;
begin
  if NEW.data is null or jsonb_typeof(NEW.data) <> 'array' then
    return NEW;
  end if;

  select coalesce(jsonb_object_agg(o->>'id', true), '{}'::jsonb) into old_ids
    from jsonb_array_elements(coalesce(OLD.data, '[]'::jsonb)) o where o->>'id' is not null;
  select coalesce(jsonb_object_agg(o->>'id', true), '{}'::jsonb) into old_closed
    from jsonb_array_elements(coalesce(OLD.data, '[]'::jsonb)) o
    where o->>'id' is not null
      and (coalesce(o->>'status','')='CLOSED' or coalesce(o->>'approvalStatus','')='APPROVED CLOSED');
  select coalesce(jsonb_object_agg(o->>'id', o->>'clientApprovedRole'), '{}'::jsonb) into old_gcrole
    from jsonb_array_elements(coalesce(OLD.data, '[]'::jsonb)) o
    where o->>'id' is not null and coalesce(o->>'clientApprovedRole','') <> '';
  select coalesce(jsonb_object_agg(o->>'id', o->>'lpApprovedRole'), '{}'::jsonb) into old_pmcrole
    from jsonb_array_elements(coalesce(OLD.data, '[]'::jsonb)) o
    where o->>'id' is not null and coalesce(o->>'lpApprovedRole','') <> '';

  -- Caller identity from the request JWT (null for a service-role / no-session write).
  begin
    caller_uid := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub';
  exception when others then
    caller_uid := null;
  end;
  if caller_uid is not null then
    select role into caller_role from public.ctpa_user_profiles where id::text = caller_uid;
  end if;

  for e in select value from jsonb_array_elements(NEW.data) t(value)
  loop
    eid := e->>'id';
    if eid is null then continue; end if;

    -- (B) ROLE AUTHORIZATION on a newly added / changed sign-off role.
    if coalesce(e->>'clientApprovedRole','') <> ''
       and coalesce(e->>'clientApprovedRole','') is distinct from coalesce(old_gcrole->>eid,'') then
      if coalesce(caller_role,'') not in ('dayone_admin','lm_gc','ritta_gc') then
        raise exception
          'CTPA authorization: GC Manager approval on % requires a GC Manager or Admin account (caller role: %). Unauthorized approval rejected.',
          eid, coalesce(caller_role,'unknown') using errcode = 'insufficient_privilege';
      end if;
    end if;
    if coalesce(e->>'lpApprovedRole','') <> ''
       and coalesce(e->>'lpApprovedRole','') is distinct from coalesce(old_pmcrole->>eid,'') then
      if coalesce(caller_role,'') not in ('dayone_admin','pmc_manager') then
        raise exception
          'CTPA authorization: PMC Manager approval on % requires a PMC Manager or Admin account (caller role: %). Unauthorized approval rejected.',
          eid, coalesce(caller_role,'unknown') using errcode = 'insufficient_privilege';
      end if;
    end if;

    -- (A) CLOSE INVARIANT — no NEW close/approved-closed without BOTH sign-off roles.
    if not (coalesce(e->>'status','')='CLOSED' or coalesce(e->>'approvalStatus','')='APPROVED CLOSED') then
      continue;
    end if;
    if (nullif(e->>'clientApprovedRole','') is not null and nullif(e->>'clientApprovedBy','') is not null
        and nullif(e->>'lpApprovedRole','') is not null and nullif(e->>'lpApprovedBy','') is not null) then
      continue;
    end if;
    if old_closed ? eid then continue; end if;
    if not (old_ids ? eid) then continue; end if;
    raise exception
      'CTPA workflow guard: observation % cannot transition to Closed / Approved Closed without GC Manager and PMC Manager approval sign-offs. The two-stage approval workflow cannot be bypassed.',
      eid using errcode = 'check_violation';
  end loop;

  return NEW;
end;
$function$;

drop trigger if exists ctpa_state_close_guard_trg on public.ctpa_state;
create trigger ctpa_state_close_guard_trg
  before update on public.ctpa_state
  for each row
  execute function public.ctpa_state_close_guard();
