-- ============================================================
-- SCHEMA BACKUP — EHS Observation Tracker
-- Project  : CTPA BKK22 Chonburi Tech Park
-- Generated: 2026-06-16
-- Supabase : ocwdnvblpjfzkgzratqb.supabase.co
--
-- Reflects the ACTUAL live schema (ctpa_state has id + data only;
-- no updated_at column in production).
--
-- Run in: Supabase Dashboard → SQL Editor → New query
-- Safe to re-run (all statements are idempotent).
-- DO NOT add or remove columns — this script matches the live table.
-- ============================================================


-- ════════════════════════════════════════════════════════════
-- TABLE 1: ctpa_state
-- Purpose : Single-row JSONB blob storing ALL observations.
--           One row per site (id = 'bkk22').
--           The entire obs array is read/written as one payload.
--
-- ACTUAL COLUMNS (production):
--   id    TEXT  — site identifier, always 'bkk22'
--   data  JSONB — full observation array
--
-- NOTE: updated_at does NOT exist in the production table.
-- ════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.ctpa_state (
  id    TEXT   PRIMARY KEY,
  data  JSONB  NOT NULL DEFAULT '[]'::jsonb
);

COMMENT ON TABLE  public.ctpa_state      IS 'Single-row observation blob per site. id=bkk22 for CTPA BKK22.';
COMMENT ON COLUMN public.ctpa_state.id   IS 'Site identifier — always ''bkk22'' for this project.';
COMMENT ON COLUMN public.ctpa_state.data IS 'Full observation array as JSONB. Each element is one EHS observation object.';


-- ════════════════════════════════════════════════════════════
-- TABLE 2: ctpa_log
-- Purpose : Append-only activity log. One row per event.
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

CREATE INDEX IF NOT EXISTS ctpa_log_site_at
  ON public.ctpa_log (site, at DESC);


-- ════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY — ctpa_state
-- ════════════════════════════════════════════════════════════

ALTER TABLE public.ctpa_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "state_select"                     ON public.ctpa_state;
DROP POLICY IF EXISTS "state_insert"                     ON public.ctpa_state;
DROP POLICY IF EXISTS "state_update"                     ON public.ctpa_state;
DROP POLICY IF EXISTS "state_delete"                     ON public.ctpa_state;
DROP POLICY IF EXISTS "allow_select"                     ON public.ctpa_state;
DROP POLICY IF EXISTS "allow_insert"                     ON public.ctpa_state;
DROP POLICY IF EXISTS "allow_update"                     ON public.ctpa_state;
DROP POLICY IF EXISTS "allow_delete"                     ON public.ctpa_state;
DROP POLICY IF EXISTS "Enable read access for all users" ON public.ctpa_state;
DROP POLICY IF EXISTS "Enable insert for all users"      ON public.ctpa_state;
DROP POLICY IF EXISTS "Enable update for all users"      ON public.ctpa_state;
DROP POLICY IF EXISTS "state_select_anon"                ON public.ctpa_state;
DROP POLICY IF EXISTS "state_upsert_anon"                ON public.ctpa_state;
DROP POLICY IF EXISTS "obs_select_anon"                  ON public.ctpa_state;
DROP POLICY IF EXISTS "obs_insert_anon"                  ON public.ctpa_state;
DROP POLICY IF EXISTS "obs_update_anon"                  ON public.ctpa_state;
DROP POLICY IF EXISTS "obs_delete_anon"                  ON public.ctpa_state;

CREATE POLICY "state_select"
  ON public.ctpa_state FOR SELECT USING (true);

CREATE POLICY "state_insert"
  ON public.ctpa_state FOR INSERT WITH CHECK (true);

-- CRITICAL: UPDATE needs BOTH USING and WITH CHECK.
-- Missing WITH CHECK (true) causes HTTP 403 on every PATCH.
CREATE POLICY "state_update"
  ON public.ctpa_state FOR UPDATE
  USING (true) WITH CHECK (true);

CREATE POLICY "state_delete"
  ON public.ctpa_state FOR DELETE USING (true);


-- ════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY — ctpa_log
-- ════════════════════════════════════════════════════════════

