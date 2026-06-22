-- ============================================================
-- EHS Auth Setup — Run in Supabase SQL Editor
-- Creates: ctpa_user_profiles, ctpa_approval_logs, ctpa_login_logs
-- Does NOT touch: ctpa_state, ctpa_photos, ctpa_log, observations
-- ============================================================

-- ── 1. User Profiles (extends auth.users) ──────────────────
CREATE TABLE IF NOT EXISTS ctpa_user_profiles (
  id          UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email       TEXT,
  name        TEXT        NOT NULL DEFAULT '',
  company     TEXT        NOT NULL DEFAULT 'DayOne',
  role        TEXT        NOT NULL DEFAULT 'viewer',
  status      TEXT        NOT NULL DEFAULT 'active',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE ctpa_user_profiles IS 'EHS app user roles and company assignments';
COMMENT ON COLUMN ctpa_user_profiles.role IS
  'dayone_admin | dayone_user | ms_user | pmc_manager | lm_gc | ritta_gc | viewer';
COMMENT ON COLUMN ctpa_user_profiles.status IS 'active | disabled';

-- ── 2. Approval Logs ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ctpa_approval_logs (
  id          BIGSERIAL   PRIMARY KEY,
  obs_id      TEXT        NOT NULL,
  action      TEXT        NOT NULL,
  approved_by TEXT        NOT NULL,
  company     TEXT,
  role        TEXT,
  approved_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  remarks     TEXT
);

COMMENT ON TABLE ctpa_approval_logs IS 'GC/PMC approval history per observation';
COMMENT ON COLUMN ctpa_approval_logs.action IS
  'GC_APPROVE | PMC_APPROVE | GC_REJECT | PMC_REJECT | OVERRIDE_CLOSE';

CREATE INDEX IF NOT EXISTS idx_approval_logs_obs_id ON ctpa_approval_logs (obs_id);
CREATE INDEX IF NOT EXISTS idx_approval_logs_at     ON ctpa_approval_logs (approved_at DESC);

-- ── 3. Login Logs ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ctpa_login_logs (
  id          BIGSERIAL   PRIMARY KEY,
  user_id     UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  email       TEXT,
  login_time  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  device      TEXT,
  ip_address  TEXT
);

CREATE INDEX IF NOT EXISTS idx_login_logs_user_id ON ctpa_login_logs (user_id);
CREATE INDEX IF NOT EXISTS idx_login_logs_time    ON ctpa_login_logs (login_time DESC);

-- ── 4. Row Level Security ────────────────────────────────────
ALTER TABLE ctpa_user_profiles  ENABLE ROW LEVEL SECURITY;
ALTER TABLE ctpa_approval_logs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE ctpa_login_logs     ENABLE ROW LEVEL SECURITY;

-- ctpa_user_profiles: authenticated users can read their own row;
-- admin reads/writes all rows via service_role key from admin panel.
DROP POLICY IF EXISTS "profiles_select_own"  ON ctpa_user_profiles;
DROP POLICY IF EXISTS "profiles_select_all"  ON ctpa_user_profiles;
DROP POLICY IF EXISTS "profiles_insert_auth" ON ctpa_user_profiles;
DROP POLICY IF EXISTS "profiles_update_auth" ON ctpa_user_profiles;

CREATE POLICY "profiles_select_all"  ON ctpa_user_profiles
  FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY "profiles_insert_auth" ON ctpa_user_profiles
  FOR INSERT TO authenticated WITH CHECK (id = auth.uid());

CREATE POLICY "profiles_update_auth" ON ctpa_user_profiles
  FOR UPDATE TO authenticated
  USING (TRUE) WITH CHECK (TRUE);

-- approval_logs: authenticated users can read/insert
DROP POLICY IF EXISTS "applogs_select" ON ctpa_approval_logs;
DROP POLICY IF EXISTS "applogs_insert" ON ctpa_approval_logs;

CREATE POLICY "applogs_select" ON ctpa_approval_logs
  FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY "applogs_insert" ON ctpa_approval_logs
  FOR INSERT TO authenticated WITH CHECK (TRUE);

-- login_logs: insert only (no browser reads needed)
DROP POLICY IF EXISTS "loginlogs_insert" ON ctpa_login_logs;

CREATE POLICY "loginlogs_insert" ON ctpa_login_logs
  FOR INSERT TO authenticated WITH CHECK (TRUE);

-- ── 5. Auto-create profile on signup ────────────────────────
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.ctpa_user_profiles (id, email, name, company, role, status)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'name', ''),
    COALESCE(NEW.raw_user_meta_data->>'company', 'DayOne'),
    COALESCE(NEW.raw_user_meta_data->>'role', 'viewer'),
    'active'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ── 6. Verify ───────────────────────────────────────────────
/*
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('ctpa_user_profiles','ctpa_approval_logs','ctpa_login_logs');
*/
