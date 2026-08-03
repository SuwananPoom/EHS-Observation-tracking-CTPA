/* ============================================================================
 * Approval-workflow tests  (no framework — run: node test/approval-workflow.test.js)
 *
 * Exercises the REAL code by extracting functions from index.html:
 *   - status/approval derivation: apOf / effAp / effStatus / isUnapprovedClosed
 *   - access control:            userRole / canApproveGC / canApproveGCFor
 * Plus static checks on the create-path, the export builder, and the hardened
 * upsert_observation() SQL. Covers new observations AND the existing workflow.
 * ==========================================================================*/
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const html = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
const sql = fs.readFileSync(path.join(ROOT, "migrations", "2026-08-03_harden_upsert_observation.sql"), "utf8");
const sqlCode = sql.replace(/--[^\n]*/g, ""); // strip `--` comments (header quotes the OLD code)

let pass = 0;
function ok(name, cond) {
  assert.strictEqual(cond, true, "FAILED: " + name);
  pass++;
  console.log("  ✓ " + name);
}

/* ---- Extract the REAL derivation block (APPROVAL .. effStatus) ---- */
const start = html.indexOf("var APPROVAL = {");
const end = html.indexOf("/* one-time, non-destructive migration");
assert.ok(start > 0 && end > start, "could not locate derivation block");
const C = new Proxy({}, { get: () => "#000" });
const { apOf, isUnapprovedClosed, effAp, effStatus } = new Function(
  "C",
  html.slice(start, end) + "\n;return { apOf, isUnapprovedClosed, effAp, effStatus };",
)(C);

/* ---- Extract the REAL access-control functions (brace-matched) ---- */
function extractFn(src, name) {
  const i = src.indexOf("function " + name + "(");
  assert.ok(i >= 0, "fn not found: " + name);
  let depth = 0, started = false;
  for (let k = src.indexOf("{", i); k < src.length; k++) {
    if (src[k] === "{") { depth++; started = true; }
    else if (src[k] === "}") { depth--; if (started && depth === 0) return src.slice(i, k + 1); }
  }
  throw new Error("unbalanced: " + name);
}
const authSrc =
  extractFn(html, "_authProfile") + "\n" +
  extractFn(html, "userRole") + "\n" +
  extractFn(html, "canApproveGC") + "\n" +
  extractFn(html, "canApproveGCFor") + "\n" +
  "; return { setRole: function(r){ window.CTPA_AUTH = { profile: { role: r, company: (arguments[1]||'') } }; }, canApproveGC: canApproveGC, canApproveGCFor: canApproveGCFor };";
const win = {};
const AC = new Function("window", authSrc)(win);

/* ---- Mirror of the create-path override (index.html submit(), create branch) ---- */
function buildNewObservation(form, id, before, after) {
  return Object.assign({}, form, {
    id, pb: before, pa: after, rev: 1,
    status: "OPEN", approvalStatus: "OPEN", closed: "", closedBy: "",
    clientApprovedBy: "", clientApprovedById: "", clientApprovedRole: "", clientApprovedDate: "",
    lpApprovedBy: "", lpApprovedById: "", lpApprovedRole: "", lpApprovedDate: "",
    approvedBy: "", approvedDate: "", approvalComment: "",
    submittedForClosureBy: "", submittedForClosureDate: "",
  });
}
/* Mirror of the APPLIED upsert_observation() GC/PMC approval gate (role-based) */
const nz = (x) => x != null && x !== "";
const rpcGcApproved = (p) => !!(nz(p.clientApprovedRole) && nz(p.clientApprovedBy));
const rpcPmcApproved = (p) => !!(nz(p.lpApprovedRole) && nz(p.lpApprovedBy));

console.log("\n1) New Daily Site Observation → Open, no inherited approval");
{
  const ni = buildNewObservation(
    { fc: "Daily Site Inspection (GC : Subcon)", desc: "x", status: "CLOSED", clientApprovedBy: "Someone", clientApprovedRole: "GC Manager", closed: "2026-08-03" },
    "OBS-999", [], [{ src: "data:image/png;base64,AAA" }],
  );
  ok("new obs is OPEN regardless of form", ni.status === "OPEN" && ni.approvalStatus === "OPEN");
  ok("no inherited GC approval", ni.clientApprovedBy === "" && ni.clientApprovedRole === "" && ni.clientApprovedById === "");
  ok("no inherited PMC approval", ni.lpApprovedBy === "" && ni.lpApprovedRole === "");
  ok("no closure sign-off", ni.closed === "" && ni.closedBy === "" && ni.approvedBy === "");
  ok("effStatus(new)===OPEN (not Pending Verify)", effStatus(ni) === "OPEN");
  ok("effAp(new)===OPEN", effAp(ni) === "OPEN");
  ok("isUnapprovedClosed(new)===false", isUnapprovedClosed(ni) === false);
  ok("after photo present but NOT approved", rpcGcApproved(ni) === false);
}

console.log("\n2) Real create-path in index.html forces OPEN + clears sign-offs");
{
  const s = html.indexOf("ALWAYS starts");
  const region = html.slice(s, s + 900);
  ok('sets status: "OPEN"', /status:\s*"OPEN"/.test(region));
  ok("clears clientApprovedRole", /clientApprovedRole:\s*""/.test(region));
  ok("clears lpApprovedBy", /lpApprovedBy:\s*""/.test(region));
}

