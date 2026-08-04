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
const guardSql = fs.readFileSync(path.join(ROOT, "migrations", "2026-08-04_ctpa_state_close_guard.sql"), "utf8");
const guardCode = guardSql.replace(/--[^\n]*/g, ""); // strip `--` comments before pattern checks

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
  extractFn(html, "canApprovePMC") + "\n" +
  extractFn(html, "isAdmin") + "\n" +
  extractFn(html, "canCloseObs") + "\n" +
  "; return { setRole: function(r){ window.CTPA_AUTH = { profile: { role: r, company: (arguments[1]||'') } }; }," +
  "  canApproveGC: canApproveGC, canApproveGCFor: canApproveGCFor," +
  "  canApprovePMC: canApprovePMC, isAdmin: isAdmin, canCloseObs: canCloseObs };";
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
  const legacy = { status: "CLOSED", approvalStatus: "APPROVED CLOSED", clientApprovedBy: "Ritta", lpApprovedBy: "", pa: [{ _hasPhoto: true }] };
  ok("counts as Closed (effStatus)", effStatus(legacy) === "CLOSED");
  ok("counts in Approved-Closed bucket (effAp) — unchanged", effAp(legacy) === "APPROVED CLOSED");
  ok("flagged unapproved for honest display", isUnapprovedClosed(legacy) === true);
  ok("export mirror blanks its approver (no role)", rpcGcApproved(legacy) === false);
}

console.log("\n7) Real GC+PMC approval and mid-funnel still work");
{
  const gcOnly = { status: "PENDING_VERIFY", approvalStatus: "PENDING PMC APPROVAL", clientApprovedBy: "GC", clientApprovedRole: "GC Manager", clientApprovedById: "u1", clientApprovedDate: "2026-01-01", lpApprovedBy: "", pa: [{ _hasPhoto: true }] };
  ok("GC approved, awaiting PMC (effAp)", effAp(gcOnly) === "PENDING PMC APPROVAL");
  ok("GC approved, awaiting PMC (effStatus)", effStatus(gcOnly) === "PENDING_VERIFY");
  const both = { status: "CLOSED", approvalStatus: "APPROVED CLOSED", clientApprovedBy: "GC", clientApprovedRole: "GC Manager", clientApprovedById: "u1", clientApprovedDate: "2026-01-01", lpApprovedBy: "PMC", lpApprovedRole: "PMC Manager", lpApprovedById: "u2", lpApprovedDate: "2026-01-02", pa: [{ _hasPhoto: true }] };
  ok("both approved → Closed", effStatus(both) === "CLOSED" && effAp(both) === "APPROVED CLOSED");
  ok("both approved → not flagged unapproved", isUnapprovedClosed(both) === false);
  ok("both approved → RPC records approval", rpcGcApproved(both) === true && rpcPmcApproved(both) === true);
}