ALTER TABLE public.ctpa_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "log_select"                       ON public.ctpa_log;
DROP POLICY IF EXISTS "log_insert"                       ON public.ctpa_log;
DROP POLICY IF EXISTS "log_update"                       ON public.ctpa_log;
DROP POLICY IF EXISTS "log_delete"                       ON public.ctpa_log;
DROP POLICY IF EXISTS "allow_select"                     ON public.ctpa_log;
DROP POLICY IF EXISTS "allow_insert"                     ON public.ctpa_log;
DROP POLICY IF EXISTS "Enable read access for all users" ON public.ctpa_log;
DROP POLICY IF EXISTS "Enable insert for all users"      ON public.ctpa_log;
DROP POLICY IF EXISTS "log_select_anon"                  ON public.ctpa_log;
DROP POLICY IF EXISTS "log_insert_anon"                  ON public.ctpa_log;

CREATE POLICY "log_select"
  ON public.ctpa_log FOR SELECT USING (true);

CREATE POLICY "log_insert"
  ON public.ctpa_log FOR INSERT WITH CHECK (true);


-- ════════════════════════════════════════════════════════════
-- SEED — ensure bkk22 row exists
-- Only inserts (id, data). No updated_at — column does not exist.
-- ════════════════════════════════════════════════════════════

INSERT INTO public.ctpa_state (id, data)
VALUES ('bkk22', '[]'::jsonb)
ON CONFLICT (id) DO NOTHING;


-- ════════════════════════════════════════════════════════════
-- OBSERVATION OBJECT SCHEMA (reference — stored in data[])
-- ════════════════════════════════════════════════════════════
/*
Each element of ctpa_state.data is a JSON object:
{
  "id"                       : "OBS-001",
  "date"                     : "2026-06-16",
  "week"                     : "W25",
  "zone"                     : "1F · Data Hall",
  "company"                  : "RITTA",
  "cat"                      : "Electrical Safety (HRA)",
  "fc"                       : "Daily Site Inspection (GC : Subcon)",
  "obsType"                  : "UNSAFE_ACT",        -- | UNSAFE_CON | GOOD_OBS
  "desc"                     : "Hazard description...",
  "rect"                     : "Corrective action...",
  "risk"                     : "SERIOUS",            -- | MAJOR | MINOR
  "status"                   : "OPEN",               -- | IN_PROGRESS | PENDING_VERIFY | CLOSED
  "by"                       : "K. Attakorn",
  "due"                      : "2026-06-23",
  "closed"                   : "",
  "closedBy"                 : "",
  "pb"                       : [{ "id": 1234, "src": "data:image/jpeg;base64,...", "name": "before.jpg", "at": "2026-06-16" }],
  "pa"                       : [],
  "approvalStatus"           : "OPEN",
  "submittedForClosureBy"    : "",
  "submittedForClosureDate"  : "",
  "clientApprovedBy"         : "",
  "clientApprovedDate"       : "",
  "lpApprovedBy"             : "",
  "lpApprovedDate"           : "",
  "approvedBy"               : "",
  "approvedDate"             : "",
  "approvalComment"          : "",
  "rejectedBy"               : "",
  "rejectedDate"             : "",
  "_v"                       : 1
}
*/


-- ════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- Run these after restore to confirm everything is correct.
-- ════════════════════════════════════════════════════════════

-- 1. Confirm tables exist with correct columns
SELECT
  table_name,
  column_name,
  data_type,
  is_nullable,
  column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('ctpa_state', 'ctpa_log')
ORDER BY table_name, ordinal_position;

-- 2. Confirm bkk22 row and observation count
SELECT
  id,
  jsonb_array_length(data)                       AS obs_count,
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
SELECT indexname, tablename, indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename IN ('ctpa_state', 'ctpa_log')
ORDER BY tablename, indexname;

-- 5. Smoke-test UPDATE on ctpa_state using only real columns
--    Must return 1 row — proves PATCH from the app will work
UPDATE public.ctpa_state
SET data = data
WHERE id = 'bkk22'
RETURNING id, jsonb_array_length(data) AS obs_count;

-- 6. Smoke-test INSERT to ctpa_log
INSERT INTO public.ctpa_log (site, who, action, detail, device)
VALUES ('bkk22', 'SCHEMA_BACKUP', 'schema_restore_verify', 'Schema backup verified OK', 'SQL Editor')
RETURNING id, at;

-- 7. Latest 5 activity log entries
SELECT id, at, who, action, obs_id, detail, device
FROM public.ctpa_log
WHERE site = 'bkk22'
ORDER BY at DESC
LIMIT 5;
