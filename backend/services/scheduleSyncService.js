const crypto = require('node:crypto');
const Device = require('../models/Device');
const Schedule = require('../models/Schedule');
const { compile, MAX_TIMERS, MAX_RULE_LENGTH } = require('./scheduleCompiler');
const tasmotaConfigClient = require('./tasmotaConfigClient');

const SYNC_FLAG = 'TASMOTA_SCHEDULE_SYNC_ENABLED';
const MAX_SYNC_ATTEMPTS = 3;
const DEFAULT_TIMEOUT_MS = 5000;

// Tasmota factory timer state (as observed live in Phase 5): what an orphaned
// managed slot is reset to when a shrinking plan no longer uses it. Output
// stays 1 (never 0) so real firmware readback matches byte-for-byte and
// verification cannot fail on firmware Output normalization.
const FACTORY_DEFAULT_TIMER = Object.freeze({
  Enable: 0,
  Mode: 0,
  Time: '00:00',
  Window: 0,
  Days: '0000000',
  Repeat: 0,
  Output: 1,
  Action: 0,
});

// Ownership contract (explicit, stable across syncs):
//  - Timer3 is the user Rule1 trigger on the real device - NEVER managed.
//  - Rule1 and Rule3 are user rules - NEVER written.
//  - Rule2 is reserved for STEES ONLY - written only when a compiled plan has
//    multi-channel events, and only if currently empty (never overwriting user
//    config; if occupied -> conflict).
const USER_TRIGGER_TIMER = 3;
const USER_RULE_INDEXES = [1, 3];
const STEES_RULE_INDEX = 2;

function syncEnabled() {
  return String(process.env[SYNC_FLAG] || 'false').toLowerCase() === 'true';
}

