-- ============================================================
-- EHS Observation Tracker — Minimal Supabase Setup
-- Project : CTPA BKK22 Chonburi Tech Park
--
-- Run this in: Supabase Dashboard → SQL Editor → New query
-- This creates the 2 tables the app needs to sync across devices.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- TABLE 1: ctpa_state  (observations blob — one row per site)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ctpa_state (
  id          TEXT PRIMARY KEY,
  data        JSONB NOT NULL DEFAULT '[]'::jsonb,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.ctpa_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "state_select" ON public.ctpa_state;
DROP POLICY IF EXISTS "state_insert" ON public.ctpa_state;
DROP POLICY IF EXISTS "state_update" ON public.ctpa_state;

CREATE POLICY "state_select" ON public.ctpa_state FOR SELECT USING (true);
CREATE POLICY "state_insert" ON public.ctpa_state FOR INSERT WITH CHECK (true);
CREATE POLICY "state_update" ON public.ctpa_state FOR UPDATE USING (true);

-- Seed the bkk22 row so cloudSave can upsert correctly
INSERT INTO public.ctpa_state (id, data)
VALUES ('bkk22', '[]'::jsonb)
ON CONFLICT (id) DO NOTHING;

-- ────────────────────────────────────────────────────────────
-- TABLE 2: ctpa_log  (activity log — one row per event)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ctpa_log (
  id         BIGSERIAL PRIMARY KEY,
  site       TEXT NOT NULL DEFAULT 'bkk22',
  who        TEXT,
  action     TEXT,
  obs_id     TEXT,
  detail     TEXT,
  device     TEXT,
  at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.ctpa_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "log_select" ON public.ctpa_log;
DROP POLICY IF EXISTS "log_insert" ON public.ctpa_log;

CREATE POLICY "log_select" ON public.ctpa_log FOR SELECT USING (true);
CREATE POLICY "log_insert" ON public.ctpa_log FOR INSERT WITH CHECK (true);

-- Index for fast lookup by site + time
CREATE INDEX IF NOT EXISTS ctpa_log_site_at ON public.ctpa_log (site, at DESC);

-- ────────────────────────────────────────────────────────────
-- VERIFY (run after the above)
-- ────────────────────────────────────────────────────────────
-- SELECT * FROM public.ctpa_state;
-- SELECT * FROM public.ctpa_log ORDER BY at DESC LIMIT 10;
