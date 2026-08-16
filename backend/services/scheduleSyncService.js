const Device = require('../models/Device');
const Schedule = require('../models/Schedule');
const { compile, MAX_TIMERS, MAX_RULE_LENGTH } = require('./scheduleCompiler');
const tasmotaConfigClient = require('./tasmotaConfigClient');

const SYNC_FLAG = 'TASMOTA_SCHEDULE_SYNC_ENABLED';
const MAX_SYNC_ATTEMPTS = 3;
const DEFAULT_TIMEOUT_MS = 5000;

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
  return JSON.stringify({
    Enable: t.Enable || 1,
    Mode: t.Mode || 0,
    Time: t.Time,
    Window: t.Window || 0,
    Days: t.Days,
    Repeat: t.Repeat || 1,
    Output: t.Output || 0,
    Action: t.Action || 0,
  });
}

// Read all 16 timers and 3 rules individually (never the bulk `Timers`
// response). Reads are best-effort: a missing timer/rule response normalizes to
// its default so the sync can still proceed with what it could verify.
async function readDeviceScheduleState(deviceId) {
  const timerNames = [];
  const ruleNames = [];
  for (let i = 1; i <= 16; i++) timerNames.push(`Timer${i}`);
  for (let i = 1; i <= 3; i++) ruleNames.push(`Rule${i}`);

  const responses = await Promise.all([
    ...timerNames.map((name) =>
      tasmotaConfigClient.requestTasmotaConfig(deviceId, name, '', { timeoutMs: DEFAULT_TIMEOUT_MS, expectedResponseKey: name }),
    ),
    ...ruleNames.map((name) =>
      tasmotaConfigClient.requestTasmotaConfig(deviceId, name, '', { timeoutMs: DEFAULT_TIMEOUT_MS, expectedResponseKey: name }),
    ),
  ]);

  const timers = timerNames.map((name, i) => {
    const payload = responses[i];
    return { index: i + 1, ...normalizeTimer(payload && payload[name]) };
  });
  const rules = ruleNames.map((name, i) => {
    const payload = responses[i + 16];
    return normalizeRule(i + 1, payload && payload[name]);
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
    const occupied = rule2 && rule2.State !== 'OFF' && rule2.Rules !== '';
    if (occupied && rule2.Rules !== ruleText) {
      result.okay = false;
      result.conflicts.push('Rule2 is occupied by user configuration and cannot be overwritten');
      result.unsupportedReasons.push('Rule2 is not free');
      return result;
    }
    if (!occupied || rule2.Rules !== ruleText) {
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
  if (rule2 && rule2.State !== 'OFF' && rule2.Rules !== '') {
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

function syncDevice(deviceId, options) {
  const id = String(deviceId || '');
  const prev = deviceSyncGates.get(id) || Promise.resolve();
  let release;
  const completed = new Promise((resolve) => {
    release = resolve;
  });
  const tail = prev.catch(() => {}).then(() => completed);
  deviceSyncGates.set(id, tail);
  return (async () => {
    try {
      await prev;
    } catch (err) {
      // runSyncDevice always resolves a summary (never rejects), so this arm is
      // purely defensive against a genuinely rejected gate predecessor.
    }
    try {
      return await runSyncDevice(id, options || {});
    } finally {
      release();
      if (deviceSyncGates.get(id) === tail) deviceSyncGates.delete(id);
    }
  })();
}

// Sync one device: read -> compile -> allocate -> diff -> apply (if enabled)
// -> readback verify with bounded retries. Never throws for expected conditions.
// Returns a structured result ({ status, changedTimers, changedRules, ... }).
async function runSyncDevice(deviceId, { deviceModel = Device, scheduleModel = Schedule } = {}) {
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
    const schedules = await scheduleModel.find({ deviceId });
    const plan = compile({ deviceId, schedules, device });
    summary.conflicts = plan.conflicts.slice();
    summary.unsupportedReasons = plan.unsupportedReasons.slice();
    summary.plan = planView(plan);

    if (plan.requiredTimerCount === 0 && plan.rules.length === 0) {
      summary.status = 'synced';
      summary.verificationPassed = true;
      summary.error = 'No scheduled actions to sync';
      return summary;
    }

    const actual = await readDeviceScheduleState(deviceId);
    const managedIndexes = (device && device.scheduleSyncInfo && device.scheduleSyncInfo.managedTimerIndexes) || [];
    summary.protected = protectedResources(actual, managedIndexes);
    const result = computeWrites(plan, actual, managedIndexes);
    summary.allocation = allocationView(result.allocation || new Map());

    if (!result.okay) {
      summary.status = 'unsupported';
      summary.conflicts = result.conflicts;
      summary.unsupportedReasons = result.unsupportedReasons;
      summary.error = result.unsupportedReasons[0] || 'Plan cannot be safely applied';
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
      summary.status = 'pending';
      summary.error = `${SYNC_FLAG} is disabled - no writes published (dry run complete)`;
      return summary;
    }

    // Apply phase with bounded retries: write changed resources, read back,
    // verify; on any verification failure retry the whole write set.
    let attempts = 0;
    let lastError = null;
    while (attempts < MAX_SYNC_ATTEMPTS) {
      attempts += 1;
      summary.attempts = attempts;
      try {
        for (const w of writes) {
          if (w.kind === 'timer') {
            await tasmotaConfigClient.requestTasmotaConfig(deviceId, `Timer${w.index}`, timerPayload(w.desired), {
              timeoutMs: DEFAULT_TIMEOUT_MS,
              expectedResponseKey: `Timer${w.index}`,
            });
          } else {
            await tasmotaConfigClient.requestTasmotaConfig(deviceId, `Rule2`, w.text, {
              timeoutMs: DEFAULT_TIMEOUT_MS,
              expectedResponseKey: 'Rule2',
            });
          }
        }
        summary.publishedWrites = summary.intendedWrites.slice();

        const after = await readDeviceScheduleState(deviceId);
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
            }
          } else {
            const current = after.rules.find((r) => r.index === w.index);
            const matches = !!(current && current.Rules === w.text);
            verification.push({
              resource: `Rule${w.index}`,
              desired: { State: 'ON', Rules: w.text },
              actual: current ? { ...current } : null,
              matches,
            });
            if (!matches) {
              verified = false;
              lastError = new Error(`Rule2 verification failed on attempt ${attempts}`);
            }
          }
        }
        summary.verification = verification;

        if (verified) {
          summary.status = 'synced';
          summary.verificationPassed = true;
          summary.error = null;
          summary.attempts = attempts;
          if (deviceModel && typeof deviceModel.updateOne === 'function') {
            await deviceModel.updateOne(
              { deviceId },
              {
                $set: {
                  scheduleSyncInfo: {
                    managedTimerIndexes: result.managed,
                    status: 'synced',
                    lastSyncedAt: new Date(),
                    error: null,
                  },
                },
              },
            );
          }
          return summary;
        }
      } catch (err) {
        lastError = err;
      }
    }

    summary.status = 'failed';
    summary.verificationPassed = false;
    summary.error = lastError ? lastError.message : 'Sync failed after bounded retries';
    return summary;
  } catch (err) {
    summary.status = 'failed';
    summary.verificationPassed = false;
    summary.error = err.message;
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
  buildRuleText,
  allocateSlots,
  protectedResources,
  planView,
  allocationView,
  syncEnabled,
  SYNC_FLAG,
  MAX_SYNC_ATTEMPTS,
  USER_TRIGGER_TIMER,
  USER_RULE_INDEXES,
  STEES_RULE_INDEX,
};