-- ============================================================
-- EHS Observation Tracker — Supabase Schema Migration
-- Project : CTPA BKK22 Chonburi Tech Park
-- Run in  : Supabase SQL Editor (Database > SQL Editor > New query)
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 0. ENABLE UUID EXTENSION (required by gen_obs_id RPC)
-- ────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ────────────────────────────────────────────────────────────
-- 1. ENUM TYPES
-- ────────────────────────────────────────────────────────────
DO $$ BEGIN
  CREATE TYPE obs_risk_level AS ENUM ('SERIOUS', 'MAJOR', 'MINOR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE obs_status AS ENUM (
    'OPEN',
    'IN_PROGRESS',
    'PENDING_VERIFY',
    'CLOSED'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE obs_type AS ENUM (
    'GOOD_OBS',
    'UNSAFE_ACT',
    'UNSAFE_CON'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE obs_approval_status AS ENUM (
    'NONE',
    'PENDING REVIEW',
    'APPROVED CLOSED',
    'REJECTED'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ────────────────────────────────────────────────────────────
-- 2. OBSERVATIONS TABLE
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS observations (

  -- Primary key — format OBS-XXXXXXXX (8 uppercase hex chars from UUID)
  id                      TEXT        PRIMARY KEY,

  -- ── Core fields ──
  obs_date                DATE        NOT NULL,
  week                    TEXT,                         -- e.g. "W24"

  obs_type                obs_type    NOT NULL DEFAULT 'UNSAFE_ACT',

  -- Location
  zone                    TEXT,                         -- legacy composite "Floor · Area"
  floor                   TEXT,                         -- e.g. "1F", "External"
  area                    TEXT,                         -- e.g. "Data Hall", "Site Road"

  -- Classification
  responsible_company     TEXT,
  category                TEXT        NOT NULL,         -- e.g. "Electrical Safety (HRA)"
  finding_category        TEXT,                         -- e.g. "Daily Site Inspection (PMC)"
  risk_level              obs_risk_level NOT NULL DEFAULT 'MINOR',

  -- Workflow
  status                  obs_status  NOT NULL DEFAULT 'OPEN',
  due_date                DATE,
  raised_by               TEXT,                         -- app field: `by`

  -- Narrative
  hazard_description      TEXT        NOT NULL,         -- app field: `desc`
  corrective_action       TEXT,                         -- app field: `rect`

  -- Photos (base64 data-URL arrays stored as JSONB)
  before_photos           JSONB       NOT NULL DEFAULT '[]'::jsonb,
  after_photos            JSONB       NOT NULL DEFAULT '[]'::jsonb,

  -- ── Closure fields ──
  closed_date             DATE,                         -- app field: `closed`
  closed_by               TEXT,                         -- who performed the physical closure

  -- ── GC Manager approval ──
  gc_manager_approved     BOOLEAN     NOT NULL DEFAULT FALSE,
  gc_manager_approved_by  TEXT,                         -- app field: `clientApprovedBy`
  gc_manager_approved_date TIMESTAMPTZ,                 -- app field: `clientApprovedDate`

  -- ── PMC Manager approval ──
  pmc_manager_approved    BOOLEAN     NOT NULL DEFAULT FALSE,
  pmc_manager_approved_by TEXT,                         -- app field: `lpApprovedBy`
  pmc_manager_approved_date TIMESTAMPTZ,                -- app field: `lpApprovedDate`

  -- ── Approval workflow ──
  approval_status         obs_approval_status NOT NULL DEFAULT 'NONE',
  approved_by             TEXT,                         -- "GC Manager + PMC Manager" when both done
  approved_date           TIMESTAMPTZ,
  approval_comment        TEXT,

  -- ── Rejection ──
  rejected_by             TEXT,
  rejected_date           TIMESTAMPTZ,

  -- ── Submission for closure ──
  submitted_for_closure_by   TEXT,
  submitted_for_closure_date TIMESTAMPTZ,

  -- ── Audit ──
  created_by              TEXT,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE observations IS 'EHS Safety Observations — CTPA BKK22 Chonburi Tech Park';
COMMENT ON COLUMN observations.id              IS 'OBS-XXXXXXXX (8 hex chars from gen_random_uuid)';
COMMENT ON COLUMN observations.zone            IS 'Legacy composite zone string (Floor · Area)';
COMMENT ON COLUMN observations.before_photos   IS 'Array of base64 data-URL strings (before fix)';
COMMENT ON COLUMN observations.after_photos    IS 'Array of base64 data-URL strings (after fix)';
COMMENT ON COLUMN observations.gc_manager_approved IS 'TRUE when GC Manager has signed off on closure';
COMMENT ON COLUMN observations.pmc_manager_approved IS 'TRUE when PMC Manager has signed off on closure';

-- ────────────────────────────────────────────────────────────
-- 3. LEGACY BLOB TABLE (keep existing app sync working)
--    The current app writes the entire obs array as a single
--    JSON blob to ctpa_state. Keep this table so the live app
--    continues to work while you migrate gradually.
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ctpa_state (
  id    TEXT PRIMARY KEY,  -- 'bkk22'
  data  JSONB
);

-- ────────────────────────────────────────────────────────────
-- 4. ACTIVITY LOG TABLE
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ctpa_log (
  id         BIGSERIAL    PRIMARY KEY,
  site       TEXT         NOT NULL DEFAULT 'bkk22',
  who        TEXT,
  action     TEXT         NOT NULL,  -- create | edit | delete | approve_closure | ...
  obs_id     TEXT         REFERENCES observations(id) ON DELETE SET NULL,
  detail     TEXT,
  device     TEXT,
  at         TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ctpa_log_at     ON ctpa_log (at DESC);
CREATE INDEX IF NOT EXISTS idx_ctpa_log_obs_id ON ctpa_log (obs_id);

-- ────────────────────────────────────────────────────────────
-- 5. INDEXES
-- ────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_obs_status       ON observations (status);
CREATE INDEX IF NOT EXISTS idx_obs_risk         ON observations (risk_level);
CREATE INDEX IF NOT EXISTS idx_obs_date         ON observations (obs_date DESC);
CREATE INDEX IF NOT EXISTS idx_obs_due_date     ON observations (due_date);
CREATE INDEX IF NOT EXISTS idx_obs_company      ON observations (responsible_company);
CREATE INDEX IF NOT EXISTS idx_obs_floor        ON observations (floor);
CREATE INDEX IF NOT EXISTS idx_obs_approval     ON observations (approval_status);
CREATE INDEX IF NOT EXISTS idx_obs_created_at   ON observations (created_at DESC);

-- Partial index: quickly find open overdue observations
CREATE INDEX IF NOT EXISTS idx_obs_overdue ON observations (due_date)
  WHERE status != 'CLOSED' AND due_date IS NOT NULL;

-- ────────────────────────────────────────────────────────────
-- 6. AUTO-UPDATE updated_at TRIGGER
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_obs_updated_at ON observations;
CREATE TRIGGER trg_obs_updated_at
  BEFORE UPDATE ON observations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ────────────────────────────────────────────────────────────
-- 7. AUTO-APPROVE TRIGGER
--    When both gc_manager_approved AND pmc_manager_approved
--    become TRUE, automatically set approval_status to
--    'APPROVED CLOSED' and status to 'CLOSED'.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION auto_approve_closure()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.gc_manager_approved = TRUE AND NEW.pmc_manager_approved = TRUE
     AND NEW.approval_status != 'APPROVED CLOSED'
  THEN
    NEW.approval_status  = 'APPROVED CLOSED';
    NEW.status           = 'CLOSED';
    NEW.approved_by      = 'GC Manager + PMC Manager';
    NEW.approved_date    = NOW();
    IF NEW.closed_date IS NULL THEN
      NEW.closed_date = CURRENT_DATE;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_approve ON observations;
CREATE TRIGGER trg_auto_approve
  BEFORE INSERT OR UPDATE ON observations
  FOR EACH ROW EXECUTE FUNCTION auto_approve_closure();

-- ────────────────────────────────────────────────────────────
-- 8. RPC: gen_obs_id() — returns UUID for client-side use
--    Called by the app's genObsId() function before creating
--    a new observation. Returns the raw UUID; the app
--    formats it as OBS-XXXXXXXX.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION gen_obs_id()
RETURNS UUID
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT gen_random_uuid();
$$;

-- ────────────────────────────────────────────────────────────
-- 9. RPC: upsert_observation(payload JSONB)
--    Safe single-row upsert. The app can call this to write
--    individual observations without replacing the full blob.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION upsert_observation(payload JSONB)
RETURNS observations
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result observations;
BEGIN
  INSERT INTO observations (
    id, obs_date, week, obs_type,
    zone, floor, area,
    responsible_company, category, finding_category, risk_level,
    status, due_date, raised_by,
    hazard_description, corrective_action,
    before_photos, after_photos,
    closed_date, closed_by,
    gc_manager_approved, gc_manager_approved_by, gc_manager_approved_date,
    pmc_manager_approved, pmc_manager_approved_by, pmc_manager_approved_date,
    approval_status, approved_by, approved_date, approval_comment,
    rejected_by, rejected_date,
    submitted_for_closure_by, submitted_for_closure_date,
    created_by
  ) VALUES (
    payload->>'id',
    (payload->>'date')::DATE,
    payload->>'week',
    COALESCE((payload->>'obsType')::obs_type,  'UNSAFE_ACT'),
    payload->>'zone',
    payload->>'floor',
    payload->>'area',
    payload->>'company',
    payload->>'cat',
    payload->>'fc',
    COALESCE((payload->>'risk')::obs_risk_level, 'MINOR'),
    COALESCE((payload->>'status')::obs_status,   'OPEN'),
    NULLIF(payload->>'due',    '')::DATE,
    payload->>'by',
    payload->>'desc',
    payload->>'rect',
    COALESCE(payload->'pb', '[]'::jsonb),
    COALESCE(payload->'pa', '[]'::jsonb),
    NULLIF(payload->>'closed', '')::DATE,
    payload->>'closedBy',
    COALESCE((payload->>'clientApprovedBy') IS NOT NULL AND (payload->>'clientApprovedBy') != '', FALSE),
    payload->>'clientApprovedBy',
    NULLIF(payload->>'clientApprovedDate', '')::TIMESTAMPTZ,
    COALESCE((payload->>'lpApprovedBy') IS NOT NULL AND (payload->>'lpApprovedBy') != '', FALSE),
    payload->>'lpApprovedBy',
    NULLIF(payload->>'lpApprovedDate', '')::TIMESTAMPTZ,
    COALESCE((payload->>'approvalStatus')::obs_approval_status, 'NONE'),
    payload->>'approvedBy',
    NULLIF(payload->>'approvedDate', '')::TIMESTAMPTZ,
    payload->>'approvalComment',
    payload->>'rejectedBy',
    NULLIF(payload->>'rejectedDate', '')::TIMESTAMPTZ,
    payload->>'submittedForClosureBy',
    NULLIF(payload->>'submittedForClosureDate', '')::TIMESTAMPTZ,
    payload->>'by'
  )
  ON CONFLICT (id) DO UPDATE SET
    obs_date                    = EXCLUDED.obs_date,
    week                        = EXCLUDED.week,
    obs_type                    = EXCLUDED.obs_type,
    zone                        = EXCLUDED.zone,
    floor                       = EXCLUDED.floor,
    area                        = EXCLUDED.area,
    responsible_company         = EXCLUDED.responsible_company,
    category                    = EXCLUDED.category,
    finding_category            = EXCLUDED.finding_category,
    risk_level                  = EXCLUDED.risk_level,
    status                      = EXCLUDED.status,
    due_date                    = EXCLUDED.due_date,
    raised_by                   = EXCLUDED.raised_by,
    hazard_description          = EXCLUDED.hazard_description,
    corrective_action           = EXCLUDED.corrective_action,
    before_photos               = EXCLUDED.before_photos,
    after_photos                = EXCLUDED.after_photos,
    closed_date                 = EXCLUDED.closed_date,
    closed_by                   = EXCLUDED.closed_by,
    gc_manager_approved         = EXCLUDED.gc_manager_approved,
    gc_manager_approved_by      = EXCLUDED.gc_manager_approved_by,
    gc_manager_approved_date    = EXCLUDED.gc_manager_approved_date,
    pmc_manager_approved        = EXCLUDED.pmc_manager_approved,
    pmc_manager_approved_by     = EXCLUDED.pmc_manager_approved_by,
    pmc_manager_approved_date   = EXCLUDED.pmc_manager_approved_date,
    approval_status             = EXCLUDED.approval_status,
    approved_by                 = EXCLUDED.approved_by,
    approved_date               = EXCLUDED.approved_date,
    approval_comment            = EXCLUDED.approval_comment,
    rejected_by                 = EXCLUDED.rejected_by,
    rejected_date               = EXCLUDED.rejected_date,
    submitted_for_closure_by    = EXCLUDED.submitted_for_closure_by,
    submitted_for_closure_date  = EXCLUDED.submitted_for_closure_date
  RETURNING * INTO result;
  RETURN result;
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 10. ROW LEVEL SECURITY
-- ────────────────────────────────────────────────────────────
ALTER TABLE observations ENABLE ROW LEVEL SECURITY;
ALTER TABLE ctpa_log     ENABLE ROW LEVEL SECURITY;
ALTER TABLE ctpa_state   ENABLE ROW LEVEL SECURITY;

-- Drop existing policies to allow clean re-run
DROP POLICY IF EXISTS "obs_select_anon"  ON observations;
DROP POLICY IF EXISTS "obs_insert_anon"  ON observations;
DROP POLICY IF EXISTS "obs_update_anon"  ON observations;
DROP POLICY IF EXISTS "obs_delete_anon"  ON observations;

DROP POLICY IF EXISTS "log_select_anon"  ON ctpa_log;
DROP POLICY IF EXISTS "log_insert_anon"  ON ctpa_log;

DROP POLICY IF EXISTS "state_select_anon" ON ctpa_state;
DROP POLICY IF EXISTS "state_upsert_anon" ON ctpa_state;

-- ── observations ──
-- SELECT: anyone with the anon key can read (site is not public, key is embedded in app)
CREATE POLICY "obs_select_anon"
  ON observations FOR SELECT
  TO anon
  USING (TRUE);

-- INSERT: anon can insert new observations
CREATE POLICY "obs_insert_anon"
  ON observations FOR INSERT
  TO anon
  WITH CHECK (TRUE);

-- UPDATE: anon can update (manager code enforced at app layer)
CREATE POLICY "obs_update_anon"
  ON observations FOR UPDATE
  TO anon
  USING (TRUE)
  WITH CHECK (TRUE);

-- DELETE: only authenticated service role can delete (no hard-deletes from browser)
CREATE POLICY "obs_delete_anon"
  ON observations FOR DELETE
  TO anon
  USING (FALSE);  -- block all browser deletes; use status='CLOSED' instead

-- ── ctpa_log ──
CREATE POLICY "log_select_anon"
  ON ctpa_log FOR SELECT
  TO anon
  USING (TRUE);

CREATE POLICY "log_insert_anon"
  ON ctpa_log FOR INSERT
  TO anon
  WITH CHECK (TRUE);

-- ── ctpa_state (legacy blob) ──
CREATE POLICY "state_select_anon"
  ON ctpa_state FOR SELECT
  TO anon
  USING (id = 'bkk22');

CREATE POLICY "state_upsert_anon"
  ON ctpa_state FOR ALL
  TO anon
  USING (id = 'bkk22')
  WITH CHECK (id = 'bkk22');

-- ────────────────────────────────────────────────────────────
-- 11. GRANT RPC EXECUTION TO ANON ROLE
-- ────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION gen_obs_id()             TO anon;
GRANT EXECUTE ON FUNCTION upsert_observation(JSONB) TO anon;

-- ────────────────────────────────────────────────────────────
-- 12. MIGRATION: import existing blob data into observations
--     Run AFTER the app has been live for a while and you want
--     to move from blob storage to individual rows.
--     Safe to run multiple times (ON CONFLICT DO NOTHING).
-- ────────────────────────────────────────────────────────────
/*  — UNCOMMENT WHEN READY TO MIGRATE —

INSERT INTO observations (
  id, obs_date, week, obs_type,
  zone, floor, area,
  responsible_company, category, finding_category, risk_level,
  status, due_date, raised_by,
  hazard_description, corrective_action,
  before_photos, after_photos,
  closed_date, closed_by,
  gc_manager_approved, gc_manager_approved_by, gc_manager_approved_date,
  pmc_manager_approved, pmc_manager_approved_by, pmc_manager_approved_date,
  approval_status, approved_by, approved_date, approval_comment,
  rejected_by, rejected_date,
  submitted_for_closure_by, submitted_for_closure_date,
  created_by
)
SELECT
  item->>'id',
  (item->>'date')::DATE,
  item->>'week',
  CASE item->>'obsType'
    WHEN 'GOOD_OBS'   THEN 'GOOD_OBS'::obs_type
    WHEN 'UNSAFE_CON' THEN 'UNSAFE_CON'::obs_type
    ELSE 'UNSAFE_ACT'::obs_type
  END,
  item->>'zone',
  split_part(item->>'zone', ' · ', 1),
  split_part(item->>'zone', ' · ', 2),
  item->>'company',
  item->>'cat',
  item->>'fc',
  CASE item->>'risk'
    WHEN 'SERIOUS' THEN 'SERIOUS'::obs_risk_level
    WHEN 'MAJOR'   THEN 'MAJOR'::obs_risk_level
    ELSE 'MINOR'::obs_risk_level
  END,
  CASE item->>'status'
    WHEN 'CLOSED'        THEN 'CLOSED'::obs_status
    WHEN 'IN_PROGRESS'   THEN 'IN_PROGRESS'::obs_status
    WHEN 'PENDING_VERIFY'THEN 'PENDING_VERIFY'::obs_status
    ELSE 'OPEN'::obs_status
  END,
  NULLIF(item->>'due',    '')::DATE,
  item->>'by',
  item->>'desc',
  item->>'rect',
  COALESCE(item->'pb', '[]'::jsonb),
  COALESCE(item->'pa', '[]'::jsonb),
  NULLIF(item->>'closed', '')::DATE,
  item->>'closedBy',
  (item->>'clientApprovedBy') IS NOT NULL AND (item->>'clientApprovedBy') != '',
  item->>'clientApprovedBy',
  NULLIF(item->>'clientApprovedDate', '')::TIMESTAMPTZ,
  (item->>'lpApprovedBy') IS NOT NULL AND (item->>'lpApprovedBy') != '',
  item->>'lpApprovedBy',
  NULLIF(item->>'lpApprovedDate', '')::TIMESTAMPTZ,
  COALESCE(
    NULLIF(item->>'approvalStatus', '')::obs_approval_status,
    CASE WHEN item->>'status' = 'CLOSED' THEN 'APPROVED CLOSED'::obs_approval_status
         ELSE 'NONE'::obs_approval_status END
  ),
  item->>'approvedBy',
  NULLIF(item->>'approvedDate', '')::TIMESTAMPTZ,
  item->>'approvalComment',
  item->>'rejectedBy',
  NULLIF(item->>'rejectedDate', '')::TIMESTAMPTZ,
  item->>'submittedForClosureBy',
  NULLIF(item->>'submittedForClosureDate', '')::TIMESTAMPTZ,
  item->>'by'
FROM ctpa_state,
     jsonb_array_elements(data) AS item
WHERE id = 'bkk22'
  AND (item->>'id') IS NOT NULL
  AND (item->>'id') != ''
ON CONFLICT (id) DO NOTHING;

*/

-- ────────────────────────────────────────────────────────────
-- 13. VERIFY — run these SELECTs to confirm schema is correct
-- ────────────────────────────────────────────────────────────
/*
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = 'observations'
ORDER BY ordinal_position;

SELECT tablename, policyname, cmd, qual
FROM pg_policies
WHERE tablename IN ('observations', 'ctpa_log', 'ctpa_state');

SELECT routine_name FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN ('gen_obs_id', 'upsert_observation', 'set_updated_at', 'auto_approve_closure');
*/
