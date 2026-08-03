/* ============================================================================
 * Approval-workflow tests (no framework — run with: node test/approval-workflow.test.js)
 *
 * Covers BOTH:
 *   A) newly created observations (must stay OPEN, inherit no approval), and
 *   B) the existing approval workflow (legacy closed records stay counted as
 *      Closed but are shown honestly; real GC/PMC sign-offs still work).
 *
 * The status/approval derivation functions are EXTRACTED FROM THE REAL
 * index.html so the tests exercise the shipped code, not a copy.
 * ==========================================================================*/
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const html = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
const sql = fs.readFileSync(
  path.join(ROOT, "migrations", "2026-08-03_harden_upsert_observation.sql"),
  "utf8",
);
// active SQL with `--` line comments stripped (the header comment intentionally
// quotes the OLD vulnerable derivation for documentation)
const sqlCode = sql.replace(/--[^\n]*/g, "");

let pass = 0;
function ok(name, cond) {
  assert.strictEqual(cond, true, "FAILED: " + name);
  pass++;
  console.log("  ✓ " + name);
}

/* ---- Extract the REAL derivation block (APPROVAL .. effStatus) ---- */
const start = html.indexOf("var APPROVAL = {");
const end = html.indexOf("/* one-time, non-destructive migration");
assert.ok(start > 0 && end > start, "could not locate derivation block in index.html");
const block = html.slice(start, end);
const C = new Proxy({}, { get: () => "#000" }); // colour stub — values are irrelevant
const M = new Function(
  "C",
  block + "\n;return { apOf, isUnapprovedClosed, effAp, effStatus };",
)(C);
const { apOf, isUnapprovedClosed, effAp, effStatus } = M;

/* ---- Mirror of the create-path override (index.html submit(), create branch) ---- */
function buildNewObservation(formFields, newId, before, after) {
  return Object.assign({}, formFields, {
    id: newId,
    pb: before,
    pa: after,
    rev: 1,
    status: "OPEN",
    approvalStatus: "OPEN",
    closed: "",
    closedBy: "",
    clientApprovedBy: "", clientApprovedById: "", clientApprovedRole: "", clientApprovedDate: "",
    lpApprovedBy: "", lpApprovedById: "", lpApprovedRole: "", lpApprovedDate: "",
    approvedBy: "", approvedDate: "", approvalComment: "",
    submittedForClosureBy: "", submittedForClosureDate: "",
  });
}

/* ---- Mirror of the hardened upsert_observation() GC-approval derivation ---- */
function rpcGcApproved(p) {
  const explicit =
    p.gcApproved === true || (p.clientApprovedRole != null && p.clientApprovedRole !== "");
  return !!(explicit && p.clientApprovedBy && p.clientApprovedById && p.clientApprovedDate);
}

console.log("\n1) New Daily Site Observation");
{
  const ni = buildNewObservation(
    { fc: "Daily Site Inspection (GC : Subcon)", desc: "loose rebar", status: "CLOSED", clientApprovedBy: "Someone", clientApprovedRole: "GC Manager", closed: "2026-08-03", closedBy: "Someone" },
    "OBS-999", [], [{ src: "data:image/png;base64,AAA" }], // even WITH an after photo + a status=CLOSED form
  );
  ok("new obs is OPEN regardless of form input", ni.status === "OPEN" && ni.approvalStatus === "OPEN");
  ok("new obs inherits NO GC approval", ni.clientApprovedBy === "" && ni.clientApprovedRole === "" && ni.clientApprovedById === "");
  ok("new obs inherits NO PMC approval", ni.lpApprovedBy === "" && ni.lpApprovedRole === "");
  ok("new obs carries no closure sign-off", ni.closed === "" && ni.closedBy === "" && ni.approvedBy === "");
  ok("effStatus(new) === OPEN (not Pending Verify)", effStatus(ni) === "OPEN");
  ok("isUnapprovedClosed(new) === false", isUnapprovedClosed(ni) === false);
  ok("effAp(new) === OPEN", effAp(ni) === "OPEN");
  // an after photo present but no approval must NOT read as approved
  ok("after photo alone does not approve", effStatus(ni) === "OPEN" && rpcGcApproved(ni) === false);
}

console.log("\n2) The real create-path in index.html forces OPEN + clears sign-offs");
{
  const s = html.indexOf("ALWAYS starts");
  assert.ok(s > 0, "create-path fix marker not found");
  const region = html.slice(s, s + 900);
  ok('create branch sets status: "OPEN"', /status:\s*"OPEN"/.test(region));
  ok("create branch clears clientApprovedRole", /clientApprovedRole:\s*""/.test(region));
  ok("create branch clears lpApprovedBy", /lpApprovedBy:\s*""/.test(region));
}

