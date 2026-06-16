-- ============================================================
-- EHS Observation Tracker — Supabase Setup
-- Project : CTPA BKK22 Chonburi Tech Park
--
-- Run this in: Supabase Dashboard → SQL Editor → New query
-- Safe to run multiple times (all statements are idempotent).
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- TABLE 1: ctpa_state  (observations blob — one row per site)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ctpa_state (
  id          TEXT PRIMARY KEY,
  data        JSONB NOT NULL DEFAULT '[]'::jsonb,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Enable RLS (required for anon key access via PostgREST)
ALTER TABLE public.ctpa_state ENABLE ROW LEVEL SECURITY;

-- Drop ALL existing policies on ctpa_state (idempotent reset)
DROP POLICY IF EXISTS "state_select"                   ON public.ctpa_state;
DROP POLICY IF EXISTS "state_insert"                   ON public.ctpa_state;
DROP POLICY IF EXISTS "state_update"                   ON public.ctpa_state;
DROP POLICY IF EXISTS "state_delete"                   ON public.ctpa_state;
DROP POLICY IF EXISTS "allow_select"                   ON public.ctpa_state;
DROP POLICY IF EXISTS "allow_insert"                   ON public.ctpa_state;
DROP POLICY IF EXISTS "allow_update"                   ON public.ctpa_state;
DROP POLICY IF EXISTS "allow_delete"                   ON public.ctpa_state;
DROP POLICY IF EXISTS "Enable read access for all users" ON public.ctpa_state;
DROP POLICY IF EXISTS "Enable insert for all users"    ON public.ctpa_state;
DROP POLICY IF EXISTS "Enable update for all users"    ON public.ctpa_state;

-- SELECT — anon can read all rows (app reads the bkk22 row)
CREATE POLICY "state_select"
  ON public.ctpa_state
  FOR SELECT
  USING (true);

-- INSERT — anon can insert new site rows (POST upsert fallback)
CREATE POLICY "state_insert"
  ON public.ctpa_state
  FOR INSERT
  WITH CHECK (true);

-- UPDATE — anon can PATCH existing rows
-- CRITICAL: Both USING and WITH CHECK are required.
-- WITHOUT CHECK (true) → PATCH returns HTTP 403 even when USING passes.
CREATE POLICY "state_update"
  ON public.ctpa_state
  FOR UPDATE
  USING (true)
  WITH CHECK (true);

-- DELETE — anon can delete rows
CREATE POLICY "state_delete"
  ON public.ctpa_state
  FOR DELETE
  USING (true);

-- Seed the bkk22 row — app sends PATCH which requires this row to exist.
-- If the row is missing, PATCH silently affects 0 rows and data is lost.
INSERT INTO public.ctpa_state (id, data, updated_at)
VALUES ('bkk22', '[]'::jsonb, now())
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

DROP POLICY IF EXISTS "log_select"                     ON public.ctpa_log;
DROP POLICY IF EXISTS "log_insert"                     ON public.ctpa_log;
DROP POLICY IF EXISTS "log_update"                     ON public.ctpa_log;
DROP POLICY IF EXISTS "log_delete"                     ON public.ctpa_log;
DROP POLICY IF EXISTS "allow_select"                   ON public.ctpa_log;
DROP POLICY IF EXISTS "allow_insert"                   ON public.ctpa_log;
DROP POLICY IF EXISTS "Enable read access for all users" ON public.ctpa_log;
DROP POLICY IF EXISTS "Enable insert for all users"    ON public.ctpa_log;

CREATE POLICY "log_select"
  ON public.ctpa_log
  FOR SELECT
  USING (true);

CREATE POLICY "log_insert"
  ON public.ctpa_log
  FOR INSERT
  WITH CHECK (true);

-- Performance index
CREATE INDEX IF NOT EXISTS ctpa_log_site_at ON public.ctpa_log (site, at DESC);

-- ────────────────────────────────────────────────────────────
-- VERIFY — run after the above to confirm everything is correct
-- ────────────────────────────────────────────────────────────

-- 1. Confirm bkk22 row exists
SELECT id, updated_at, jsonb_array_length(data) AS obs_count
FROM public.ctpa_state
WHERE id = 'bkk22';

-- 2. List all RLS policies on ctpa_state (should show 4 rows: SELECT, INSERT, UPDATE, DELETE)
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'ctpa_state'
ORDER BY cmd;

-- 3. List all RLS policies on ctpa_log (should show 2 rows: SELECT, INSERT)
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'ctpa_log'
ORDER BY cmd;

-- 4. Simulate the exact PATCH the app sends — must return 1 row
UPDATE public.ctpa_state
SET updated_at = now()
WHERE id = 'bkk22'
RETURNING id, updated_at;
