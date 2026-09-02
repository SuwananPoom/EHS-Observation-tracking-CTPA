-- ═══════════════════════════════════════════════════════════════════════════
-- CTPA BKK22 — keep ctpa_state.updated_at in step with each write
-- SAFE / ADDITIVE (applied 2026-09-02): one trigger + function; changes no
-- data, only stamps updated_at = now() on every insert/update so the column
-- reflects the real last save time (useful for audit). Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.ctpa_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_ctpa_state_touch on public.ctpa_state;
create trigger trg_ctpa_state_touch
  before insert or update on public.ctpa_state
  for each row execute function public.ctpa_touch_updated_at();
