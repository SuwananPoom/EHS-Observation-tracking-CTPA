-- ADDITIVE (applied 2026-11-21): composite index for incremental reads
-- (site = ? and updated_at > ?) used by the app's 60 s delta polling.
create index if not exists idx_ctpa_obs_site_updated on public.ctpa_observations (site, updated_at);
