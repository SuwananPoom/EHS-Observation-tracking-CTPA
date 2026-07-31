# EHS Observation Tracking System — Comprehensive Read-Only Audit
**Project:** CTPA BKK22 · **Date:** 31 Jul 2026 · **Code baseline:** commit `83ca964` (deployed)
**Mode:** Inspection & diagnosis only — no code or data was modified during this audit.

---

## Scope covered (15 areas)
1 Approval Workflow · 2 Dashboard Status Calculation · 3 Closure Status Chart · 4 Observation List · 5 Observation Detail · 6 Admin Override · 7 Reject Workflow · 8 Dashboard Navigation · 9 Permission Validation · 10 Database Structure · 11 API/Sync · 12 Mobile · 13 Reports/Exports · 14 Images · 15 Data Integrity

**Overall verdict:** The core workflow engine (effStatus / effAp centralization, sequential GC→PMC approval, admin override, stage-scoped reject, auto Pending-Verify on After photo) is correctly implemented and internally consistent at the dashboard/list/detail level. The issues found are: one double-counting bug in the Closure chart, one stale-resolver badge label, several report/export paths still using raw stored status, one data-clearing behavior in Reject that conflicts with the "preserve all data" rule, and the known architectural limitation that all enforcement is client-side only.

---

## ISSUES FOUND

### Issue #1 — No server-side enforcement of permissions or workflow
- **Location:** Architecture-wide. Supabase is accessed with the public anon key; `ctpa_state` and Storage bucket `ctpa-photos` are writable by any client that loads the page. All role checks (`canApproveGC`, `canApprovePMC`, admin override, reject guards) run only in browser JavaScript.
- **Root Cause:** No Row Level Security policies restricting writes by role; no Edge Function mediating approval transitions.
- **Impact:** Any user (or anyone with the anon key, which is embedded in the page source) can bypass every approval rule by calling the Supabase API directly — approve, close, reject, or overwrite any observation, or delete photos. The UI enforcement is real for normal users but is not a security boundary.
- **Severity:** **Critical**
- **Recommended Fix:** Add RLS policies on `ctpa_state`/`ctpa_photos` keyed to `ctpa_user_profiles.role`, and move approval/reject transitions into a Supabase Edge Function that validates role + stage server-side. *(Requires your explicit approval — this touches database policy, per the data-protection constraint. Proposal available on request.)*
- **Risk of fix:** Medium (RLS misconfiguration could block legitimate saves; must be tested on a staging copy first). **Data impact if left unfixed: possible (external tampering).**

### Issue #2 — Closure Status chart double-counts Rejected observations
- **Location:** `index.html:6652–6653` (rejectClosure sets `status:"OPEN"` + `approvalStatus:"REJECTED"`) vs. chart buckets `index.html` donut (`Open = effStatus==="OPEN"`, `Rejected = effAp==="REJECTED"`).
- **Root Cause:** A rejected observation is simultaneously `effStatus === "OPEN"` and `effAp === "REJECTED"`, so it is counted in **both** the "Open" and "Rejected" slices. The same overlap affects the Open KPI card vs. the Rejected KPI card.
- **Impact:** Reconciliation formula fails: with your live numbers, Closed 1085 + Open 10 + In Progress 0 + Pending GC 2 + Pending PMC 0 + Rejected 3 = **1100**, but the 3 rejected records are also inside "Open 10", so the true total is likely **1097**. Donut percentages and the "buckets are mutually exclusive" guarantee are both violated.
- **Severity:** **High**
- **Recommended Fix:** Exclude rejected records from the Open bucket (`effStatus(o)==="OPEN" && effAp(o)!=="REJECTED"`) in the S counts used by the donut and cards. One-line-per-bucket change; display-only.
- **Risk of fix:** Low. **No data impact.**

### Issue #3 — Observation List badge label uses stale `apOf()` while its styling uses `effAp()`
- **Location:** `index.html:10051` — badge style resolved via `effAp(o)` but the visible label via `apOf(o)`.
- **Root Cause:** One call site missed during the OBS-1021 `effAp` migration (commit `00ee254`).
- **Impact:** For a GC-only "closed" record (the OBS-1021 class), the badge can render "Approved Closed" text with "Pending PMC" coloring — the exact inconsistency the resolver was built to eliminate.
- **Severity:** **High**
- **Recommended Fix:** Replace `apOf(o)` with `effAp(o)` at line 10051 (label side only).
- **Risk of fix:** Low. **No data impact.**

