# Dashboard Data Consistency Audit — Root Cause Report
**CTPA BKK22 · 2026-08-05 · Code baseline: commit `d99853d` (current main) · READ-ONLY — no code, data, or config changed**

All findings are in the single application file **`index.html`**. Runtime record IDs/counts could not be printed from this environment (Supabase is unreachable from the audit sandbox); §11 provides read-only SQL that prints them. Everything else below is traced directly from the deployed code.

---

## 1 ▸ Widget → data-source dependency map

| Widget | Function/site (index.html) | Dataset | Status resolver | Date filter |
|---|---|---|---|---|
| Total OBS card | `S.n` (≈6779) | `dsObs` | — | Reporting Period via `dsObs` (≈6730) |
| Open card | `S.outstanding` (≈6825) | `dsObs` | **`effAp` ≠ APPROVED CLOSED** (umbrella) | Reporting Period |
| Closed card | `S.closed` | `dsObs` | **`effStatus` = CLOSED** | Reporting Period |
| Approved Closed card | `S.apApproved` | `dsObs` | **`effAp` = APPROVED CLOSED** | Reporting Period |
| Pending Verify card | `S.apPendingGC` | `dsObs` | `effAp` = PENDING REVIEW | Reporting Period |
| Pending PMC card | `S.apPendingPMC` | `dsObs` | `effAp` = PENDING PMC APPROVAL | Reporting Period |
| Rejected card | `S.apRejected` | `dsObs` | `effAp` = REJECTED | Reporting Period |
| Overdue card | `S.od` → `isOD` (1968) | `dsObs` | `effStatus`+`effAp` | **`td()` = TODAY, never cut-off** |
| Good / Unsafe Act / Unsafe Cond cards | `S.good/uact/ucon` | `dsObs` | — (obsType) | Reporting Period |
| Observation Type chart (≈8150) | `S.good/uact/ucon/n` | `dsObs` | — | Reporting Period |
| **Closure Status chart — donut slices** (≈8060) | `S.closed / S.ip / S.open / S.pv` | `dsObs` | **`effStatus` buckets (4)** | Reporting Period |
| **Closure Status chart — legend** (≈8090) | `S.apApproved / S.open / S.ip / S.apPendingGC / S.apPendingPMC / S.apRejected` | `dsObs` | **`effAp` buckets (6)** | Reporting Period |
| Risk Level bars (≈8243) | inline `dsObs.filter(risk)` | `dsObs` | — (all statuses) | Reporting Period |
| Reporting Period summary tiles (≈9079) | `selCards` | **`obsAll` week-filtered** (Weekly+week) else `sel` | `effStatus` only | raised date in selected week |
| Weekly comparison chart/table (≈9122) | `wkSrc` | Selected-Week-Only → **`obsAll`** (W−4…W); Cumulative/All-Weeks → `sel` | count only | `weekPeriodMatch` on raised date |
| Top Area / Floor / Contractor (≈9097) | `tArea/tFloor/tCo` | **`sel` (= dsObs)** — *not* `selCards` | — | Reporting Period (cumulative in cut-off mode) |
| Card navigation (≈7975) | `k.nav → setFS/setFOT` | Observation List `filt` (≈6586) | list: `effStatus`/`effAp` | **list's own filters only** |

Central resolvers: `apOf` (≈1343), `effAp` (≈1370), `effStatus` (≈1393), all in `index.html`.

---

## 2 ▸ Same-dataset verification (W42 examples)

- **Weekly · W42 · Selected Week Only:** `dsObs` = records whose **raised date** is inside W42 → Main cards, both closure-chart halves, Risk, Type, Top lists, and summary tiles all use that same week-only set. Weekly chart deliberately widens to W38–W42 from `obsAll` (trend context; documented in code). **Consistent except the chart's wider window (by design).**
- **Weekly · W42 · Cumulative to Cut-off 30 Jul 2026:** `dsObs` = **everything raised ≤ 2026-07-30** (the W42 selection is ignored by `dsObs` — cut-off wins, ≈6735). Main cards, closure chart, Risk, Type, **and Top Area/Floor/Contractor** are cumulative — but the **summary tiles (`selCards`) are W42-only** (deliberate "CARDS-ONLY" rule, ≈9079). → In cumulative mode the Reporting-Period tiles and the Top lists on the same screen use **two different datasets**. This is the single biggest visible "cards ≠ charts" driver.
- Records with missing/malformed `date` are excluded from every specific period and from cumulative mode (regex guard), but included in "All Weeks".

## 3 ▸ Status calculation & the reconciliation identity

`effAp` maps every record to exactly one of {OPEN, PENDING REVIEW, PENDING PMC, APPROVED CLOSED, REJECTED} → **apOpen + apPendingGC + apPendingPMC + apApproved + apRejected = Total always holds** (no double counting possible in the effAp system).

