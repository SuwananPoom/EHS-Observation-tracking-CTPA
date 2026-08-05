-- ============================================================================
-- REVERT the auth.uid()-based approval authorization on ctpa_state back to the
-- workflow close-guard INVARIANT only. Supersedes 2026-08-05_ctpa_state_approval_authz.sql.
--
-- WHY (root cause):
--   The app saves ctpa_state via a raw REST PATCH whose Authorization header is the
--   ANON key (see cloudHeaders() / cloudMergeSave() in index.html), NOT the signed-in
--   user's JWT. So every app write reaches Postgres as the `anon` role with
--   auth.uid() = NULL. The 2026-08-05 trigger tried to authorize approval sign-offs by
--   looking up the caller's role via auth.uid() -> ctpa_user_profiles; with auth.uid()
--   always null it saw "caller role: unknown" and REJECTED every write that added a
--   clientApprovedRole / lpApprovedRole — i.e. it silently blocked ALL real GC and PMC
--   Manager approvals (errcode 42501 / insufficient_privilege). Per-writer identity
--   simply cannot be enforced at the DB while the client writes with the anon key.
--
-- WHAT THIS DOES:
--   Restores the transition-based close-guard: an observation may not TRANSITION into
--   Closed / Approved Closed unless it carries BOTH a GC and a PMC sign-off (name+role),
--   or was already closed-ish (grandfathered), or is a brand-new id (Excel import). This
--   enforces the workflow bypass-protection purely from the DATA and reads NO auth and
--   NO other table, so it never blocks a legitimate approval. Role-level authorization of
--   WHO may approve remains enforced in the frontend (canApproveGC / canApprovePMC +
--   hidden approval controls).
--
-- SAFETY: BEFORE UPDATE trigger only; no schema change; no read-modify of any existing
--   observation, photo, history, or record. Applied live via an atomic transaction whose
--   in-txn self-tests (run as the anon role) proved: no-op re-save passes, a GC approval
--   passes, a full GC+PMC close passes, and an unauthorized no-sign-off close is blocked.
--
-- ROLLBACK: re-run 2026-08-05_ctpa_state_approval_authz.sql (not recommended — it blocks
--   approvals under the anon-key write model), or drop entirely:
--     drop trigger if exists ctpa_state_close_guard_trg on public.ctpa_state;
--     drop function if exists public.ctpa_state_close_guard();
-- ============================================================================

create or replace function public.ctpa_state_close_guard()
returns trigger
language plpgsql
as $function$
declare
  old_ids    jsonb;
  old_closed jsonb;
  e          jsonb;
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

  for e in select value from jsonb_array_elements(NEW.data) t(value)
  loop
    if e->>'id' is null then continue; end if;
    -- Not closed-ish in NEW → nothing to enforce (NULL-safe).
    if not (coalesce(e->>'status','')='CLOSED' or coalesce(e->>'approvalStatus','')='APPROVED CLOSED') then
      continue;
    end if;
    -- Carries BOTH real sign-offs (name + role) → a legitimate approved close. Allowed.
    if (nullif(e->>'clientApprovedRole','') is not null and nullif(e->>'clientApprovedBy','') is not null
        and nullif(e->>'lpApprovedRole','')  is not null and nullif(e->>'lpApprovedBy','')  is not null) then
      continue;
    end if;
    -- Already closed-ish in OLD → grandfathered (legacy / historical). Allowed, untouched.
    if old_closed ? (e->>'id') then continue; end if;
    -- Brand-new id (absent from OLD) → allow (e.g. Excel import of a historical closed row).
    if not (old_ids ? (e->>'id')) then continue; end if;
    -- Otherwise: a NEW unauthorised transition into Closed / Approved Closed. Reject.
    raise exception
      'CTPA workflow guard: observation % cannot transition to Closed / Approved Closed without GC Manager and PMC Manager approval sign-offs. The two-stage approval workflow cannot be bypassed.',
      e->>'id' using errcode = 'check_violation';
  end loop;

  return NEW;
end;
$function$;

drop trigger if exists ctpa_state_close_guard_trg on public.ctpa_state;
create trigger ctpa_state_close_guard_trg
  before update on public.ctpa_state
  for each row
  execute function public.ctpa_state_close_guard();