### Issue #4 — Reject clears both GC and PMC sign-offs regardless of stage
- **Location:** `index.html:6652–6664` — `rejectClosure` blanks `clientApprovedBy/Date` **and** `lpApprovedBy/Date` on every reject.
- **Root Cause:** Single reset block not scoped to the rejected stage.
- **Impact:** (a) A PMC-stage reject also erases the already-granted GC sign-off, forcing GC to re-approve — arguably intended, but undocumented. (b) **Data-loss edge case:** if a legacy client-era record (whose only sign-off is the historical `clientApprovedBy` you chose to preserve under Option A) is ever pushed through reject, that historical approval record is permanently erased, violating the "preserve approval history" constraint.
- **Severity:** **High** (because of the legacy-history erasure path)
- **Recommended Fix:** Scope the clearing to the rejected stage (PMC reject keeps GC fields), and never blank a `clientApprovedBy` that has no `clientApprovedRole` (legacy marker). Alternatively copy cleared values into `prevClientApprovedBy/...` audit fields before blanking.
- **Risk of fix:** Low. **Prevents future data loss; changes no existing data.**

### Issue #5 — Report/export paths still count by raw stored `o.status` instead of `effStatus`
- **Location:** `index.html:2087–2090` (Excel report Summary sheet: Open/In Progress/Pending Verify/Closed counts), `:2622` (contractor table in report generator), `:2854–2855` (report summary tiles Open/Closed).
- **Root Cause:** These report modules predate the effStatus centralization and were not included in the 43-site swap.
- **Impact:** Exported reports can disagree with the dashboard — e.g., a GC-only stored-CLOSED record counts as "Closed" in the Excel Summary sheet but "Pending Verify" on the dashboard. Same class of bug as OBS-1021, surviving only in exports.
- **Severity:** **Medium**
- **Recommended Fix:** Swap the four count sites to `effStatus(o)`; leave per-row raw fields (Closed By at `:2368`/`:2710`) as-is or swap for consistency.
- **Risk of fix:** Low (export/display only). **No data impact.**

### Issue #6 — Newest-wins merge depends on client clocks (`rev = Date.now()`)
- **Location:** `cloudMergeSave` / `pull()` merge logic.
- **Root Cause:** Conflict resolution compares client-generated timestamps. A device with a fast clock (minutes ahead) will win merges even when its edit is older in real time; a slow clock can silently lose a legitimate edit.
- **Impact:** Rare, hard-to-reproduce "my edit reverted" reports on multi-device use — the same symptom class you previously fixed, with a residual window.
- **Severity:** **Medium**
- **Recommended Fix:** Long-term: per-observation server timestamp (Edge Function or a `updated_at` column with a trigger). Short-term: keep as-is; the read-back verification already surfaces most losses.
- **Risk of fix:** Medium (touches sync path — defer unless the symptom recurs). **No data impact from auditing; fix must be carefully staged.**

