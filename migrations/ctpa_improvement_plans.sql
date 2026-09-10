-- ═══════════════════════════════════════════════════════════════════════════
-- CTPA BKK22 — Recurring Issue Improvement Plans (applied 2026-09-10)
-- ADDITIVE ONLY: one new table storing an improvement plan per recurring
-- cluster (JSONB). Touches nothing existing — no observation data, photos,
-- storage, or other tables. Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.ctpa_improvement_plans (
  cluster_id text primary key,
  site       text not null default 'bkk22',
  plan       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.ctpa_improvement_plans enable row level security;
drop policy if exists imp_select on public.ctpa_improvement_plans;
create policy imp_select on public.ctpa_improvement_plans for select using (site = 'bkk22');
drop policy if exists imp_upsert on public.ctpa_improvement_plans;
create policy imp_upsert on public.ctpa_improvement_plans for insert with check (site = 'bkk22');
drop policy if exists imp_update on public.ctpa_improvement_plans;
create policy imp_update on public.ctpa_improvement_plans for update using (site = 'bkk22') with check (site = 'bkk22');
drop trigger if exists trg_ctpa_imp_touch on public.ctpa_improvement_plans;
create trigger trg_ctpa_imp_touch before insert or update on public.ctpa_improvement_plans
  for each row execute function public.ctpa_touch_updated_at();
-- plan JSONB shape (managed by the frontend):
-- { clusterId, label, hoc:[{level,decision,control,reason}x5], justification,
--   actions:[{level,role,action,company,team,owner,due,status,evidence,verification}],
--   monitorFrom, history:[{at,by,note}] }