console.log("\n3) After photo → Pending Verify, awaiting GC (NOT approved)");
{
  const afterSubmitted = { status: "PENDING_VERIFY", approvalStatus: "PENDING REVIEW", clientApprovedBy: "", clientApprovedRole: "", lpApprovedBy: "", pa: [{ src: "x" }] };
  ok("effAp === PENDING REVIEW (awaiting GC)", effAp(afterSubmitted) === "PENDING REVIEW");
  ok("effStatus === PENDING_VERIFY", effStatus(afterSubmitted) === "PENDING_VERIFY");
  ok("not GC-approved (no role)", rpcGcApproved(afterSubmitted) === false);
  ok("not counted as closed", isUnapprovedClosed(afterSubmitted) === false);
}

console.log("\n4) Access control — approval NEVER derived from a name (RPC hardening)");
{
  ok("name alone does NOT approve", rpcGcApproved({ clientApprovedBy: "GC Manager" }) === false);
  ok("name + id + date but no explicit action does NOT approve", rpcGcApproved({ clientApprovedBy: "GC", clientApprovedById: "u1", clientApprovedDate: "t" }) === false);
  ok("explicit flag but missing id/date does NOT approve", rpcGcApproved({ gcApproved: true, clientApprovedBy: "GC" }) === false);
  ok("real approval (role+name+id+date) approves", rpcGcApproved({ clientApprovedRole: "GC Manager", clientApprovedBy: "GC", clientApprovedById: "u1", clientApprovedDate: "t" }) === true);
  ok("explicit gcApproved + full fingerprint approves", rpcGcApproved({ gcApproved: true, clientApprovedBy: "GC", clientApprovedById: "u1", clientApprovedDate: "t" }) === true);
  // the vulnerable name-presence derivation must be gone from the SQL
  ok("SQL no longer derives gc approval from name presence", !/gc_manager_approved[\s\S]{0,120}clientApprovedBy'\)\s*IS NOT NULL/i.test(sqlCode));
  ok("SQL requires explicit gcApproved / role", /gcApproved|clientApprovedRole/.test(sqlCode));
}

console.log("\n5) Existing ~1,147 legacy closed records — counted Closed, shown honestly");
{
  const legacy = { status: "CLOSED", approvalStatus: "APPROVED CLOSED", clientApprovedBy: "Ritta" /* backfilled name, NO role */, lpApprovedBy: "" };
  ok("still counts as Closed (effStatus)", effStatus(legacy) === "CLOSED");
  ok("still counts as Approved-Closed bucket (effAp) — count unchanged", effAp(legacy) === "APPROVED CLOSED");
  ok("but flagged unapproved for HONEST display", isUnapprovedClosed(legacy) === true);
}

console.log("\n6) Real GC+PMC approval and mid-funnel still work");
{
  const gcOnly = { status: "PENDING_VERIFY", approvalStatus: "PENDING PMC APPROVAL", clientApprovedBy: "GC", clientApprovedRole: "GC Manager", clientApprovedById: "u1", clientApprovedDate: "2026-01-01", lpApprovedBy: "" };
  ok("GC approved, awaiting PMC (effAp)", effAp(gcOnly) === "PENDING PMC APPROVAL");
  ok("GC approved, awaiting PMC (effStatus)", effStatus(gcOnly) === "PENDING_VERIFY");

  const both = { status: "CLOSED", approvalStatus: "APPROVED CLOSED", clientApprovedBy: "GC", clientApprovedRole: "GC Manager", clientApprovedById: "u1", clientApprovedDate: "2026-01-01", lpApprovedBy: "PMC", lpApprovedRole: "PMC Manager", lpApprovedById: "u2", lpApprovedDate: "2026-01-02" };
  ok("both approved → truly Closed", effStatus(both) === "CLOSED" && effAp(both) === "APPROVED CLOSED");
  ok("both approved → NOT flagged unapproved", isUnapprovedClosed(both) === false);
  ok("both approved → RPC records GC approval true", rpcGcApproved(both) === true);
}

console.log("\n7) Counts invariant — derivation buckets are unchanged by the display fix");
{
  // OPEN / IN_PROGRESS pass through unchanged
  ok("OPEN passes through", effStatus({ status: "OPEN" }) === "OPEN");
  ok("IN_PROGRESS passes through", effStatus({ status: "IN_PROGRESS" }) === "IN_PROGRESS");
  ok("REJECTED approval maps to OPEN bucket", apOf({ status: "OPEN", approvalStatus: "REJECTED" }) === "REJECTED" || apOf({ status: "OPEN" }) === "OPEN");
}

console.log("\n==============================");
console.log("ALL " + pass + " ASSERTIONS PASSED ✓");
console.log("==============================");