console.log("\n3) After photo → Pending Verify, awaiting GC (NOT approved)");
{
  const a = { status: "PENDING_VERIFY", approvalStatus: "PENDING REVIEW", clientApprovedBy: "", clientApprovedRole: "", lpApprovedBy: "", pa: [{ src: "x" }] };
  ok("effAp===PENDING REVIEW", effAp(a) === "PENDING REVIEW");
  ok("effStatus===PENDING_VERIFY", effStatus(a) === "PENDING_VERIFY");
  ok("not GC-approved", rpcGcApproved(a) === false);
  ok("not counted closed", isUnapprovedClosed(a) === false);
}

console.log("\n4) Approval NEVER derived from a name (RPC == workflow's role gate)");
{
  ok("name alone → not approved", rpcGcApproved({ clientApprovedBy: "GC Manager" }) === false);
  ok("name+id+date, NO role → not approved", rpcGcApproved({ clientApprovedBy: "GC", clientApprovedById: "u1", clientApprovedDate: "t" }) === false);
  ok("role without name → not approved", rpcGcApproved({ clientApprovedRole: "GC Manager" }) === false);
  ok("role + name → approved (real action)", rpcGcApproved({ clientApprovedRole: "GC Manager", clientApprovedBy: "GC", clientApprovedById: "u1", clientApprovedDate: "t" }) === true);
  ok("PMC role + name → approved", rpcPmcApproved({ lpApprovedRole: "PMC Manager", lpApprovedBy: "PMC" }) === true);
  ok("SQL no longer derives approval from name presence", !/clientApprovedBy'\)\s*IS NOT NULL/i.test(sqlCode));
  ok("SQL gate uses clientApprovedRole", /clientApprovedRole/.test(sqlCode));
  ok("SQL adds NO columns (no ALTER TABLE)", !/alter\s+table/i.test(sqlCode));
}

console.log("\n5) Role permissions — only GC Manager / Admin can GC-approve");
{
  const cannot = ["viewer", "dayone_user", "contractor", "observer", "safety_officer", "", "lm_user"];
  cannot.forEach((r) => { AC.setRole(r); ok('role "' + (r || "(none)") + '" cannot GC-approve', AC.canApproveGC() === false); });
  ["dayone_admin", "lm_gc", "ritta_gc"].forEach((r) => { AC.setRole(r); ok('role "' + r + '" CAN GC-approve', AC.canApproveGC() === true); });
  // contractor scope: a GC Manager may only approve their own company's obs
  AC.setRole("ritta_gc");
  ok("GC scope: ritta_gc can approve Ritta obs", AC.canApproveGCFor({ company: "Ritta Co" }) === true);
  ok("GC scope: ritta_gc cannot approve other company", AC.canApproveGCFor({ company: "LongMotive" }) === false);
  AC.setRole("dayone_admin");
  ok("Admin can approve any company", AC.canApproveGCFor({ company: "Anything" }) === true);
}

console.log("\n6) Existing ~1,147 legacy closed — counted Closed, shown honestly");
{
  const legacy = { status: "CLOSED", approvalStatus: "APPROVED CLOSED", clientApprovedBy: "Ritta", lpApprovedBy: "" };
  ok("counts as Closed (effStatus)", effStatus(legacy) === "CLOSED");
  ok("counts in Approved-Closed bucket (effAp) — unchanged", effAp(legacy) === "APPROVED CLOSED");
  ok("flagged unapproved for honest display", isUnapprovedClosed(legacy) === true);
  ok("export mirror blanks its approver (no role)", rpcGcApproved(legacy) === false);
}

console.log("\n7) Real GC+PMC approval and mid-funnel still work");
{
  const gcOnly = { status: "PENDING_VERIFY", approvalStatus: "PENDING PMC APPROVAL", clientApprovedBy: "GC", clientApprovedRole: "GC Manager", clientApprovedById: "u1", clientApprovedDate: "2026-01-01", lpApprovedBy: "" };
  ok("GC approved, awaiting PMC (effAp)", effAp(gcOnly) === "PENDING PMC APPROVAL");
  ok("GC approved, awaiting PMC (effStatus)", effStatus(gcOnly) === "PENDING_VERIFY");
  const both = { status: "CLOSED", approvalStatus: "APPROVED CLOSED", clientApprovedBy: "GC", clientApprovedRole: "GC Manager", clientApprovedById: "u1", clientApprovedDate: "2026-01-01", lpApprovedBy: "PMC", lpApprovedRole: "PMC Manager", lpApprovedById: "u2", lpApprovedDate: "2026-01-02" };
  ok("both approved → Closed", effStatus(both) === "CLOSED" && effAp(both) === "APPROVED CLOSED");
  ok("both approved → not flagged unapproved", isUnapprovedClosed(both) === false);
  ok("both approved → RPC records approval", rpcGcApproved(both) === true && rpcPmcApproved(both) === true);
}

console.log("\n8) Counts invariant + export blanking (static)");
{
  ok("OPEN passes through", effStatus({ status: "OPEN" }) === "OPEN");
  ok("IN_PROGRESS passes through", effStatus({ status: "IN_PROGRESS" }) === "IN_PROGRESS");
  // export builder must gate approver columns on the real role
  ok("export blanks GC approver unless role", /clientApprovedRole\s*\?\s*fmtApprover\(o\.clientApprovedBy\)\s*:\s*""/.test(html));
  ok("export blanks PMC approver unless role", /lpApprovedRole\s*\?\s*fmtApprover\(o\.lpApprovedBy\)\s*:\s*""/.test(html));
}

console.log("\n==============================");
console.log("ALL " + pass + " ASSERTIONS PASSED ✓");
console.log("==============================");