function toNum(v) {
  if (v === undefined || v === null) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function normDays(v) {
  return typeof v === 'string' && /^[01]{7}$/.test(v) ? v : '0000000';
}

function normTime(v) {
  return typeof v === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(v) ? v : '00:00';
}

// Normalize one Timer<n> response into a stable comparable shape. Tolerates
// missing/firmware-varying fields by falling back to safe defaults, so the
// diff only fires on real behavioral changes.
function normalizeTimer(t) {
  t = t || {};
  return {
    Enable: toNum(t.Enable) === 1 ? 1 : 0,
    Mode: toNum(t.Mode) === 1 ? 1 : 0,
    Time: normTime(t.Time),
    Window: toNum(t.Window) || 0,
    Days: normDays(t.Days),
    Repeat: toNum(t.Repeat) || 0,
    Output: toNum(t.Output) || 0,
    Action: toNum(t.Action) || 0,
  };
}

// Normalize a Rule<n> response. The firmware may reply either with the full
// object ({State,Once,StopOnError,Length,Free,Rules}) or, after a write, with
// just the raw rules text; both are tolerated.
function normalizeRule(index, r) {
  if (typeof r === 'string') {
    const text = String(r);
    return { index, State: 'ON', Once: 'OFF', StopOnError: 'OFF', Length: text.length, Free: MAX_RULE_LENGTH - text.length, Rules: text };
  }
  r = r || {};
  return {
    index,
    State: String(r.State || 'OFF'),
    Once: String(r.Once || 'OFF'),
    StopOnError: String(r.StopOnError || 'OFF'),
    Length: toNum(r.Length) || 0,
    Free: toNum(r.Free) || MAX_RULE_LENGTH,
    Rules: String(r.Rules || ''),
  };
}

// A slot is considered "default/empty" if it matches Tasmota's factory state.
function isDefaultTimer(t) {
  return (
    t.Enable === 0 &&
    t.Mode === 0 &&
    t.Time === '00:00' &&
    t.Window === 0 &&
    t.Days === '0000000' &&
    t.Repeat === 0 &&
    t.Action === 0
  );
}

function timerPayload(t) {
  // Verbatim: no falsy-coercion. The historical `Enable: t.Enable || 1` /
  // `Repeat: t.Repeat || 1` made it STRUCTURALLY IMPOSSIBLE to publish a
  // disarming clear (Enable:0/Repeat:0 silently became 1/1 on the wire).
  // Every caller passes a complete normalizeTimer()-shaped config.
  return JSON.stringify({
    Enable: t.Enable,
    Mode: t.Mode,
    Time: t.Time,
    Window: t.Window,
    Days: t.Days,
    Repeat: t.Repeat,
    Output: t.Output,
    Action: t.Action,
  });
}

// Read timers and rules individually (never the bulk `Timers` response). By
// default reads all 16 timers and 3 rules (the full state snapshot used for the
// initial read and diffing). Pass explicit `timerIndexes`/`ruleIndexes` to read
// only a subset - the verification phase uses exactly the slots that were
// written, so unchanged slots are never re-fetched. Reads are best-effort: a
// missing timer/rule response normalizes to its default so the sync can still
// proceed with what it could verify.
async function readDeviceScheduleState(deviceId, { traceId, timerIndexes, ruleIndexes } = {}) {
  const readTimers = timerIndexes === undefined ? Array.from({ length: 16 }, (_, i) => i + 1) : timerIndexes;
  const readRules = ruleIndexes === undefined ? [1, 2, 3] : ruleIndexes;

  const requests = [];
  for (const index of readTimers) {
    requests.push({
      kind: 'timer',
      index,
      pending: tasmotaConfigClient.requestTasmotaConfig(deviceId, `Timer${index}`, '', { timeoutMs: DEFAULT_TIMEOUT_MS, expectedResponseKey: `Timer${index}`, traceId }),
    });
  }
  for (const index of readRules) {
    requests.push({
      kind: 'rule',
      index,
      pending: tasmotaConfigClient.requestTasmotaConfig(deviceId, `Rule${index}`, '', { timeoutMs: DEFAULT_TIMEOUT_MS, expectedResponseKey: `Rule${index}`, traceId }),
    });
  }

  const responses = await Promise.all(requests.map((r) => r.pending));

  const timers = [];
  const rules = [];
  requests.forEach((r, i) => {
    const payload = responses[i];
    if (r.kind === 'timer') {
      timers.push({ index: r.index, ...normalizeTimer(payload && payload[`Timer${r.index}`]) });
    } else {
      rules.push(normalizeRule(r.index, payload && payload[`Rule${r.index}`]));
    }
  });
  return { timers, rules };
}

// Rewrite the compiler's rule clauses substituting physical slot numbers for
// the compiler's logical indices, then re-check the 511-char budget.
// Compiler rule text references Clock#Timer=<logical>; STEES must remap to the
// physical slot the timer actually landed in.
function buildRuleText(planTimers, allocation) {
  const clauses = [];
  for (const timer of planTimers) {
    const slot = allocation.get(timer.index);
    if (!slot) return null;
    const isDirect = timer.event.on.length + timer.event.off.length === 1;
    if (isDirect) continue;
    const commands = [];
    for (const c of timer.event.on) commands.push(`Power${c} ON`);
    for (const c of timer.event.off) commands.push(`Power${c} OFF`);
    const body = commands.length === 1 ? commands[0] : `Backlog ${commands.join('; ')}`;
    clauses.push(`ON Clock#Timer=${slot} DO ${body} ENDON`);
  }
  if (!clauses.length) return '';
  const text = clauses.join(' ');
  return text.length <= MAX_RULE_LENGTH ? text : null;
}

// Recognize Rule2 content authored by ANY STEES compiler revision. Ownership is
// established by PATTERN, never byte-equality against the current plan (the
// historical byte-exact check misclassified legitimately-edited STEES rules as
// "user configuration" whenever channel sets, event counts, or clause spacing
// drifted - e.g. legacy join(';') vs current join('; ') bodies). Recognition
// requires BOTH:
//   1. Grammar: every clause matches `ON Clock#Timer=<n> DO <body> ENDON`,
//      where <body> is `Backlog Power<d> ON|OFF` commands joined by ';' with
//      any spacing (or a single bare `Power<d> ON|OFF`).
//   2. Slot ownership: every referenced Clock#Timer=<n> slot is either a slot
//      STEES previously managed, a factory-default free slot, OR an occupied
//      slot whose timer carries the compiler signature (Action === 3 - STEES
//      emits Action 3 ONLY for multi-channel rule events; direct events are
//      0/1). The Action-3 acceptance is what un-deadlocks ownership resets
//      (unclaim/reclaim wipes scheduleSyncInfo while the device keeps its
//      STEES timers): without it the rule was misclassified as foreign forever
//      and every sync latched 'unsupported'. Timer3 (user trigger) stays
//      absolutely excluded, and plain user timers (Action 0/1) stay rejected.
// Mixed content (our clause + foreign tail like `ON Sys#Boot DO ...`) fails the
// full-consumption check and stays protected.
function isSteesOwnedRule2(rule2, actual, managedTimerIndexes = []) {
  if (!rule2 || typeof rule2.Rules !== 'string' || rule2.Rules.trim() === '') return false;
  const managed = new Set(managedTimerIndexes);
  const timersByIndex = new Map(
    ((actual && actual.timers) || []).map((t) => [t.index, t]),
  );
  const slotAcceptable = (slot) => {
    if (slot === USER_TRIGGER_TIMER) return false; // user trigger: never ours
    if (managed.has(slot)) return true;
    const t = timersByIndex.get(slot);
    if (!t) return false; // unknown slot: cannot prove ownership
    if (isDefaultTimer(t)) return true; // factory-default free slot
    // Occupied: only the compiler signature makes it ours. Direct-action
    // timers (Action 0/1) are indistinguishable from user automations ->
    // rejected.
    return toNum(t.Action) === 3 && toNum(t.Enable) === 1;
  };
  const text = rule2.Rules;
  const clauseRe = /ON\s+Clock#Timer=(\d+)\s+DO\s+(.+?)\s+ENDON/gi;
  let consumed = 0;
  let m;
  while ((m = clauseRe.exec(text)) !== null) {
    consumed += m[0].length;
    if (!slotAcceptable(Number(m[1]))) return false;
    const parts = m[2].split(';').map((s) => s.trim()).filter(Boolean);
    if (/^backlog\b/i.test(parts[0])) {
      parts[0] = parts[0].replace(/^backlog\s+/i, '');
    } else if (parts.length > 1) {
      // Multiple commands without a Backlog wrapper is not compiler output.
      return false;
    }
    for (const p of parts) {
      if (!/^Power\d+\s+(?:ON|OFF)$/i.test(p)) return false;
    }
  }
  if (consumed === 0) return false;
  const remainder = text.replace(new RegExp(clauseRe.source, 'gi'), '');
  return remainder.trim() === '';
}

// Decide the physical allocation for a compiled plan (logical index 1..N ->
// physical slot 1..16). Ownership: skip the user trigger timer and every
// occupied non-default slot. A slot previously recorded as STEES-managed is
// still owned even when non-default (so re-syncs reuse the same slots instead
// of churning). If the plan cannot fit, the result is NOT okay and nothing is
// ever overwritten.
function allocateSlots(plan, actual, managedTimerIndexes = []) {
  const managed = new Set(managedTimerIndexes);
  const ownedSlots = [];
  for (const timer of actual.timers) {
    if (timer.index === USER_TRIGGER_TIMER) continue;
    if (isDefaultTimer(timer) || managed.has(timer.index)) ownedSlots.push(timer.index);
  }

  const conflicts = [];
  const unsupportedReasons = plan.unsupportedReasons.slice();

  if (plan.requiredTimerCount > ownedSlots.length) {
    conflicts.push(
      `Desired plan needs ${plan.requiredTimerCount} timer slot(s) but only ${ownedSlots.length} safe managed slot(s) are free (user Timer3 and occupied timers are protected)`,
    );
    unsupportedReasons.push('Not enough safe managed timer slots for this plan');
  }
  if (unsupportedReasons.length) return { okay: false, allocation: new Map(), conflicts, unsupportedReasons };

  const allocation = new Map();
  const used = new Set([USER_TRIGGER_TIMER]);
  for (const timer of plan.timers) {
    const slot = ownedSlots.find((s) => !used.has(s));
    allocation.set(timer.index, slot);
    used.add(slot);
  }
  return { okay: true, allocation, managed: Array.from(used).filter((i) => i !== USER_TRIGGER_TIMER), conflicts, unsupportedReasons };
}

// Compute the exact set of writes needed to bring the device to the compiled
// plan. Pure: takes an `actual` state and the previously-managed timer indexes
// so the flag-off preview path and the apply path share identical diffing.
function computeWrites(plan, actual, managedTimerIndexes = []) {
  const result = allocateSlots(plan, actual, managedTimerIndexes);
  if (!result.okay) return result;

  const writes = [];
  const touched = [];

  for (const timer of plan.timers) {
    const slot = result.allocation.get(timer.index);
    if (slot === undefined) continue;
    const desired = normalizeTimer({ ...timer.config, Time: timer.config.Time });
    const current = actual.timers.find((t) => t.index === slot);
    const same =
      desired.Enable === current.Enable &&
      desired.Mode === current.Mode &&
      desired.Time === current.Time &&
      desired.Window === current.Window &&
      desired.Days === current.Days &&
      desired.Repeat === current.Repeat &&
      desired.Output === current.Output &&
      desired.Action === current.Action;
    if (!same) writes.push({ kind: 'timer', index: slot, desired });
    touched.push(slot);
  }

  // Orphan cleanup (plan-shrink / schedule deletion): a slot previously managed
  // by an earlier plan that the current plan no longer uses would otherwise
  // stay ARMED on the device forever - firing its stale Clock#Timer event with
  // no Rule2 clause to catch it, permanently leaked (never factory-default,
  // never reusable). Reset every such orphan to FACTORY_DEFAULT_TIMER. These
  // writes flow through the normal apply + readback-verify loop below, so a
  // clear is CONFIRMED on the device, never assumed. Slots already default are
  // skipped (idempotent). result.managed comes from allocateSlots and already
  // excludes orphans, so the post-sync persistence drops them automatically.
  const allocationSlots = new Set(result.allocation.values());
  const seenOrphans = new Set();
  for (const slot of managedTimerIndexes) {
    if (slot === USER_TRIGGER_TIMER || allocationSlots.has(slot) || seenOrphans.has(slot)) continue;
    seenOrphans.add(slot);
    const current = actual.timers.find((t) => t.index === slot);
    if (!current || isDefaultTimer(current)) {
      touched.push(slot); // nothing to publish; ownership drop only
      continue;
    }
    writes.push({ kind: 'timer', index: slot, desired: { ...FACTORY_DEFAULT_TIMER } });
    touched.push(slot);
  }

  const ruleText = buildRuleText(plan.timers, result.allocation);
  if (ruleText === null) {
    result.okay = false;
    result.conflicts.push(`Multi-channel rule exceeds ${MAX_RULE_LENGTH} chars after slot remapping`);
    result.unsupportedReasons.push('Rule1 would exceed the 511-char Tasmota limit after slot remapping');
    return result;
  }

  const wantsRule2 = plan.rules.length > 0;
  if (wantsRule2) {
    const rule2 = actual.rules.find((r) => r.index === STEES_RULE_INDEX);
    // A rule with State OFF is STORED but DISABLED — it never executes. So a
    // write is required whenever the text differs OR the rule is not active,
    // even when the stored text already matches (activation-only pass).
    // Occupancy conflicts apply ONLY to foreign content: a Rule2 that matches
    // the STEES ownership pattern (any compiler revision) is ours and is
    // safely rewritten below, even when its stored text differs from the new
    // plan (legitimate edits must never dead-lock into "Rule2 is not free").
    const occupied = rule2 && rule2.State !== 'OFF' && rule2.Rules !== '';
    if (occupied && !isSteesOwnedRule2(rule2, actual, managedTimerIndexes)) {
      result.okay = false;
      result.conflicts.push('Rule2 is occupied by user configuration and cannot be overwritten');
      result.unsupportedReasons.push('Rule2 is not free');
      return result;
    }
    const needsActivation = !rule2 || String(rule2.State).toUpperCase() !== 'ON';
    if (!occupied || rule2.Rules !== ruleText || needsActivation) {
      writes.push({ kind: 'rule', index: STEES_RULE_INDEX, text: ruleText });
    }
    touched.push('rule2');
  }

  result.writes = writes;
  result.touched = touched;
  return result;
}

// Report the protected / unmanaged resources on the device: the user's rule
// trigger timer, every occupied non-managed timer, the user rules, and Rule2
// when it holds user config. These are the resources sync must never touch.
function protectedResources(actual, managedTimerIndexes = []) {
  const managed = new Set(managedTimerIndexes);
  const timers = [];
  const rules = [];

  for (const timer of actual.timers || []) {
    if (timer.index === USER_TRIGGER_TIMER) {
      timers.push({ index: timer.index, reason: 'user Rule1 trigger' });
    } else if (!isDefaultTimer(timer) && !managed.has(timer.index)) {
      timers.push({ index: timer.index, reason: 'occupied (unmanaged)' });
    }
  }
  for (const index of USER_RULE_INDEXES) {
    rules.push({ index, reason: 'user rule' });
  }
  const rule2 = (actual.rules || []).find((r) => r.index === STEES_RULE_INDEX);
  if (
    rule2 &&
    rule2.State !== 'OFF' &&
    rule2.Rules !== '' &&
    !isSteesOwnedRule2(rule2, actual, managedTimerIndexes)
  ) {
    rules.push({ index: STEES_RULE_INDEX, reason: 'occupied by user config' });
  }
  return { timers, rules };
}

// Report the compiled plan as a JSON-safe view (logical timer index, its config
// and event, and the rule clauses).
function planView(plan) {
  return {
    requiredTimerCount: plan.requiredTimerCount,
    timers: (plan.timers || []).map((t) => ({
      index: t.index,
      config: { ...t.config },
      event: { on: (t.event && t.event.on) || [], off: (t.event && t.event.off) || [] },
      sources: (t.sources || []).slice(),
    })),
    rules: (plan.rules || []).map((r) => ({ ruleIndex: r.ruleIndex, length: r.length, text: r.text })),
  };
}

// Report the logical -> physical allocation as a JSON-safe list.
function allocationView(allocation) {
  const out = [];
  for (const [logical, physical] of allocation) out.push({ logical, physical });
  out.sort((a, b) => a.logical - b.logical);
  return out;
}

// Per-device serialization gate. Overlapping full syncs for the SAME device must
// never interleave - an interleaved run reads the device's Timer/Rule config in
// the middle of another run's writes, computes a stale-vs-desired diff against
// that half-applied state, and re-issues the same writes (the Timer1-16 +
// Rule1-3 echo observed on the console). EVERY caller funnels through this one
// point:
//   - the CRUD trigger's default syncFn (scheduleSyncTrigger -> this.syncDevice)
//   - manualSync() / the devSync route, which otherwise bypass the trigger.
// A call for a device waits until every earlier call for that device has fully
// completed (apply + readback verification), then runs fresh so it re-reads the
// latest DB + device state. Different devices run fully in parallel (per-device
// gates, never a global lock).
const deviceSyncGates = new Map();

// Diagnostic trace channel (observability only - no behavior change). Every
// top-level syncDevice invocation gets a fresh traceId; it is logged at every
// phase boundary so a Tasmota console capture can be correlated to exactly one
// invocation and to each internal retry/readback cycle.
function syncLogger(options) {
  return (options && options.logger) || console;
}

function syncDevice(deviceId, options) {
  const id = String(deviceId || '');
  const traceId = (options && options.traceId) || crypto.randomUUID();
  const source = (options && options.source) || 'unknown';
  const logger = syncLogger(options);
  const startedAt = Date.now();
  logger.log(`[SYNC ENTER] traceId=${traceId} device=${id} source=${source}`);

  const prev = deviceSyncGates.get(id) || Promise.resolve();
  let release;
  const completed = new Promise((resolve) => {
    release = resolve;
  });
  const tail = prev.catch(() => {}).then(() => completed);
  deviceSyncGates.set(id, tail);
  return (async () => {
    logger.log(`[SYNC GATE WAIT] traceId=${traceId} device=${id}`);
    try {
      await prev;
    } catch (err) {
      // runSyncDevice always resolves a summary (never rejects), so this arm is
      // purely defensive against a genuinely rejected gate predecessor.
    }
    logger.log(`[SYNC GATE ACQUIRED] traceId=${traceId} device=${id}`);
    try {
      const result = await runSyncDevice(id, { ...(options || {}), traceId, source, logger });
      logger.log(`[SYNC EXIT] traceId=${traceId} device=${id} status=${result && result.status} durationMs=${Date.now() - startedAt}`);
      return result;
    } finally {
      release();
      if (deviceSyncGates.get(id) === tail) deviceSyncGates.delete(id);
    }
  })();
}

// Sync one device: read -> compile -> allocate -> diff -> apply (if enabled)
// -> readback verify with bounded retries. Never throws for expected conditions.
// Returns a structured result ({ status, changedTimers, changedRules, ... }).
// Persist the sync outcome onto Device.scheduleSyncInfo. EVERY terminal
// outcome goes through this so the stored status can never go stale: leaving
// a previous 'synced' in place after a failure made the retry sweep and the
// startup backfill believe the device was converged and skip it forever.
// managedTimerIndexes is sticky ownership — preserved verbatim on failures
// (orphan cleanup depends on it), replaced only by a verified synced result.
async function persistOutcome(deviceModel, deviceId, managedTimerIndexes, status, error) {
  if (!deviceModel || typeof deviceModel.updateOne !== 'function') return;
  try {
    await deviceModel.updateOne(
      { deviceId },
      {
        $set: {
          scheduleSyncInfo: {
            managedTimerIndexes: managedTimerIndexes || [],
            status,
            lastSyncedAt: new Date(),
            error: error || null,
          },
        },
      },
    );
  } catch (_) {
    // Persistence of the outcome must never mask the sync result itself.
  }
}

async function runSyncDevice(deviceId, { deviceModel = Device, scheduleModel = Schedule, traceId = '?', source = 'unknown', logger = console } = {}) {
  const summary = {
    status: 'pending',
    deviceId,
    changedTimers: [],
    changedRules: [],
    verificationPassed: null,
    attempts: 0,
    error: null,
    conflicts: [],
    unsupportedReasons: [],
    enabled: syncEnabled(),
    plan: null,
    allocation: [],
    protected: { timers: [], rules: [] },
    intendedWrites: [],
    publishedWrites: [],
    verification: [],
  };

  // Last-known sticky ownership, hoisted so the OUTER catch can persist a
  // failure WITHOUT wiping it. Wiping here used to cascade: one unexpected
  // throw erased managedTimerIndexes, which then deadlocked Rule2 recognition
  // on the next run (clauses pointing at now-unmanaged slots).
  let managedSnapshot = [];
  try {
    let device;
    if (deviceModel && typeof deviceModel.findOne === 'function') {
      let query = deviceModel.findOne({ deviceId });
      if (query && typeof query.select === 'function') query = query.select('+scheduleSyncInfo');
      device = await query;
      if (!device) {
        summary.status = 'unsupported';
        summary.error = `Device ${deviceId} not found`;
        return summary;
      }
    }
    const schedules = await scheduleModel.find({ deviceId, pendingDelete: { $ne: true } });
    const plan = compile({ deviceId, schedules, device });
    summary.conflicts = plan.conflicts.slice();
    summary.unsupportedReasons = plan.unsupportedReasons.slice();
    summary.plan = planView(plan);
    // Sticky ownership recorded by previous successful syncs. Read BEFORE the
    // empty-plan fast-path: a device whose schedules were all deleted/disabled
    // still owns orphaned onboard timers that must be cleared, not ignored.
    const managedIndexes =
      (device && device.scheduleSyncInfo && device.scheduleSyncInfo.managedTimerIndexes) || [];
    managedSnapshot = managedIndexes;

    if (plan.requiredTimerCount === 0 && plan.rules.length === 0 && managedIndexes.length === 0) {
      summary.status = 'synced';
      summary.verificationPassed = true;
      summary.error = 'No scheduled actions to sync';
      return summary;
    }

    logger.log(`[SYNC INITIAL READ] traceId=${traceId}`);
    const actual = await readDeviceScheduleState(deviceId, { traceId });
    summary.protected = protectedResources(actual, managedIndexes);
    const result = computeWrites(plan, actual, managedIndexes);
    summary.allocation = allocationView(result.allocation || new Map());

    if (!result.okay) {
      summary.status = 'unsupported';
      summary.conflicts = result.conflicts;
      summary.unsupportedReasons = result.unsupportedReasons;
      summary.error = result.unsupportedReasons[0] || 'Plan cannot be safely applied';
      await persistOutcome(deviceModel, deviceId, managedIndexes, 'unsupported', summary.error);
      return summary;
    }

    const writes = result.writes || [];
    summary.changedTimers = writes.filter((w) => w.kind === 'timer').map((w) => w.index);
    summary.changedRules = writes.filter((w) => w.kind === 'rule').map((w) => w.index);
    summary.intendedWrites = writes.map((w) =>
      w.kind === 'timer'
        ? { kind: 'timer', index: w.index, config: timerPayload(w.desired) }
        : { kind: 'rule', index: w.index, text: w.text },
    );

    if (!syncEnabled()) {
      // Dry run: deliberately NOT persisted. A preview must never clobber the
      // device's real recorded state ('synced'/'failed') — the flag-off path
      // publishes nothing, so there is no new truth to store.
      summary.status = 'pending';
      summary.error = `${SYNC_FLAG} is disabled - no writes published (dry run complete)`;
      return summary;
    }

    // Clock accuracy gate: device-native timers fire on the DEVICE's clock, so
    // a drifted/unconfigured NTP setup silently shifts every scheduled window.
    // Best-effort and non-fatal: a failed check/correction is logged, never
    // aborts the sync.
    try {
      const clock = await ensureDeviceClock(deviceId, { traceId, logger });
      summary.clock = clock;
    } catch (err) {
      logger.warn(`[SYNC CLOCK] traceId=${traceId} device=${deviceId} clock step error: ${err.message}`);
    }
    // Global timer arm gate: per-timer Enable:1 is inert while `Timers` is OFF.
    try {
      summary.timersArmed = await ensureTimersArmed(deviceId, { traceId, logger });
    } catch (err) {
      logger.warn(`[SYNC TIMERS] traceId=${traceId} device=${deviceId} arm step error: ${err.message}`);
    }

    // Apply phase with bounded retries: write changed resources, read back,
    // verify; on any verification failure retry the whole write set.
    let attempts = 0;
    let lastError = null;
    while (attempts < MAX_SYNC_ATTEMPTS) {
      attempts += 1;
      summary.attempts = attempts;
      logger.log(`[SYNC ATTEMPT] traceId=${traceId} attempt=${attempts}/${MAX_SYNC_ATTEMPTS}`);
      try {
        for (const w of writes) {
          if (w.kind === 'timer') {
            logger.log(`[SYNC WRITE] traceId=${traceId} type=Timer slot=${w.index}`);
            await tasmotaConfigClient.requestTasmotaConfig(deviceId, `Timer${w.index}`, timerPayload(w.desired), {
              timeoutMs: DEFAULT_TIMEOUT_MS,
              expectedResponseKey: `Timer${w.index}`,
              traceId,
            });
          } else {
            logger.log(`[SYNC WRITE] traceId=${traceId} type=Rule slot=${w.index}`);
            // 1) Store the rule body. On many Tasmota firmwares this alone
            //    leaves the rule DISABLED (State:"OFF") — the raw device logs
            //    proved exactly that.
            await tasmotaConfigClient.requestTasmotaConfig(deviceId, `Rule2`, w.text, {
              timeoutMs: DEFAULT_TIMEOUT_MS,
              expectedResponseKey: 'Rule2',
              traceId,
            });
            // 2) ACTIVATE it: `Rule2 1` is the enable command, distinct from
            //    writing the body. Idempotent when already ON.
            logger.log(`[SYNC WRITE] traceId=${traceId} type=RuleActivate slot=${w.index}`);
            await tasmotaConfigClient.requestTasmotaConfig(deviceId, `Rule2`, '1', {
              timeoutMs: DEFAULT_TIMEOUT_MS,
              expectedResponseKey: 'Rule2',
              traceId,
            });
          }
        }
        summary.publishedWrites = summary.intendedWrites.slice();

        logger.log(`[SYNC VERIFY READ] traceId=${traceId} attempt=${attempts}`);
        const after = await readDeviceScheduleState(deviceId, {
          traceId,
          timerIndexes: writes.filter((w) => w.kind === 'timer').map((w) => w.index),
          ruleIndexes: writes.filter((w) => w.kind === 'rule').map((w) => w.index),
        });
        let verified = true;
        const verification = [];
        for (const w of writes) {
          if (w.kind === 'timer') {
            const current = after.timers.find((t) => t.index === w.index);
            const matches = sameTimer(current, w.desired);
            verification.push({
              resource: `Timer${w.index}`,
              desired: { ...w.desired },
              actual: current ? { ...current } : null,
              matches,
            });
            if (!matches) {
              verified = false;
              lastError = new Error(`Timer${w.index} verification failed on attempt ${attempts}`);
              logger.log(`[SYNC VERIFY MISMATCH] traceId=${traceId} attempt=${attempts} type=Timer slot=${w.index} desired=${JSON.stringify(w.desired)} actual=${JSON.stringify(current || null)} diff=${JSON.stringify(diffTimer(w.desired, current || {}))}`);
            }
          } else {
            const current = after.rules.find((r) => r.index === w.index);
            // A true match requires BOTH the exact rule text AND an ACTIVE
            // rule (State ON). Text-only matching is what previously reported
            // `synced` while the device held the rule disabled.
            const matches = !!(
              current &&
              current.Rules === w.text &&
              String(current.State).toUpperCase() === 'ON'
            );
            verification.push({
              resource: `Rule${w.index}`,
              desired: { State: 'ON', Rules: w.text },
              actual: current ? { ...current } : null,
              matches,
            });
            if (!matches) {
              verified = false;
              lastError = new Error(`Rule2 verification failed on attempt ${attempts}`);
              logger.log(`[SYNC VERIFY MISMATCH] traceId=${traceId} attempt=${attempts} type=Rule slot=${w.index} desired=${JSON.stringify({ State: 'ON', Rules: w.text })} actual=${JSON.stringify(current || null)} diff=${JSON.stringify(diffRule({ State: 'ON', Rules: w.text }, current || {}))}`);
            }
          }
        }
        summary.verification = verification;
        logger.log(`[SYNC VERIFY RESULT] traceId=${traceId} attempt=${attempts} matched=${verified}`);

        if (verified) {
          summary.status = 'synced';
          summary.verificationPassed = true;
          summary.error = null;
          summary.attempts = attempts;
          await persistOutcome(deviceModel, deviceId, result.managed, 'synced', null);
          return summary;
        }
      } catch (err) {
        lastError = err;
      }
    }

    summary.status = 'failed';
    summary.verificationPassed = false;
    summary.error = lastError ? lastError.message : 'Sync failed after bounded retries';
    await persistOutcome(deviceModel, deviceId, managedIndexes, 'failed', summary.error);
    return summary;
  } catch (err) {
    summary.status = 'failed';
    summary.verificationPassed = false;
    summary.error = err.message;
    await persistOutcome(deviceModel, deviceId, managedSnapshot, 'failed', err.message);
    return summary;
  }
}

function sameTimer(a, b) {
  return (
    a &&
    a.Enable === b.Enable &&
    a.Mode === b.Mode &&
    a.Time === b.Time &&
    a.Window === b.Window &&
    a.Days === b.Days &&
    a.Repeat === b.Repeat &&
    a.Output === b.Output &&
    a.Action === b.Action
  );
}

// Clock-drift threshold before correction fires (device clock vs server).
const CLOCK_DRIFT_TOLERANCE_SEC = 120;
const NTP_SERVERS = ['pool.ntp.org', 'time.google.com', 'time.cloudflare.com'];

// Schedules are authored in this zone; device-native Timers match the device's
// LOCAL wall time, so that wall time is what the health check must agree with.
const APP_TIMEZONE = process.env.APP_TIMEZONE || 'Africa/Algiers';

// Minutes-of-day the device's wall clock is ahead of the expected
// APP_TIMEZONE wall clock (wraps at midnight). null when the Time string is
// unparseable. This is the TZ-aware check: NTP keeps Epoch absolute, but
// Timers match the device's LOCAL wall time, so a wrong Timezone shows up here
// even when Epoch drift would be zero.
function wallClockDriftSec(deviceTimeStr) {
  if (typeof deviceTimeStr !== 'string') return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/.exec(deviceTimeStr);
  if (!m) return null;
  const { DateTime } = require('luxon');
  const deviceLocal = DateTime.fromObject(
    {
      year: Number(m[1]), month: Number(m[2]), day: Number(m[3]),
      hour: Number(m[4]), minute: Number(m[5]), second: Number(m[6]),
    },
    { zone: 'utc' }, // treat as plain wall time; only the HH:mm:ss matters
  );
  const expected = DateTime.now().setZone(APP_TIMEZONE);
  const devMin = deviceLocal.hour * 3600 + deviceLocal.minute * 60 + deviceLocal.second;
  const expMin = expected.hour * 3600 + expected.minute * 60 + expected.second;
  let diff = Math.abs(devMin - expMin);
  if (diff > 43200) diff = 86400 - diff; // midnight wrap
  return diff;
}

// Verify the device clock is sane and, when it is not, (re)point NTP at
// standard pools so the firmware self-corrects. Tasmota-native timers execute
// on this clock, so this is what keeps window boundaries accurate.
//
// Health is checked in two tiers:
//   1. `Epoch` unix timestamp when the firmware exposes it — absolute, exact.
//   2. Fallback (firmwares whose `Time` reply has no Epoch): compare the
//      device's wall-clock string against the expected APP_TIMEZONE wall
//      time. This also catches a wrong-device-Timezone setup, because the
//      wall string shifts with it.
// On failure: republish each NtpServer<n> (own echo key) so the device
// resyncs; if the wall string is ALSO offset after that, the mismatch is
// almost certainly Timezone configuration — logged loudly, never overwritten
// (user config). Every failure is non-fatal.
async function ensureDeviceClock(deviceId, { traceId = '?', logger = console } = {}) {
  const result = { checked: true, corrected: false, driftSec: null, error: null };
  let timeRes = null;
  try {
    timeRes = await tasmotaConfigClient.requestTasmotaConfig(
      deviceId,
      'Time',
      '',
      { timeoutMs: DEFAULT_TIMEOUT_MS, expectedResponseKey: 'Time', traceId },
    );
  } catch (err) {
    result.error = `Time read failed: ${err.message}`;
    logger.warn(`[SYNC CLOCK] traceId=${traceId} device=${deviceId} ${result.error}`);
    return result;
  }

  const epoch = toNum(timeRes && timeRes.Epoch);
  if (epoch !== null && epoch > 0) {
    result.driftSec = Math.round(Math.abs(Date.now() / 1000 - epoch));
    if (result.driftSec <= CLOCK_DRIFT_TOLERANCE_SEC) {
      return result; // healthy (absolute check)
    }
  } else {
    // No Epoch on this firmware: fall back to the TZ-aware wall-clock check.
    const wall = wallClockDriftSec(timeRes && timeRes.Time);
    if (wall !== null && wall <= CLOCK_DRIFT_TOLERANCE_SEC) {
      result.driftSec = wall;
      return result; // healthy (wall check) — no false "CORRECTED" spam
    }
    if (wall !== null) result.driftSec = wall;
  }

  // Unhealthy: repoint NTP so the firmware corrects itself within minutes.
  for (let i = 0; i < NTP_SERVERS.length; i++) {
    try {
      await tasmotaConfigClient.requestTasmotaConfig(
        deviceId,
        `NtpServer${i + 1}`,
        NTP_SERVERS[i],
        { timeoutMs: DEFAULT_TIMEOUT_MS, expectedResponseKey: `NtpServer${i + 1}`, traceId },
      );
    } catch (err) {
      // Firmware variants differ in whether setting echoes the key; a miss is
      // tolerated — the correction intent is logged either way.
      logger.log(
        `[SYNC CLOCK] traceId=${traceId} device=${deviceId} NtpServer${i + 1} write unconfirmed: ${err.message}`,
      );
    }
  }
  result.corrected = true;
  logger.warn(
    `[SYNC CLOCK] traceId=${traceId} device=${deviceId} CORRECTED — ` +
      `previousEpoch=${epoch === null ? 'none' : epoch} ` +
      `driftSec=${result.driftSec === null ? 'n/a' : result.driftSec} ` +
      `(tolerance ${CLOCK_DRIFT_TOLERANCE_SEC}s). NTP pools rewritten.` +
      (epoch === null && result.driftSec !== null && result.driftSec > CLOCK_DRIFT_TOLERANCE_SEC
        ? ' Wall-time offset persists after NTP: check device Timezone/TimeSTD/TimeDST config.'
        : ''),
  );
  return result;
}

// Tasmota arms/disarms ALL timers globally via `Timers 1` / `Timers 0`. A
// per-timer Enable:1 does nothing while the global switch is OFF — the classic
// "everything looks configured but nothing fires" trap. Read the flag and arm
// it when needed; idempotent and non-fatal.
async function ensureTimersArmed(deviceId, { traceId = '?', logger = console } = {}) {
  const result = { checked: true, corrected: false, error: null };
  let res = null;
  try {
    res = await tasmotaConfigClient.requestTasmotaConfig(
      deviceId,
      'Timers',
      '',
      { timeoutMs: DEFAULT_TIMEOUT_MS, expectedResponseKey: 'Timers', traceId },
    );
  } catch (err) {
    result.error = `Timers read failed: ${err.message}`;
    logger.warn(`[SYNC TIMERS] traceId=${traceId} device=${deviceId} ${result.error}`);
    return result;
  }
  const state = res && res.Timers != null ? String(res.Timers).toUpperCase() : null;
  if (state === 'ON') return result; // already armed
  try {
    await tasmotaConfigClient.requestTasmotaConfig(
      deviceId,
      'Timers',
      '1',
      { timeoutMs: DEFAULT_TIMEOUT_MS, expectedResponseKey: 'Timers', traceId },
    );
    result.corrected = true;
    logger.warn(
      `[SYNC TIMERS] traceId=${traceId} device=${deviceId} ARMED — global Timers was ` +
        `${state === null ? 'unreadable' : state}; sent "Timers 1".`,
    );
  } catch (err) {
    result.error = `Timers arm failed: ${err.message}`;
    logger.warn(`[SYNC TIMERS] traceId=${traceId} device=${deviceId} ${result.error}`);
  }
  return result;
}

const TIMER_FIELDS = ['Enable', 'Mode', 'Time', 'Window', 'Days', 'Repeat', 'Output', 'Action'];

// Field-level diff between desired and actual (diagnostic only). Only fields
// that differ are reported, so the exact verification-failure cause is visible.
function diffTimer(desired, actual) {
  const diff = {};
  for (const f of TIMER_FIELDS) {
    if (desired[f] !== actual[f]) diff[f] = { desired: desired[f], actual: actual[f] };
  }
  return diff;
}

function diffRule(desired, actual) {
  const diff = {};
  for (const f of ['State', 'Once', 'StopOnError', 'Rules']) {
    if (desired[f] !== actual[f]) diff[f] = { desired: desired[f], actual: actual[f] };
  }
  return diff;
}

// DEV-ONLY (Phase 6.5): manual sync trigger for the real device. Wraps
// syncDevice and returns the full dry-run/sync report (plan, allocation,
// protected resources, intended/published writes, verification). This function
// is intentionally exported so the dev route and its tests share it; it is a
// thin pass-through and adds no behavior of its own.
function manualSync(deviceId, options) {
  return syncDevice(deviceId, options);
}

module.exports = {
  syncDevice,
  manualSync,
  readDeviceScheduleState,
  computeWrites,
  normalizeTimer,
  normalizeRule,
  isDefaultTimer,
  timerPayload,
  FACTORY_DEFAULT_TIMER,
  buildRuleText,
  isSteesOwnedRule2,
  allocateSlots,
  protectedResources,
  planView,
  allocationView,
  syncEnabled,
  ensureDeviceClock,
  ensureTimersArmed,
  SYNC_FLAG,
  MAX_SYNC_ATTEMPTS,
  USER_TRIGGER_TIMER,
  USER_RULE_INDEXES,
  STEES_RULE_INDEX,
};