-- ============================================================
-- SCHEMA BACKUP — EHS Observation Tracker
-- Project  : CTPA BKK22 Chonburi Tech Park
-- Generated: 2026-06-16
-- Supabase : ocwdnvblpjfzkgzratqb.supabase.co
--
-- This file captures the exact live schema.
-- Run in: Supabase Dashboard → SQL Editor → New query
-- Safe to re-run (all statements are idempotent).
-- ============================================================


-- ════════════════════════════════════════════════════════════
-- TABLE 1: ctpa_state
-- Purpose : Single-row JSONB blob storing ALL observations.
--           One row per site (id = 'bkk22').
--           The entire obs array is read/written as one payload.
-- ════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.ctpa_state (
  id          TEXT        PRIMARY KEY,
  data        JSONB       NOT NULL DEFAULT '[]'::jsonb,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.ctpa_state             IS 'Single-row observation blob per site. id=bkk22 for CTPA BKK22.';
COMMENT ON COLUMN public.ctpa_state.id          IS 'Site identifier — always ''bkk22'' for this project.';
COMMENT ON COLUMN public.ctpa_state.data        IS 'Full observation array as JSONB. Each element is one EHS observation object.';
COMMENT ON COLUMN public.ctpa_state.updated_at  IS 'UTC timestamp of last write. Used by smart polling to detect changes without fetching full blob.';


-- ════════════════════════════════════════════════════════════
-- TABLE 2: ctpa_log
-- Purpose : Append-only activity log. One row per event.
--           Records: create, edit, delete, approve_closure,
--           reject_closure, submit_closure, visit, sync.
-- ════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.ctpa_log (
  id         BIGSERIAL    PRIMARY KEY,
  site       TEXT         NOT NULL DEFAULT 'bkk22',
  who        TEXT,
  action     TEXT,
  obs_id     TEXT,
  detail     TEXT,
  device     TEXT,
  at         TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.ctpa_log         IS 'Append-only activity log for all observation events.';
COMMENT ON COLUMN public.ctpa_log.site    IS 'Site ID — always ''bkk22'' for this project.';
COMMENT ON COLUMN public.ctpa_log.who     IS 'User identifier (device name or username).';
COMMENT ON COLUMN public.ctpa_log.action  IS 'Event type: create | edit | delete | approve_closure | reject_closure | submit_closure | visit.';
COMMENT ON COLUMN public.ctpa_log.obs_id  IS 'Observation ID this event relates to (e.g. OBS-001).';
COMMENT ON COLUMN public.ctpa_log.detail  IS 'Human-readable detail string.';
COMMENT ON COLUMN public.ctpa_log.device  IS 'Device type: Desktop | Mobile.';
COMMENT ON COLUMN public.ctpa_log.at      IS 'UTC timestamp of the event.';


-- ════════════════════════════════════════════════════════════
-- INDEXES
-- ════════════════════════════════════════════════════════════

-- ctpa_log: fast lookup by site + time (most common query pattern)
CREATE INDEX IF NOT EXISTS ctpa_log_site_at
  ON public.ctpa_log (site, at DESC);


-- ════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY — ctpa_state
--
-- The anon key is embedded in the HTML app (no server-side auth).
-- All browser traffic uses the anon role.
--
-- Policy summary:
--   SELECT  — anon can read the bkk22 row
--   INSERT  — anon can create new site rows (POST upsert fallback)
--   UPDATE  — anon can PATCH existing rows
--             CRITICAL: both USING and WITH CHECK required.
--             Missing WITH CHECK causes HTTP 403 on every PATCH.
--   DELETE  — anon can delete rows
-- ════════════════════════════════════════════════════════════

ALTER TABLE public.ctpa_state ENABLE ROW LEVEL SECURITY;

-- Drop all existing policies (idempotent — handles legacy names)
DROP POLICY IF EXISTS "state_select"                    ON public.ctpa_state;
DROP POLICY IF EXISTS "state_insert"                    ON public.ctpa_state;
DROP POLICY IF EXISTS "state_update"                    ON public.ctpa_state;
DROP POLICY IF EXISTS "state_delete"                    ON public.ctpa_state;
DROP POLICY IF EXISTS "allow_select"                    ON public.ctpa_state;
DROP POLICY IF EXISTS "allow_insert"                    ON public.ctpa_state;
DROP POLICY IF EXISTS "allow_update"                    ON public.ctpa_state;
DROP POLICY IF EXISTS "allow_delete"                    ON public.ctpa_state;
DROP POLICY IF EXISTS "Enable read access for all users" ON public.ctpa_state;
DROP POLICY IF EXISTS "Enable insert for all users"     ON public.ctpa_state;
DROP POLICY IF EXISTS "Enable update for all users"     ON public.ctpa_state;
DROP POLICY IF EXISTS "obs_select_anon"                 ON public.ctpa_state;
DROP POLICY IF EXISTS "obs_insert_anon"                 ON public.ctpa_state;
DROP POLICY IF EXISTS "obs_update_anon"                 ON public.ctpa_state;
DROP POLICY IF EXISTS "obs_delete_anon"                 ON public.ctpa_state;
DROP POLICY IF EXISTS "state_select_anon"               ON public.ctpa_state;
DROP POLICY IF EXISTS "state_upsert_anon"               ON public.ctpa_state;

-- SELECT
CREATE POLICY "state_select"
  ON public.ctpa_state
  FOR SELECT
  USING (true);

-- INSERT (needed for POST upsert fallback when PATCH finds 0 rows)
CREATE POLICY "state_insert"
  ON public.ctpa_state
  FOR INSERT
  WITH CHECK (true);

-- UPDATE — app uses PATCH /rest/v1/ctpa_state?id=eq.bkk22
-- BOTH USING and WITH CHECK are mandatory for PATCH to succeed.
CREATE POLICY "state_update"
  ON public.ctpa_state
  FOR UPDATE
  USING (true)
  WITH CHECK (true);

-- DELETE
CREATE POLICY "state_delete"
  ON public.ctpa_state
  FOR DELETE
  USING (true);


-- ════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY — ctpa_log
--
-- SELECT  — anon can read activity log
-- INSERT  — anon can write activity events
-- (No UPDATE or DELETE — log is append-only)
-- ════════════════════════════════════════════════════════════

ALTER TABLE public.ctpa_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "log_select"                      ON public.ctpa_log;
DROP POLICY IF EXISTS "log_insert"                      ON public.ctpa_log;
DROP POLICY IF EXISTS "log_update"                      ON public.ctpa_log;
DROP POLICY IF EXISTS "log_delete"                      ON public.ctpa_log;
DROP POLICY IF EXISTS "allow_select"                    ON public.ctpa_log;
DROP POLICY IF EXISTS "allow_insert"                    ON public.ctpa_log;
DROP POLICY IF EXISTS "Enable read access for all users" ON public.ctpa_log;
DROP POLICY IF EXISTS "Enable insert for all users"     ON public.ctpa_log;
DROP POLICY IF EXISTS "log_select_anon"                 ON public.ctpa_log;
DROP POLICY IF EXISTS "log_insert_anon"                 ON public.ctpa_log;

CREATE POLICY "log_select"
  ON public.ctpa_log
  FOR SELECT
  USING (true);

CREATE POLICY "log_insert"
  ON public.ctpa_log
  FOR INSERT
  WITH CHECK (true);


-- ════════════════════════════════════════════════════════════
-- SEED — ensure bkk22 row exists in ctpa_state
--
-- The app uses PATCH (UPDATE) as primary write, with POST
-- (INSERT) as fallback. If the bkk22 row is missing, PATCH
-- silently matches 0 rows and data is never saved.
-- This INSERT ensures the row always exists.
-- ════════════════════════════════════════════════════════════

INSERT INTO public.ctpa_state (id, data, updated_at)
VALUES ('bkk22', '[]'::jsonb, now())
ON CONFLICT (id) DO NOTHING;


-- ════════════════════════════════════════════════════════════
-- OBSERVATION OBJECT SCHEMA (reference — stored in data[])
--
-- Each element of ctpa_state.data is a JSON object with:
-- ════════════════════════════════════════════════════════════
/*
{
  "id"           : "OBS-001",          -- TEXT PRIMARY KEY
  "date"         : "2026-06-16",       -- DATE (YYYY-MM-DD)
  "week"         : "W25",              -- TEXT
  "zone"         : "1F · Data Hall",   -- TEXT (Floor · Area)
  "company"      : "RITTA",            -- TEXT (responsible contractor)
  "cat"          : "Electrical Safety (HRA)",  -- TEXT category
  "fc"           : "Daily Site Inspection (GC : Subcon)", -- TEXT finding category
  "obsType"      : "UNSAFE_ACT",       -- UNSAFE_ACT | UNSAFE_CON | GOOD_OBS
  "desc"         : "Hazard description...",    -- TEXT
  "rect"         : "Corrective action...",     -- TEXT
  "risk"         : "SERIOUS",          -- SERIOUS | MAJOR | MINOR
  "status"       : "OPEN",             -- OPEN | IN_PROGRESS | PENDING_VERIFY | CLOSED
  "by"           : "K. Attakorn",      -- TEXT (raised by / assigned to)
  "due"          : "2026-06-23",       -- DATE (YYYY-MM-DD)
  "closed"       : "2026-06-16",       -- DATE (YYYY-MM-DD) — set when status=CLOSED
  "closedBy"     : "K. Attakorn",      -- TEXT — who performed the close action

  -- Photos: arrays of photo objects
  "pb"           : [                   -- Before-fix photos
    {
      "id"   : 1718528400123.45,       -- NUMBER (Date.now() + Math.random())
      "src"  : "data:image/jpeg;base64,...",  -- base64 data URI
      "name" : "before.jpg",           -- TEXT original filename
      "at"   : "2026-06-16"            -- DATE added
    }
  ],
  "pa"           : [ ... ],            -- After-fix photos (same structure as pb)

  -- Approval workflow fields
  "approvalStatus"           : "PENDING REVIEW",  -- OPEN | PENDING REVIEW | APPROVED CLOSED | REJECTED
  "submittedForClosureBy"    : "K. Attakorn",
  "submittedForClosureDate"  : "2026-06-16",
  "clientApprovedBy"         : "GC Manager Name",   -- GC Manager approval
  "clientApprovedDate"       : "2026-06-16 10:30",
  "lpApprovedBy"             : "PMC Manager Name",  -- PMC Manager approval
  "lpApprovedDate"           : "2026-06-16 11:00",
  "approvedBy"               : "GC Manager + PMC Manager",
  "approvedDate"             : "2026-06-16 11:00",
  "approvalComment"          : "Approved after site verification.",
  "rejectedBy"               : "",
  "rejectedDate"             : "",

  -- v25c migration marker
  "_v"           : 1                   -- schema version (added by ctpaMigrate())
}
*/


-- ════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES — run after restore to confirm schema
-- ════════════════════════════════════════════════════════════

-- 1. Confirm tables exist
SELECT table_name, table_type
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('ctpa_state', 'ctpa_log')
ORDER BY table_name;

-- 2. Confirm bkk22 row and observation count
SELECT
  id,
  updated_at,
  jsonb_array_length(data) AS obs_count,
  pg_size_pretty(octet_length(data::text)::bigint) AS data_size
FROM public.ctpa_state
WHERE id = 'bkk22';

-- 3. Confirm all RLS policies (expect 4 on ctpa_state, 2 on ctpa_log)
SELECT
  tablename,
  policyname,
  cmd,
  qual        AS using_clause,
  with_check  AS with_check_clause
FROM pg_policies
WHERE tablename IN ('ctpa_state', 'ctpa_log')
ORDER BY tablename, cmd;

-- 4. Confirm indexes
SELECT
  indexname,
  tablename,
  indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename IN ('ctpa_state', 'ctpa_log')
ORDER BY tablename, indexname;

-- 5. Smoke-test UPDATE (must return 1 row — proves PATCH will work)
UPDATE public.ctpa_state
SET updated_at = now()
WHERE id = 'bkk22'
RETURNING id, updated_at, jsonb_array_length(data) AS obs_count;

-- 6. Smoke-test INSERT to ctpa_log (proves log writes will work)
INSERT INTO public.ctpa_log (site, who, action, detail, device)
VALUES ('bkk22', 'SCHEMA_BACKUP', 'schema_restore_verify', 'Schema backup verified OK', 'SQL Editor')
RETURNING id, at;

-- 7. Latest 5 activity log entries
SELECT id, at, who, action, obs_id, detail, device
FROM public.ctpa_log
WHERE site = 'bkk22'
ORDER BY at DESC
LIMIT 5;