### Issue #7 — Entire dataset stored as one JSONB row (`ctpa_state` id='bkk22')
- **Location:** Database structure.
- **Root Cause:** Original design: every save rewrites the full observation array (~1100 records).
- **Impact:** (a) Every save is a full-dataset overwrite — one corrupted write could affect all records (mitigated by merge + verify, but the blast radius remains total). (b) Payload grows linearly; save latency and mobile data use will keep increasing. (c) No row-level audit/versioning in Postgres.
- **Severity:** **Medium** (architectural)
- **Recommended Fix:** Migrate to one-row-per-observation table with RLS (combine with Issue #1). Until then: enable Supabase Point-in-Time Recovery / scheduled backups of `ctpa_state` as insurance.
- **Risk of fix:** High if rushed (migration touches all data) — do **not** do this without a dedicated, backed-up migration plan. **Backup recommendation has zero data impact.**

### Issue #8 — Base64 photo fallback (`ctpa_photos` table) growth and duplication
- **Location:** Photo persistence: originals go to Storage (deterministic paths), but base64 fallback rows remain in `ctpa_photos`, and display copies live in localStorage (≤1600px JPEG).
- **Root Cause:** Layered fallbacks accumulated across the photo-fix iterations; nothing prunes superseded base64 rows once a Storage URL exists.
- **Impact:** Database bloat and slower photo pulls; no functional error today. iPhone localStorage quota (~5MB) remains the binding constraint the display-copy design works around — very photo-heavy single observations could still evict entries.
- **Severity:** **Low**
- **Recommended Fix:** After connector returns: read-only query to measure `ctpa_photos` size and count rows whose Storage object exists; then (with your approval only) a pruning pass. Not urgent.
- **Risk of fix:** Medium (deletion) — **do not run without a verified Storage-side copy check.**

### Issue #9 — Overdue / Serious Open / Rejected / OBS-250WH KPI cards are not clickable
- **Location:** Dashboard KPI cards (commit `83ca964`).
- **Root Cause:** Intentional — the Observation List has no exact matching filter (overdue and serious-open are computed conditions, not status values).
- **Impact:** Minor UX inconsistency: some cards navigate, others don't (tooltip only appears on clickable ones, which signals this).
- **Severity:** **Low**
- **Recommended Fix:** Optional: add computed quick-filters ("Overdue", "Serious & Open", "Rejected") to the list page, then wire the cards. Rejected becomes trivial once Issue #2's bucket logic exists.
- **Risk of fix:** Low. **No data impact.**

### Issue #10 — Runtime data-integrity checks pending (connector disconnected)
- **Location:** Live database.
- **Root Cause:** The Supabase MCP connector is currently disconnected, so the following could not be executed: duplicate-ID scan, orphaned photo-reference sampling, live count reconciliation (which would confirm Issue #2's 1100-vs-1097 discrepancy), and rejected-record status distribution.
- **Impact:** Audit areas 10 and 15 are verified at code level only.
- **Severity:** **Medium** (verification gap, not a known defect)
- **Recommended Fix:** Read-only SQL for the Supabase SQL Editor (safe — SELECT only):
```sql
-- A. Total, and the Issue #2 overlap check
SELECT jsonb_array_length(data) AS total_obs FROM ctpa_state WHERE id='bkk22';
SELECT count(*) AS rejected_and_open
FROM ctpa_state, jsonb_array_elements(data) o
WHERE id='bkk22' AND o->>'approvalStatus'='REJECTED' AND o->>'status'='OPEN';
-- B. Duplicate IDs
SELECT o->>'id' AS obs_id, count(*) FROM ctpa_state, jsonb_array_elements(data) o
WHERE id='bkk22' GROUP BY 1 HAVING count(*)>1;
-- C. Status × approvalStatus distribution (full reconciliation matrix)
SELECT o->>'status' s, o->>'approvalStatus' a, count(*)
FROM ctpa_state, jsonb_array_elements(data) o WHERE id='bkk22'
GROUP BY 1,2 ORDER BY 3 DESC;
```
- **Risk:** None (read-only). **No data impact.**

---

## Areas inspected with NO issues found
- **Approval Workflow (1):** Sequence Open → After-photo auto Pending-Verify → GC → Pending PMC → PMC → Closed verified in code; Closed requires both sign-offs (or the approved legacy carve-out); auto-transition correctly guarded against already-advanced records.
- **Observation Detail (5):** Panel branches driven by `effAp(det)`; sign-off rows correctly annotate "· Admin Override" and "· legacy client-era approval"; approver identity recorded as the actual actor, never impersonated.
- **Admin Override (6):** GC and PMC overrides are separate buttons, each recording `Role:"Admin"` + audit log; no combined "force close" exists — matches spec.
- **Reject Workflow (7):** Reason required, stage-scoped authorization correct, full audit fields recorded. (Only the sign-off clearing scope — Issue #4 — needs attention.)
- **Permissions (9):** Role gates match spec: GC = contractor-matched `lm_gc`/`ritta_gc` or Admin; PMC = `pmc_manager` or Admin; UI visibility gates (Supabase bar, Reporting Period) correct. (Enforcement depth is Issue #1.)
- **Dashboard Navigation (8):** Card click-through is read-only (sets filters + view only); no mutation on navigation.
- **Mobile (12):** CSS-only media queries with `display:contents` wrappers; desktop DOM unchanged; confirmed working by your device testing.
- **Images (14):** Dual-copy upload (original → Storage, display copy local), deterministic Storage paths, `durl` recovery for old photos, EXIF normalization at export — all present and previously verified working.

---

## Reconciliation formula check
`Total OBS = Open + In Progress + Pending GC + Pending PMC + Approved Closed + Rejected`
- **Code level:** every bucket now uses the central resolvers — correct **except** the Open/Rejected overlap (Issue #2), which inflates the sum by the rejected count.
- **Your screenshot:** 1085 + 10 + 0 + 2 + 0 + 3 = 1100. Expected true total: **1097** if all 3 rejected records also have stored status OPEN (query A above confirms).

---

## SUMMARY

| Metric | Count |
|---|---|
| **Total issues found** | **10** |
| Critical | 1 (#1) |
| High | 3 (#2, #3, #4) |
| Medium | 4 (#5, #6, #7, #10) |
| Low | 2 (#8, #9) |

**Recommended implementation order** (after your review — nothing has been changed yet):
1. **#2** Rejected/Open double-count (one-line bucket fix; restores reconciliation) — no data impact
2. **#3** List badge `apOf`→`effAp` (one-line) — no data impact
3. **#4** Stage-scoped sign-off clearing in Reject (prevents future history loss) — no data impact
4. **#10** Run the read-only SQL to confirm live totals and close the verification gap
5. **#5** Report/export counts → effStatus — no data impact
6. **#1** Server-side enforcement proposal (RLS + Edge Function) — separate approved project with staging test
7. **#7** Backup enablement now; row-per-observation migration only as a planned project
8. **#6, #8, #9** — deferred / optional
