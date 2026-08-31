-- ═══════════════════════════════════════════════════════════════════════════
-- CTPA BKK22 — Per-user device-limit overrides (applied 2026-08-31)
-- SAFE / ADDITIVE: adds one config table + replaces ctpa_claim_session so the
-- per-device-type limit is read from the table (default stays 1 DESKTOP +
-- 1 MOBILE for everyone). Does NOT touch observation data, photos, storage,
-- or existing sessions. Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.ctpa_device_limits (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  desktop_limit integer not null default 1 check (desktop_limit between 0 and 10),
  mobile_limit  integer not null default 1 check (mobile_limit between 0 and 10),
  note          text not null default '',
  updated_at    timestamptz not null default now()
);
alter table public.ctpa_device_limits enable row level security;
-- no policies: not readable/writable from clients; only SECURITY DEFINER
-- functions and admins via the SQL editor.

create or replace function public.ctpa_claim_session(
  p_device_id text, p_device_type text, p_browser text default '', p_os text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_ip  text := '';
  v_row public.ctpa_sessions%rowtype;
  v_limit integer := 1;
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

  -- per-user, per-device-type limit (default 1 each; overridable in ctpa_device_limits)
  select case when p_device_type = 'DESKTOP' then desktop_limit else mobile_limit end
    into v_limit from public.ctpa_device_limits where user_id = v_uid;
  if v_limit is null then v_limit := 1; end if;

  if (select count(*) from public.ctpa_sessions
       where user_id = v_uid and status = 'ACTIVE'
         and device_type = p_device_type) >= v_limit then
    return jsonb_build_object('ok', false, 'reason', 'DEVICE_LIMIT');
  end if;

  insert into public.ctpa_sessions (user_id, device_id, device_type, browser, os, ip)
  values (v_uid, p_device_id, p_device_type, coalesce(p_browser,''), coalesce(p_os,''), v_ip)
  returning * into v_row;
  return jsonb_build_object('ok', true, 'session_id', v_row.id, 'reused', false);
end $$;

-- Grant an override with e.g.:
--   insert into public.ctpa_device_limits (user_id, desktop_limit, mobile_limit, note)
--   values ('<auth.users id>', 2, 1, 'reason')
--   on conflict (user_id) do update set desktop_limit = 2, updated_at = now();