The failures come from **mixing two bucket systems**:

- **F1 (Critical) — the Closure chart disagrees with its own legend.** The donut geometry uses 4 `effStatus` buckets (Closed/In Prog/Open/P.Verify — with S.open excluding Rejected, so **rejected records are in no slice**: slice sum < Total, percentages wrong). The legend beside it prints 6 `effAp` buckets with a *different* Closed definition. One widget, two datasets.
- **F2 (Critical) — the twin resolvers now diverge on the evidence rule.** `effStatus`: record without After photo that is closed-ish → **IN_PROGRESS**. `effAp`: same record → **OPEN**. The same observation therefore sits in "In Progress" in effStatus widgets and "Open" in effAp widgets. This affects **every legacy record without an After photo** — a large population — and is the main reason counts shifted and stopped matching after commit `5c215d3` (which also removed the legacy client-era CLOSED carve-out, moving ~894 legacy GC-only records from Closed → Pending PMC across the system).
- **F3 (High) — "Closed" has two definitions.** `S.closed` (effStatus: stored CLOSED + both sign-offs + After photo) vs `S.apApproved` (effAp: sign-offs support regardless of stored status). A record with `approvalStatus=APPROVED CLOSED`, both sign-offs, but stored status ≠ CLOSED counts in Approved-Closed but not Closed.
- **F4 (Medium) — Open card = Outstanding umbrella** (your explicit spec) overlaps Pending/Rejected cards and differs from the strict donut "Open" slice. Working as specified, but it *reads* as an inconsistency next to the strict slices.
- **F5 (Medium) — Reporting tiles' "Open" includes Rejected** (tiles use `effStatus` only, no `effAp≠REJECTED` exclusion, ≈9089) — unlike the main Open bucket and the list's OPEN filter.

## 4 ▸ Overdue

`isOD` (1968): `effStatus(o) !== "CLOSED" && effAp(o) !== "PENDING PMC APPROVAL" && o.due && o.due < td()`. **Uses `td()` (today) exclusively — the selected Cut-off date is never consulted**, in every widget (card, contractor tables, exports). So a cumulative-to-30-Jul view still computes overdue against today's date. Single consistent definition everywhere (no per-widget divergence) — but it ignores the reporting scope's cut-off by design.

## 5 ▸ Reporting-period filtering

Verified: **all** period branches (`dsObs` ≈6730, `weekPeriodMatch`, `getPeriodKey`, cumulative cut-off) filter **only on `o.date` (raised date)**. Closed date, approval dates, last-updated (`rev`), and photo timestamps are never used. ✓ Requirement met.

## 6 ▸ Why selecting W42 shows W13–W24

Weekly chart row builder (≈9142): in **Cumulative to Cut-off** (and All-Weeks) mode, `wkRows = __wkPeriods.filter(p → sel has records in p)` — **the selected week plays no role in choosing the rows**; the chart shows every anchored week that contains records raised on or before the cut-off. Your project's records were raised in a range that maps to anchored weeks **W13–W24** (anchor: W40 = 11–17 Jul 2026), so that is exactly what renders. W42 only drives the **summary tiles**. In Selected-Week-Only mode the chart correctly shows W38–W42. So: **not a broken week generator** (`weeklyPeriodsForYear` is contiguous 7-day anchored weeks; labels via `fmtWeekRange`; year from `qYearEff`) — it is the documented cumulative-mode row rule, which is **confusing but intentional**; the caption text does state it.

## 7 ▸ Top Area / Floor / Contractor

Computed from **`sel` = `dsObs`** (≈9097) — the current *reporting-period* dataset, **not** the whole project and **not** the week-only `selCards`. Count used = `sel.length` (printed in the section header line). Consequence: in Cumulative mode the Top lists summarize the cumulative set while the tiles directly above them summarize the selected week only (F6, Medium).

## 8 ▸ Dashboard navigation

`onClick` (≈7975) passes **only** `fSt` (status) and `fOT` (type) and switches to the list. **Lost: Reporting Period mode, selected Week, Year, Cumulative cut-off, Contractor, Floor, Area, Risk** — the list opens with its own independent filters (its Reporting-Week dropdown, date range, company, floor, area, risk all reset/keep their previous values). Whenever any reporting scope is active on the dashboard, the card number and the list count **will differ** (F7, High). Also: the list's Reporting-Week filter (`obsWeek`) and the dashboard's `qWeek` are two unrelated states.

## 9 ▸ Root-cause summary