console.log("\n9) EVIDENCE RULE — no After photo → cannot be/stay closed (UAT OBS-1036)");
{
  // exact shape pulled from production on 2026-08-04 (photo deleted during UAT)
  const obs1036 = {
    id: "OBS-1036", date: "2026-07-24", status: "OPEN", approvalStatus: "APPROVED CLOSED",
    closed: "2026-08-02", closedBy: "", pa: [], pb: [{ _hasPhoto: true }],
    approvedBy: "GC Manager + PMC Manager", approvedDate: "2026-08-02 02:59",
    clientApprovedBy: "Suwanan Poomchaveng ", clientApprovedById: "c2fc18b6", clientApprovedRole: "Admin", clientApprovedDate: "2026-08-02 02:59",
    lpApprovedBy: "Suwanan Poomchaveng ", lpApprovedById: "c2fc18b6", lpApprovedRole: "Admin", lpApprovedDate: "2026-08-02 02:59",
  };
  ok("OBS-1036 no longer resolves Approved Closed", effAp(obs1036) === "OPEN");
  ok("OBS-1036 shows as IN_PROGRESS", effStatus(obs1036) === "IN_PROGRESS");

  const legacyNoPhoto = { id: "OBS-768", status: "CLOSED", pa: [], clientApprovedBy: "Someone" };
  ok("legacy closed WITHOUT photo → IN_PROGRESS", effStatus(legacyNoPhoto) === "IN_PROGRESS");
  ok("legacy closed WITHOUT photo → effAp OPEN (restart workflow)", effAp(legacyNoPhoto) === "OPEN");

  const legacyWithPhoto = { status: "CLOSED", pa: [{ _hasPhoto: true }], clientApprovedBy: "Someone" };
  ok("legacy closed WITH photo → still CLOSED (counts unchanged)", effStatus(legacyWithPhoto) === "CLOSED");
  ok("legacy closed WITH photo → still APPROVED CLOSED bucket", effAp(legacyWithPhoto) === "APPROVED CLOSED");

  const realClosedWithPhoto = { status: "CLOSED", pa: [{}], clientApprovedBy: "GC", clientApprovedRole: "GC Manager", lpApprovedBy: "PMC", lpApprovedRole: "PMC Manager" };
  ok("properly approved closed WITH photo → unchanged", effStatus(realClosedWithPhoto) === "CLOSED" && effAp(realClosedWithPhoto) === "APPROVED CLOSED");

  const pendingNoPhoto = { status: "PENDING_VERIFY", approvalStatus: "PENDING REVIEW", pa: [] };
  ok("pending WITHOUT photo → IN_PROGRESS / OPEN", effStatus(pendingNoPhoto) === "IN_PROGRESS" && effAp(pendingNoPhoto) === "OPEN");
  const pendingWithPhoto = { status: "PENDING_VERIFY", approvalStatus: "PENDING REVIEW", pa: [{}] };
  ok("pending WITH photo → unchanged", effStatus(pendingWithPhoto) === "PENDING_VERIFY" && effAp(pendingWithPhoto) === "PENDING REVIEW");

  // the fix's supporting code exists in the shipped file
  ok("delete-handler confirmation message present", html.includes("Deleting the last After photo will cancel the existing approvals and reopen this observation. Do you want to continue?"));
  ok("delete-handler resets to IN_PROGRESS", /APPROVAL_RESET/.test(html) && /reset to IN_PROGRESS/.test(html));
  ok("RPC blocks Closed with zero After photos", /zero After photos/.test(sqlCode) && /jsonb_array_length\(coalesce\(payload->'pa'/.test(sqlCode));
}

console.log("\n8) Counts invariant + export blanking (static)");
{
  ok("OPEN passes through", effStatus({ status: "OPEN" }) === "OPEN");
  ok("IN_PROGRESS passes through", effStatus({ status: "IN_PROGRESS" }) === "IN_PROGRESS");
  // export builder must gate approver columns on the real role
  ok("export blanks GC approver unless role", /clientApprovedRole\s*\?\s*fmtApprover\(o\.clientApprovedBy\)\s*:\s*""/.test(html));
  ok("export blanks PMC approver unless role", /lpApprovedRole\s*\?\s*fmtApprover\(o\.lpApprovedBy\)\s*:\s*""/.test(html));
}

console.log("\n10) GC USER permissions — Close / Approve lockdown (OBS-1191)");
{
  /* Roles that must NEVER be able to close (GC USERs + other non-manager roles).
     Approved Closed is reachable ONLY through the GC + PMC approval workflow. */
  const noClose = ["lm_user", "ritta_user", "dayone_user", "ms_user", "pmc_user", "viewer", ""];
  noClose.forEach((r) => { AC.setRole(r); ok('role "' + (r || "(none)") + '" cannot close (canCloseObs=false)', AC.canCloseObs() === false); });
  ["dayone_admin", "lm_gc", "ritta_gc", "pmc_manager"].forEach((r) => { AC.setRole(r); ok('role "' + r + '" CAN close (canCloseObs=true)', AC.canCloseObs() === true); });

  /* PMC approval gated to PMC Manager / Admin only (GC USERs & GC Managers cannot). */
  ["lm_user", "ritta_user", "dayone_user", "ms_user", "pmc_user", "viewer", "lm_gc", "ritta_gc"]
    .forEach((r) => { AC.setRole(r); ok('role "' + r + '" cannot PMC-approve', AC.canApprovePMC() === false); });
  ["pmc_manager", "dayone_admin"].forEach((r) => { AC.setRole(r); ok('role "' + r + '" CAN PMC-approve', AC.canApprovePMC() === true); });

  /* ---- Static checks: enforcement code is present in the shipped file ---- */
  ok("Edit form hides CLOSED unless already closed", /if \(k === "CLOSED" && form\.status !== "CLOSED"\) return null;/.test(html));
  ok("status select locked when already closed", /disabled:\s*form\.status === "CLOSED"/.test(html));
  ok("Closed Date & Closed By gated on canCloseObs", (html.match(/disabled:\s*!canCloseObs\(\)/g) || []).length >= 2);
  ok("submit() blocks a NEW close transition via the form", /form\.status === "CLOSED" && !_wasClosed/.test(html));
  ok("stCh blocks close for non-closers", /if \(ns === "CLOSED" && !canCloseObs\(\)\)/.test(html));
  ok("approveClosure PMC branch re-checks canApprovePMC", /if\(!canApprovePMC\(\)\)\{ toast\$\("Not authorized/.test(html));
  ok("PMC gate message names PMC Manager or Admin", /PMC Manager approval requires a PMC Manager or Admin account/.test(html));
  ok("edit-save auto-promote requires real sign-offs", /\(\(_sgGC && _sgPMC\) \|\| _sgLegacy\)/.test(html));
  ok("legacy PMC approver code neutralized", /code === PMC_CODE\)\{ toast\$\("PMC Manager approval requires/.test(html));

  /* ---- Behavioural: a form-close with NO sign-offs must NOT become Approved Closed ---- */
  function editAutoPromote(merged) {
    var _sgGC = !!(merged.clientApprovedBy && merged.clientApprovedRole);
    var _sgPMC = !!(merged.lpApprovedBy && merged.lpApprovedRole);
    var _sgLegacy = !!(merged.clientApprovedBy && !merged.clientApprovedRole);
    if (merged.status === "CLOSED" && (!merged.approvalStatus || merged.approvalStatus === "OPEN")
        && ((_sgGC && _sgPMC) || _sgLegacy)) merged.approvalStatus = "APPROVED CLOSED";
    return merged;
  }
  const forced = editAutoPromote({ status: "CLOSED", approvalStatus: "OPEN", clientApprovedBy: "", lpApprovedBy: "", pa: [{}] });
  ok("form-close w/o sign-offs is NOT stored Approved Closed", forced.approvalStatus === "OPEN");
  ok("form-close w/o sign-offs → effAp resolves to PENDING REVIEW", effAp(forced) === "PENDING REVIEW");
  ok("form-close w/o sign-offs → effStatus resolves to PENDING_VERIFY", effStatus(forced) === "PENDING_VERIFY");
  const realPmc = editAutoPromote({ status: "CLOSED", approvalStatus: "OPEN", clientApprovedBy: "GC", clientApprovedRole: "GC Manager", lpApprovedBy: "PMC", lpApprovedRole: "PMC Manager", pa: [{}] });
  ok("real GC+PMC close → stored Approved Closed (workflow unaffected)", realPmc.approvalStatus === "APPROVED CLOSED");

  /* ---- Server/DB tier: the ctpa_state close-guard trigger migration ---- */
  ok("guard migration is BEFORE UPDATE trigger on ctpa_state",
     /before update on public\.ctpa_state/.test(guardCode) && /create trigger ctpa_state_close_guard_trg/.test(guardCode));
  ok("guard requires BOTH GC and PMC sign-off roles to allow a close",
     /clientApprovedRole/.test(guardCode) && /lpApprovedRole/.test(guardCode)
     && /clientApprovedBy/.test(guardCode) && /lpApprovedBy/.test(guardCode));
  ok("guard is transition-based (grandfathers existing closed via old_closed)",
     /old_closed \? \(e->>'id'\)/.test(guardCode) && /old_ids \? \(e->>'id'\)/.test(guardCode));
  ok("guard closed-ish tests are NULL-safe (coalesce)",
     (guardCode.match(/coalesce\(e->>'status',''\)\s*=\s*'CLOSED'/g) || []).length >= 1
     && (guardCode.match(/coalesce\(e->>'approvalStatus',''\)\s*=\s*'APPROVED CLOSED'/g) || []).length >= 1);
  ok("guard allows brand-new ids (Excel import path)", /not \(old_ids \? \(e->>'id'\)\)/.test(guardCode));
  ok("guard raises check_violation on unauthorized close transition",
     /raise\s+exception/i.test(guardCode) && /check_violation/.test(guardCode));
  ok("guard performs NO schema change (no ALTER TABLE / ADD COLUMN)",
     !/alter\s+table/i.test(guardCode) && !/add\s+column/i.test(guardCode));
  ok("guard ships an explicit non-destructive ROLLBACK", /drop trigger if exists ctpa_state_close_guard_trg/.test(guardSql));
}

console.log("\n==============================");
console.log("ALL " + pass + " ASSERTIONS PASSED ✓");
console.log("==============================");
