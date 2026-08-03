-- ═══════════════════════════════════════════════════════════════════════════
-- CTPA BKK22 — Concurrent Device / Session Control migration
-- SAFE / ADDITIVE ONLY: creates one new table + functions. Does NOT touch
-- auth.users, ctpa_user_profiles, ctpa_state, ctpa_photos, storage, or any
-- existing data, roles, or policies. Re-runnable (IF NOT EXISTS / OR REPLACE).
-- Run in the Supabase SQL Editor.
-- ═══════════════════════════════════════════════════════════════════════════

-- 1 ▸ Session registry --------------------------------------------------------
create table if not exists public.ctpa_sessions (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  device_id      text not null,
  device_type    text not null check (device_type in ('DESKTOP','MOBILE')),
  browser        text not null default '',
  os             text not null default '',
  ip             text not null default '',
  status         text not null default 'ACTIVE'
                 check (status in ('ACTIVE','LOGGED_OUT','EXPIRED','REVOKED')),
  login_at       timestamptz not null default now(),
  last_active_at timestamptz not null default now(),
  ended_at       timestamptz
);
create index if not exists idx_ctpa_sessions_user_status
  on public.ctpa_sessions (user_id, status);

-- 2 ▸ RLS: read own sessions; admins read all; NO direct writes ---------------
--     (all writes go through the SECURITY DEFINER functions below, so the
--      device limit is enforced by the backend, not the browser)
alter table public.ctpa_sessions enable row level security;

drop policy if exists ctpa_sessions_select_own on public.ctpa_sessions;
create policy ctpa_sessions_select_own on public.ctpa_sessions
  for select using (auth.uid() = user_id);

drop policy if exists ctpa_sessions_select_admin on public.ctpa_sessions;
create policy ctpa_sessions_select_admin on public.ctpa_sessions
  for select using (exists (
    select 1 from public.ctpa_user_profiles p
    where p.id = auth.uid() and p.role = 'dayone_admin'));

-- 3 ▸ Atomic session claim (login / restore) ----------------------------------
--     Limits: max 1 DESKTOP + 1 MOBILE = 2 active devices per account.
--     Same device_id reconnecting reuses its session (refresh/reopen never
--     duplicates; an IP change on the same device is NOT a new device).
--     pg_advisory_xact_lock serializes concurrent logins per user (atomic).
--     Inactivity expiry: 12 hours (adjust the interval below to reconfigure).
create or replace function public.ctpa_claim_session(
  p_device_id text, p_device_type text, p_browser text default '', p_os text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_ip  text := '';
  v_row public.ctpa_sessions%rowtype;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'reason', 'NOT_AUTHENTICATED');
  end if;
  if p_device_type not in ('DESKTOP','MOBILE') or coalesce(p_device_id,'') = '' then
    return jsonb_build_object('ok', false, 'reason', 'BAD_REQUEST');
  end if;
  begin
    v_ip := split_part(coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', ''), ',', 1);
  exception when others then v_ip := ''; end;

  perform pg_advisory_xact_lock(hashtext('ctpa_sess_' || v_uid::text));

  update public.ctpa_sessions
     set status = 'EXPIRED', ended_at = now()
   where user_id = v_uid and status = 'ACTIVE'
     and last_active_at < now() - interval '12 hours';

  select * into v_row from public.ctpa_sessions
   where user_id = v_uid and device_id = p_device_id and status = 'ACTIVE'
   order by login_at desc limit 1;
  if found then
    update public.ctpa_sessions
       set last_active_at = now(), browser = coalesce(p_browser, browser),
           os = coalesce(p_os, os), ip = coalesce(nullif(v_ip,''), ip)
     where id = v_row.id;
    return jsonb_build_object('ok', true, 'session_id', v_row.id, 'reused', true);
  end if;

  if (select count(*) from public.ctpa_sessions
       where user_id = v_uid and status = 'ACTIVE') >= 2
     or exists (select 1 from public.ctpa_sessions
                 where user_id = v_uid and status = 'ACTIVE'
                   and device_type = p_device_type) then
    return jsonb_build_object('ok', false, 'reason', 'DEVICE_LIMIT');
  end if;

  insert into public.ctpa_sessions (user_id, device_id, device_type, browser, os, ip)
  values (v_uid, p_device_id, p_device_type, coalesce(p_browser,''), coalesce(p_os,''), v_ip)
  returning * into v_row;
  return jsonb_build_object('ok', true, 'session_id', v_row.id, 'reused', false);
end $$;

-- 4 ▸ Heartbeat: refresh last_active_at; report the session's real status ----
create or replace function public.ctpa_touch_session(p_session_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_row public.ctpa_sessions%rowtype;
begin
  if auth.uid() is null then return 'NOT_AUTHENTICATED'; end if;
  select * into v_row from public.ctpa_sessions
   where id = p_session_id and user_id = auth.uid();
  if not found then return 'MISSING'; end if;
  if v_row.status = 'ACTIVE' and v_row.last_active_at < now() - interval '12 hours' then
    update public.ctpa_sessions set status = 'EXPIRED', ended_at = now() where id = v_row.id;
    return 'EXPIRED';
  end if;
  if v_row.status = 'ACTIVE' then
    update public.ctpa_sessions set last_active_at = now() where id = v_row.id;
  end if;
  return v_row.status;
end $$;

-- 5 ▸ Logout (own session) ----------------------------------------------------
create or replace function public.ctpa_logout_session(p_session_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.ctpa_sessions
     set status = 'LOGGED_OUT', ended_at = now()
   where id = p_session_id and user_id = auth.uid() and status = 'ACTIVE';
$$;

-- 6 ▸ Admin revocation (dayone_admin only; never auto-terminates) -------------
create or replace function public.ctpa_admin_revoke_session(p_session_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.ctpa_user_profiles p
                  where p.id = auth.uid() and p.role = 'dayone_admin') then
    return false;
  end if;
  update public.ctpa_sessions set status = 'REVOKED', ended_at = now()
   where id = p_session_id and status = 'ACTIVE';
  return found;
end $$;

create or replace function public.ctpa_admin_revoke_user(p_user_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if not exists (select 1 from public.ctpa_user_profiles p
                  where p.id = auth.uid() and p.role = 'dayone_admin') then
    return 0;
  end if;
  update public.ctpa_sessions set status = 'REVOKED', ended_at = now()
   where user_id = p_user_id and status = 'ACTIVE';
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- 7 ▸ Permissions: authenticated users may call the functions -----------------
revoke all on function public.ctpa_claim_session(text,text,text,text) from public, anon;
revoke all on function public.ctpa_touch_session(uuid) from public, anon;
revoke all on function public.ctpa_logout_session(uuid) from public, anon;
revoke all on function public.ctpa_admin_revoke_session(uuid) from public, anon;
revoke all on function public.ctpa_admin_revoke_user(uuid) from public, anon;
grant execute on function public.ctpa_claim_session(text,text,text,text) to authenticated;
grant execute on function public.ctpa_touch_session(uuid) to authenticated;
grant execute on function public.ctpa_logout_session(uuid) to authenticated;
grant execute on function public.ctpa_admin_revoke_session(uuid) to authenticated;
grant execute on function public.ctpa_admin_revoke_user(uuid) to authenticated;

-- Verification (read-only):
--   select * from public.ctpa_sessions limit 5;
--   select proname from pg_proc where proname like 'ctpa_%session%' or proname like 'ctpa_admin_revoke%';