| # | Finding | Severity | Class |
|---|---|---|---|
| F1 | Closure donut slices (4×effStatus) ≠ its own legend (6×effAp); Rejected in no slice | Critical | different status logic + undercount |
| F2 | Evidence rule diverges: effStatus→IN_PROGRESS vs effAp→OPEN for no-After-photo records | Critical | different status logic |
| F3 | Two "Closed" definitions (S.closed vs S.apApproved) | High | different status logic |
| F7 | Card navigation drops all reporting scope → list ≠ card counts | High | dataset mismatch |
| F6 | Top Area/Floor/Contractor use cumulative `sel` while tiles use week-only `selCards` | Medium | dataset mismatch |
| F5 | Reporting tiles' Open includes Rejected | Medium | different status logic |
| F4 | Open card is Outstanding umbrella vs strict slices (per your spec) | Medium (by design) | perceived inconsistency |
| F8 | Weekly chart ignores selected week in cumulative mode (documented) | Low (by design) | perceived inconsistency |
| F9 | Overdue uses today, never the cut-off date (single consistent rule) | Low | date-filter scope |

Double-counting: none within the effAp bucket system; the only overlap is the **intentional** Outstanding umbrella (F4). The only *undercount* is F1's missing Rejected slice.

**Files/functions involved:** `index.html` only — `effStatus`, `effAp`, `apOf`, `hasAfterPhoto`, `isOD`, `dsObs`, `S` (counts), Closure-chart block (≈8052–8140), Reporting-Period section (`sel`/`selCards`/`wkSrc`/`tArea..`, ≈9053–9190), KPI card map + `k.nav` handler (≈7960–7990), list `filt` (≈6586).

## 10 ▸ Recommended fix plan (NOT implemented — awaiting approval)

1. **F1:** rebuild the donut slices from the same 6 effAp buckets as its legend (one array reused for both). Display-only; zero data risk.
2. **F2:** align the evidence rule — one shared decision (recommend: both resolvers → IN_PROGRESS, matching the visible "restart the workflow" narrative), applied in `effAp` to mirror `effStatus`. Display-only, but shifts counts; needs your sign-off on which side wins.
3. **F3:** define Closed := `effAp === "APPROVED CLOSED"` everywhere (retire `S.closed` from widgets). Display-only.
4. **F5:** add the `effAp ≠ REJECTED` exclusion to the reporting tiles' Open count. Display-only.
5. **F7:** pass the active reporting scope into the list navigation (set the list's week/date-range filters from `qWeek`/`qCutEff` on card click). Navigation-only; no workflow impact.
6. **F6:** switch Top lists to `selCards`, or label them "cumulative" — your choice of behavior.
7. **F8/F9:** captions/decision only — confirm intended behavior or specify changes.

Each step is independently committable/revertible and touches display/navigation logic only — no records, images, workflow, permissions, or exports. Risks: steps 2–3 will visibly change several counts (that is their purpose); recommend applying them together with a before/after screenshot comparison.

## 11 ▸ Read-only SQL to print the runtime datasets (Supabase SQL Editor)

```sql
-- Status × approvalStatus × has-After-photo distribution (drives F1–F3 sizes)
SELECT o->>'status' s, o->>'approvalStatus' a,
       (jsonb_array_length(coalesce(o->'pa','[]'::jsonb)) > 0) has_after, count(*)
FROM ctpa_state, jsonb_array_elements(data) o WHERE id='bkk22'
GROUP BY 1,2,3 ORDER BY 4 DESC;

-- W42 (2026-07-25..2026-07-31) week-only dataset: IDs, status, risk, type
SELECT o->>'id' id, o->>'status' s, o->>'approvalStatus' a, o->>'risk' r, o->>'obsType' t
FROM ctpa_state, jsonb_array_elements(data) o
WHERE id='bkk22' AND (o->>'date') BETWEEN '2026-07-25' AND '2026-07-31' ORDER BY 1;

-- Cumulative to 2026-07-30 dataset size + status counts
SELECT count(*) total,
  count(*) FILTER (WHERE o->>'status'='OPEN') open,
  count(*) FILTER (WHERE o->>'status'='CLOSED') closed,
  count(*) FILTER (WHERE o->>'approvalStatus'='REJECTED') rejected
FROM ctpa_state, jsonb_array_elements(data) o
WHERE id='bkk22' AND (o->>'date') <= '2026-07-30' AND (o->>'date') ~ '^\d{4}-\d{2}-\d{2}';

-- Overdue per the app rule (today = run date)
SELECT o->>'id' id, o->>'status' s, o->>'due' due, o->>'date' raised, o->>'closed' closed
FROM ctpa_state, jsonb_array_elements(data) o
WHERE id='bkk22' AND o->>'status' <> 'CLOSED'
  AND coalesce(o->>'due','') <> '' AND (o->>'due') < to_char(now() AT TIME ZONE 'Asia/Bangkok','YYYY-MM-DD')
ORDER BY o->>'due';
```
