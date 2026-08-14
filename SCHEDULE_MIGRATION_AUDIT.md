# STEES — Schedule Migration Audit (Phase 1)

Audit of current schedule-related Tasmota state and the migration assumptions
before any code is written. Phase 1 only: nothing below modifies any device,
broker, or runtime behaviour.

---

## 1. Current Timer1–Timer16 usage

- **No STEES code touches Tasmota timers.** A grep over `backend/` and
  `flutter_app/lib/` for `Timer`, `Timers`, `Rule1|2|3`, `Backlog`, `Clock`
  finds only:
  - JS `setInterval`/`setTimeout` timers (schedule/rule engines, MQTT ACK
    timeouts, prune loops) — unrelated to Tasmota's 16 JSON timers.
  - The Flutter provisioning wizard's `Backlog` commands, which configure the
    MQTT broker/identity during provisioning — not schedule timers/rules.
- The backend's MQTT gateway only ever publishes `cmnd/<deviceId>/POWER<n>` and
  `cmnd/<deviceId>/State`. It has never issued `cmnd/<deviceId>/Timer<x>` or
  `cmnd/<deviceId>/Rule<x>`.
- **Conclusion:** Tasmota Timer1–16 are untouched by STEES today. The 16
  timer slots are free from STEES's perspective. Their actual on-device state
  can only be confirmed by reading the physical device (see §5) before Phase 6.

## 2. Current Rule1 / Rule2 / Rule3 usage

- No STEES code reads or writes Tasmota rules. Rule1/2/3 are free from STEES's
  perspective.
- The verified hardware test used **Rule1** for the `Clock#Timer` trigger.
- **Ownership proposal (to confirm against the live device in Phase 6 before
  any write):** `Rule1` = STEES-managed, `Rule2` = reserved, `Rule3` =
  untouched. Until read-back verification runs, the sync service must never
  overwrite a rule it did not first read and own.

## 3. Rule length and available space

- Each rule set is limited to **511 characters** (confirmed by Tasmota docs and
  issues arendst/Tasmota#3204 and #7110; `MAX_RULE_LENGTH = 511`). There are
  three independent sets, so 3 × 511 = 1533 chars total, but each set is capped
  at 511 independently.
- Rules are stored **dynamically compressed**; the 511 limit applies to the
  rule *text* (`Length`), not the compressed flash footprint. Modern docs say a
  set "expects at least 1000 chars" because compression frees the on-disk
  budget — but the safe, conservative compile bound remains **511 per set**.
- Readback reports available space differently across firmware generations:
  older builds return `"Free": <chars>` (e.g. `Free:274`), newer builds return
  `"Length": <chars used>`. Phase 6 verification must accept both.

## 4. Whether any existing STEES functionality uses Tasmota Rules

- **No.** The only `Rule`-related identifier in the codebase is the MongoDB
  `Rule` model + `ruleEngine` (sensor-threshold automations executed by the
  backend over MQTT POWER commands). That is unrelated to Tasmota's native
  `Rule1..3` feature and is out of scope for this migration.

## 5. Existing Tasmota timer readback format through MQTT

- **Single timer query:** `cmnd/<deviceId>/Timer<n>` with an empty payload (or
  `?`) → `stat/<deviceId>/RESULT` returns `{"Timer<n>":{...}}` for the current
  config of that timer. Supported across firmware versions.
- **Bulk query:** `cmnd/<deviceId>/Timers` with an empty payload returns the
  armed timers as JSON in modern builds (see arendst/Tasmota#20312), but the
  exact shape varies by firmware. Phase 6 should read **per-timer** for robust,
  version-tolerant verification.
- **Write:** `cmnd/<deviceId>/Timer<n> {json}` sets the config; `Timer<n> 0`
  clears it. `Timers 0|1|2` disables/enables/toggles all timers.
- **Timer JSON shape (authoritative, from tasmota.github.io/docs/Timers):**

  | Key | Meaning |
  |---|---|
  | `Enable` | `0` disarm / `1` arm |
  | `Mode` | `0` clock time, `1` sunrise, `2` sunset (we always use `0`) |
  | `Time` | `HH:MM` clock time |
  | `Window` | `0..15` random minutes jitter (we always use `0`) |
  | `Days` | 7-char mask in `SMTWTFS` order; `0`/`-` = OFF, any other char = ON |
  | `Repeat` | `0` = fire once only, `1` = repeat |
  | `Output` | relay `1..16` used when no rule is enabled (direct-action timers) |
  | `Action` | `0` output OFF, `1` output ON, `2` toggle, `3` trigger `Clock#Timer` rule |

- **Verified hardware chain (from the task):**
  `Timer<n> (Action:3)` → `Clock#Timer=<n>` → `Rule1 ON Clock#Timer=3 DO
  Backlog Power1 ON; Power2 ON ENDON` → relay channels. Confirmed working.

## 6. Existing MQTT RESULT handling capability

- `mqttGateway` already subscribes to `stat/+/RESULT` (qos1) and
  `stat/+/POWER+`. `_handle` parses RESULT JSON and resolves pending POWER ACKs
  keyed by `deviceId:channel`.
- Timer/rule reads and writes also reply on `stat/<deviceId>/RESULT` (e.g.
  `{"Timer1":{...}}`, `{"Rule1":{...}}`), so **no new MQTT subscription is
  required** for Phase 6 read-back. What is required is an **isolated
  request/response mechanism** for timer/rule commands, separate from
  `publishCommand()`'s `deviceId:channel` ACK registry, so a timer write ACK
  can never be mistaken for (or collide with) a POWER ACK. This is Phase 6
  work; nothing is touched now.

## 7. Assumptions in the plan that conflict with the real code

1. **`Repeat` value.** The task's *verified* config used `Repeat:0`, but
   Tasmota docs say `Repeat 0 = fire once, 1 = repeat`. A `Repeat:0` timer
   disarms after firing — fine for a one-shot test, wrong for a recurring
   irrigation schedule. The task's own Timer strategy says `Repeat:1`, which is
   the correct recurring value. **The compiler emits `Repeat:1`** and this
   should be re-verified on hardware (the Phase 6 read-back will surface it).
2. **Rule readback shape varies by firmware** (`Free` vs `Length`, `Once`/
   `StopOnError` presence). Phase 6 comparison must normalize both.
3. **Bulk `Timers` readback shape is not stable across firmware** — per-timer
   reads are the reliable path.
4. **Rule ownership is unproven until live read-back.** The "Rule1 = STEES
   managed, Rule2 = reserved, Rule3 = untouched" split is a proposal that must
   be confirmed by reading the actual device before Phase 6 writes anything.
5. **Same-day ranges only.** `Schedule` model and route validation reject
   overnight/inverted ranges (`end <= start`). The compiler can rely on this;
   there is no overnight support to preserve.
6. **Multi-executor invariant is currently unenforced.** `scheduleEngine`
   executes for every device with enabled schedules. The device-level
   `scheduleExecutionMode` (Phase 5) is the enforcement point; the compiler
   itself is pure and introduces no execution.
7. **`daysOfWeek` convention confirmed.** Stored as `0=Mon..6=Sun`, matching
   `_desiredState()`'s `(now.weekday + 6) % 7`. Tasmota's Days mask is
   `SMTWTFS` (Sunday-first), so the mapping used by the compiler is
   `pos = (steesDay + 1) % 7`.

## 8. Exact files that Phase 2 will change

- **Add** `backend/services/scheduleCompiler.js` — pure compile function
  (no MQTT, no DB, no network, no side effects).
- **Add** `backend/test/scheduleCompiler.test.js` — unit tests.
- **No changes** to `scheduleEngine.js`, `mqttGateway.js`, models, routes,
  server, Flutter, or firmware.

Everything else in this migration (sync service, execution modes, dry-run
hooks, metadata fields, engine gating) is explicitly deferred to later phases.

---

# Phase 4 — Dry-Run + Behavioral Parity Verification

Proof that `scheduleCompiler` output has identical execution semantics to the
existing `scheduleEngine._desiredState()` — via a pure simulator only. No
MQTT publishes, no `Timer<n>`/`Rule<n>` commands, no Tasmota config changes,
no schedule CRUD changes, no Flutter changes, and no production timers or
background loops were introduced. `scheduleEngine` remains the single source
of execution truth and was **not modified**.

## Files introduced (all new, untracked)

- `backend/services/scheduleSimulator.js` — pure `simulateCompiledPlan(plan,
  dateTime)` (direct timers + `Clock#Timer=N` rule parsing → channel ON/OFF
  map), plus `extractRuleActions` / `steesDay` / `tasmotaDayPosition` /
  `minutesOfDay` / `minutesFromTime` helpers. Deterministic: last event per
  channel wins within the day, with an all-OFF baseline at 00:00 to mirror
  `_desiredState`'s no-OFF-transition model.
- `backend/services/scheduleDryRunService.js` — `buildDryRun({deviceId,
  schedules, device, now?})` → the documented result shape
  (`{deviceId, generatedAt, compiler:{supported, requiredTimerCount,
  ruleCount, ruleLengths, unsupportedReasons, conflicts}, plan:{timers,
  rules}}`); `dryRunForDevice(deviceId, {deviceModel?, scheduleModel?})` for
  DB-backed invocations (model lookups injectable for tests); `buildPreview`
  — Phase 4E dev-only, read-only preview (`timers`, `rule1` text,
  `timerCount`, `ruleCharacterCount`, `supported`, `unsupportedReasons`,
  sampled parity mismatches). **No public/networking/MQTT endpoint** was
  added; preview is an internal helper.
- `backend/test/scheduleParity.test.js` — behavioral parity vs the REAL
  `scheduleEngine._desiredState()` over the shared reference aggregator
  `referenceScheduleState`, at boundary timestamps (before/at/after start/end,
  one-minute-around, + middle), all 7 weekdays, 16 deterministic scenarios and
  a fixed-seed (mulberry32, seed 42) randomized run. On mismatch it prints
  Schedules / Compiled plan / Timestamp / Expected / Actual.
- `backend/test/scheduleDryRun.test.js` — result shape, JSON-safe output
  (no Sets/Maps/Dates), supported/unsupported paths, rule-length reporting,
  pure service (model mocks), preview output, reference-vs-simulator parity.

No existing file was modified in Phase 4 (`git status` shows only the new
untracked files above).

## How parity is checked

`referenceScheduleState(schedules, dt)` reuses the real
`scheduleEngine._desiredState(schedule, dt)` per schedule and aggregates with
ON-wins semantics (any schedule wanting a channel ON makes it ON). The
simulator replays only the compiler's output (timers + Rule1 text). Because
both sides use the same `dateTime` object (a luxon DateTime shaped
`{weekDay, hour, minute}`), the engine's stateless per-schedule logic is
compared directly with no need for DB, MQTT, or a live clock.

## Parity counts (exact test run)

- Deterministic: **4655 timestamps** compared across the 16 scenarios and all
  7 weekdays, **0 mismatches**.
- Randomized: **100 sets × 100 timestamps = 10000 comparisons** (fixed seed),
  **0 mismatches**.
- Full backend suite: **`# tests 114, # pass 114, # fail 0`**. Baseline was 90
  before Phase 4; the +24 new tests are the 7 dry-run tests and the 17 parity
  subtests, all green.

## Runtime safety confirmation

- `scheduleEngine.js`, `mqttGateway.js`, all models/routes/server/Flutter:
  **unchanged** (git diff clean; only untracked new files).
- **MQTT publishes: 0** from Phase 4 code paths (compiler, simulator, dry-run
  service are pure/read-only; tests contain no broker and no publishing).
- **Tasmota writes: 0.** No `Timer<n>`/`Rule<n>`/`Backlog` commands; nothing
  touches firmware config.
- **Flutter: 0 changes.**
- **Manual-control regression: none** — no control path is touched.
- No new production timers/interval loops; the dry-run/preview helpers run
  only when called explicitly.
- The `unsupportedReasons`/`conflicts` surface is exercised (e.g. >16 timers,
  Rule1 > 511 chars) without ever applying such a plan.

## What Phase 4 does NOT do (still deferred)

MQTT sync, live reads, Timer/Rule writes, shadow execution, migration mode,
`scheduleExecutionMode` gating, and disabling the backend engine are all out
of scope and remain deferred to later phases.

---

# Phase 5 — Real Tasmota Device Read-Only Verification

Inspection only. No production code changed, no writes, no config, no POWER
commands. `git status` still shows only the four Phase 1–4 files; the probe
scripts live outside the repo tree in the temp dir. Device verified live:
**`34987AC30304`** (MAC `34:98:7A:C3:03:04`) on `broker.emqx.io:1883`
(the broker configured in the backend's `.env`). HiveMQ cloud had zero
devices, confirming the real device is on the public EMQX broker.

## A. Commands/topics inspected (all read-only)

| CMD topic (payload) | Response topic | Purpose |
|---|---|---|
| `cmnd/<dev>/Status` (`0,3,4,5,6`) | `stat/<dev>/STATUS`, `STATUS1`, `STATUS3`, `STATUS4`, `STATUS5`, `STATUS6`, `STATUS7`, `STATUS8`, `STATUS10`, `STATUS11` | identity/firmware/time/network |
| `cmnd/<dev>/Time` (empty) | `stat/<dev>/RESULT` `{"Time":...}` | current device clock |
| `cmnd/<dev>/Timezone` (empty) | `stat/<dev>/RESULT` `{"Timezone":"+01:00"}` | timezone |
| `cmnd/<dev>/NtpServer` (empty) | `stat/<dev>/RESULT` `{NtpServer1..3}` | NTP servers |
| `cmnd/<dev>/TelePeriod` (empty) | `stat/<dev>/RESULT` `{"TelePeriod":300}` | telemetry cadence |
| `cmnd/<dev>/Timers` (empty) | `stat/<dev>/RESULT` bulk | global timers + all 16 |
| `cmnd/<dev>/Timer1`..`Timer16` (empty) | `stat/<dev>/RESULT` per-timer | individual reads |
| `cmnd/<dev>/Rule1`..`Rule3` (empty) | `stat/<dev>/RESULT` per-rule | rule readback |
| LWT / STATE (unsolicited) | `tele/<dev>/LWT` = `Online`, `tele/<dev>/STATE` every 300 s | liveness/state |

Putting the argument IN the topic (`cmnd/<dev>/Status 0`) is rejected as
`{"Command":"Unknown","Input":"STATUS 0"}` — the payload carries the argument.

## B. Actual response shapes observed

- **Bulk `Timers`** (matches each per-timer read on this firmware):
  `{"Timers":"ON","Timer1":{...},"Timer2":{...},..."Timer16":{...}}` — 1734
  bytes. This firmware (15.5.0) returns ALL 16 timers and they agree with the
  individual `Timer<n>` reads below.
- **Per-timer**: `{"Timer<n>":{"Enable":0,"Mode":0,"Time":"HH:MM","Window":0,"Days":"SMTWTFS","Repeat":0,"Output":1,"Action":0}}`
- **Rule readback** (classic `Free`-style, no `Length`-only firmwares needed
  here): `{"Rule<n>":{"State":"ON|OFF","Once":"OFF","StopOnError":"OFF","Length":N,"Free":M,"Rules":"..."}}`
- **Time**: `{"Time":"2026-08-14T17:30:52"}` · **Timezone**: `{"Timezone":"+01:00"}`
- **NTP**: `{"NtpServer1":"2.pool.ntp.org","NtpServer2":"2.europe.pool.ntp.org","NtpServer3":"2.nl.pool.ntp.org"}`
- **StatusN topics** (`STATUS`, `STATUS1`, ...) are separate from RESULT and
  are NOT currently subscribed by the gateway (only `stat/+/RESULT`,
  `stat/+/POWER+`, tele topics). Not needed for Timer/Rule reads.

## C. Timer1 – Timer16 current state (preserved, untouched)

- Global `Timers` = `ON` (timer engine active) but every timer is **disarmed
  (`Enable:0`)** so nothing fires today.
- `Timer1` = `Time 15:18, Days 1111111, Repeat 0, Output 1, Action 0`
- `Timer2` = `00:00, 0000000, Repeat 0, Output 1, Action 0` (default)
- `Timer3` = `Time 15:32, Days 1111111, Repeat 0, Output 1, Action 3`
  (rule-trigger timer, manually tested CD-chain; disarmed)
- `Timer4..Timer16` = all default `00:00 / 0000000 / Repeat 0 / Output 1 / Action 0`
- `Days` uses `SMTWTFS` order (position 0 = Sunday) — confirms the Phase 2
  `pos=(steesDay+1)%7` mapping ('1111111' = all days armed). `Repeat:0` here is
  the manual test leftover; STEES emits `Repeat:1` (repeat) per Phase 1 §7.1.

## D. Rule1 – Rule3 current state

- `Rule1`: **State ON**, `Once OFF`, `StopOnError OFF`, `Length 54`,
  `Free 457`, text:
  `ON Clock#Timer=3 DO Backlog Power1 ON; Power2 ON ENDON`
  (i.e. the manually-tested verification chain, currently *dormant* because
  `Timer3` is disarmed).
- `Rule2`: `State OFF, Length 0, Free 511, Rules ""`.
- `Rule3`: `State OFF, Length 0, Free 511, Rules ""`.
- **These are real user/device-managed contents (Rule1) — Phase 6 must read
  and own them, never silently overwrite; the Rule1 = managed / Rule2 =
  reserved / Rule3 = untouched proposal is consistent with what is actually
  on the device.**

## E. Time / NTP readiness

- **Clock valid and synced.** `Status 7` → `StatusTIM`: `UTC
  2026-08-14T16:31:42Z`, `Local 2026-08-14T17:31:42`, `Timezone +01:00`,
  DST transitions defined (`2026-03-29T02:00:00` / `2026-10-25T03:00:00`),
  Sunrise `05:41` / Sunset `20:07` computed. `Time` returns a live ISO
  timestamp in the app zone. Boom: STEES timers (Mode 0) can rely on the
  device clock being correct.

## F. MQTT subscription compatibility

- Timer/Rule/Time/Timezone/NtpServer/TelePeriod reads all reply on
  `stat/<dev>/RESULT` — the gateway **already subscribes** to `stat/+/RESULT`
  (qos1). New reads require **no new subscription**.
- `Status N` replies on `stat/<dev>/STATUS*` which the gateway does NOT
  subscribe to; if Phase 6 needs Status-family data it must add a
  `stat/+/STATUS+` subscription or route via the separate registry.
- `powerUpdatesFrom` and `_resolveAcks` only look for `POWER(n)` keys, so a
  `TimerN`/`RuleN`/`Timers`/`Time` RESULT produces **zero** channel-updates,
  zero pending-resolution, zero state pollution. Verified programmatically.

## G. Whether Phase 6 can safely proceed

**Yes, with the planned isolated request/response registry.** Evidence:
- Reads are unambiguous and version-tolerant on this firmware; bulk `Timers`
  and per-`Timer<n>` reads agree, but Phase 6 should still prefer per-timer
  reads (bulk shape is firmware-unstable per Phase 1).
- `publishCommand`'s ACK registry is keyed `deviceId:channel` and only matches
  `POWER(n)` replies (`_resolveAcks` at mqttGateway.js:481). A Timer/Rule
  RESULT carries no `POWER` key, so it **cannot** falsely resolve or corrupt a
  pending POWER ACK — however `publishCommand` itself cannot deliver Timer/Rule
  responses to a caller either. A **separate request/response registry**
  (request → `cmnd/<dev>/TimerN|RuleN`, resolve on the matching key in
  `stat/<dev>/RESULT`) is therefore required and is safe to add.
- Write-side budget: device `MAX_PACKET_SIZE` = 1200; per-timer write JSON is
  ~108 bytes and a 511-char Rule1 response is ~601 bytes — both fit.

## H. Exact risks / blockers discovered

1. **Device MQTT user/pass set to `DVES_USER`/blank** (Status6: `MqttUser
   "DVES_USER"`, public broker with no auth) — nothing to change now, but any
   Phase 6 write path MUST be authenticated-session-agnostic and treat the
   broker as hostile/test-namespace.
2. **Rule1 is real user/device state (ON, 54 chars) referencing `Timer3`.**
   Phase 6 must read-before-write and only touch timers/rules it first owned;
   never clear Rule1 as "free".
3. **`Repeat:0` (one-shot) lives in the manual Timer1/Timer3.** STEES compiles
   `Repeat:1`; Phase 6 verification must not assume all found timers use the
   STEES convention.
4. **Bulk `Timers` shape is firmware-dependent.** Confirmed fine on 15.5.0 but
   per-timer reads remain the robust path (Phase 1 §5).
5. **`Status` readback lands on `STATUS*` topics, not RESULT** — a Phase 6
   detail if identity/firmware verification is needed, not a blocker.
6. **Shared public broker**: 67+ third-party devices publish on
   `broker.emqx.io`; the gateway's handling of RESULT is resilient (drop
   unparseable), and deviceId `34987AC30304` is uniquely owned in the broker
   namespace. Phase 6 must scope all reads/writes to the exact canonical
   deviceId and never use group/broadcast topics.
7. **No NTP/time blockers**: clock is valid; Mode-0 (clock) timers and
   `Clock#Timer` rules will fire deterministically once armed.

## Phase 5 safety confirmation

- **Production code modified: 0** (all backend tests still green, `node
  --check` clean on every touched service).
- **Writes to the device: 0** (queries were empty/status payloads only).
- **`Timer<n>`/`Rule<n>`/`Power` commands: 0.**
- **Existing manual Timer/Rule contents preserved byte-for-byte** (Rule1 54-char
  line, Timer1, Timer3 untouched).
- Full backend suite re-run for this phase: **`# tests 114, # pass 114,
  # fail 0`**.

STOP after Phase 5. No Phase 6 implementation was started.

---

# Phase 6 — Isolated Timer/Rule sync channel + ScheduleSyncService

Status: **implemented and green (off-by-default)**. No live-broker writes were
made; all behavior is exercised through injected fake MQTT clients.

## What was added

- `backend/services/tasmotaConfigClient.js` — isolated Tasmota *configuration*
  request/response channel, fully separate from `mqttGateway.publishCommand()`:
  - **Own MQTT connection + own `stat/<dev>/RESULT` subscription**; never shares
    a message handler or pending registry with the POWER ACK channel.
  - **Correlates replies by expected top-level JSON key** (`Timer1`, `Rule2`,
    etc.) — a POWER-key RESULT or any other payload **never** resolves a config
    request (verified both directions).
  - **Per-device serialized FIFO** (one in-flight config command per device) so
    ambiguous concurrent `Timer`/`Rule` replies cannot cross-resolve; independent
    devices stay independent queues.
  - Bounded timeout, cleanup after timeout/error/disconnect (no orphan promises,
    no leaked timers), `CFG_TIMEOUT`/`CFG_PUBLISH_FAILED`/`MQTT_DISCONNECTED`
    codes. Requires nothing at import time — connection is lazily created on the
    first command.
  - Writes go to `cmnd/<dev>/<Command>` with the arguments **in the payload**
    (never in the topic — matches Phase 5 observation that the real device
    rejects `cmnd/<dev>/Status 0`).
- `backend/services/scheduleSyncService.js` — `syncDevice(deviceId)` pipeline
  `read → compile → allocate → diff → (apply if enabled) → readback verify`:
  - `readDeviceScheduleState` reads all **16 Timers + 3 Rules individually**
    (never bulk `Timers`), normalized with safe fallbacks for missing /
    firmware-variant fields.
  - **Ownership contract (explicit, stable):**
    - Timer3 = user Rule1 trigger → **never managed**.
    - Rule1/Rule3 = user rules → **never written**.
    - Rule2 = STEES-reserved, written **only** when the compiled plan has
      multi-channel events and Rule2 is currently **empty**; if occupied by user
      config → `unsupported` conflict, no overwrite.
    - Managed timer slots are recorded in `device.scheduleSyncInfo
      .managedTimerIndexes` and reused on later syncs (sticky ownership; a
      re-sync doesn't churn to fresh slots once a slot was claimed). Unmanaged
      user timers are never stolen "for room".
  - Compiler timers are **remapped from logical index onto physical slot**
    (respecting ownership) and Rule text is rebuilt with physical slot numbers,
    re-checked against the 511-char budget.
  - **Flag-gated apply**: `TASMOTA_SCHEDULE_SYNC_ENABLED` default `false`. When
    off, `syncDevice` produces `status: 'pending'`, no timer/rule writes, no DB
    write, and `intendedWrites` for preview. When on, only *changed* managed
    resources are published, then **read back and verified**; on verification
    mismatch it retries up to `MAX_SYNC_ATTEMPTS` (3) and returns `failed`
    (never falsely `synced`).
- **Additive hidden model metadata (backward-compatible, `select: false`):**
  - `Device.scheduleSyncInfo` → `{ managedTimerIndexes, status, lastSyncedAt,
    error }`.
  - `Schedule.syncStatus/lastSyncedAt/syncError` → hidden from JSON responses.
  - No existing field, route, engine behavior, or API contract changed.

## Isolation proof (from the test suite)

- Config request resolves only on its expected key; a `POWER1` report on the same
  RESULT topic leaves it pending; a `Timer1` reply leaves a `Rule1` request
  pending.
- A reply for device A never settles a request for device B.
- Non-`stat/<dev>/RESULT` topics are ignored.
- Concurrent same-device requests are serialized (second publishes only after the
  first resolves).
- Verify on retries is deterministic; when readback lies the sync latches
  `failed` after exactly 3 attempts.

## Ownership / safety tests

- `Timer3`/`Rule1`/`Rule3` are never written by `computeWrites` or by
  `syncDevice` with the flag on.
- Rule2 occupied by user content → `unsupported`, zero Rule2 writes.
- No safe managed slot for the plan → `unsupported`, nothing overwritten.
- Device already matching the plan → `synced` with **zero** writes (no-op).
- Flag off → `pending`, zero writes, zero DB updates, `intendedWrites` present.

## Files

- Added: `backend/services/tasmotaConfigClient.js`, `backend/services/
  scheduleSyncService.js`, `backend/test/tasmotaConfigClient.test.js`,
  `backend/test/scheduleSyncService.test.js`.
- Modified (additive only): `backend/models/Device.js`, `backend/models/
  Schedule.js`.
- Untouched and verified: `scheduleEngine.js`, `mqttGateway.js` (POWER ACK
  channel), control routes, LAN fallback, `scheduleCompiler.js`,
  `scheduleSimulator.js`, `scheduleDryRunService.js`, and all Flutter.

## Gates

- `node --check` clean on all new/changed files.
- Full backend suite: **`# tests 140, # pass 140, # fail 0`** (was 114;
  +26 new = 11 config-client + 15 sync-service).
- `git status`: only the two additive model files modified; all other production
  code untouched.

## Notes / deferrals

- The POWER ACK channel and the config channel are intentionally never merged;
  `publishCommand()` remains the sole authority for relay power changes.
- No automatic `syncDevice` invocation from CRUD routes yet; any wiring goes
  behind the default-off flag only.
- Execution responsibility is unchanged: `ScheduleEngine` remains active /
  authoritative; this phase only adds the off-by-default sync capability.

STOP after Phase 6. No shadow mode, no migration, no Flutter, and no automatic
Tasmota execution were introduced.

---

# Phase 6.5 — Development-only manual sync trigger for device 34987AC30304

Status: **implemented and green. No live-broker writes were made — the trigger
is intended to be exercised in two steps: first with
`TASMOTA_SCHEDULE_SYNC_ENABLED=false` (pure dry-run report, zero writes), then
with `TASMOTA_SCHEDULE_SYNC_ENABLED=true` (real apply + readback verification)
only after the operator confirms the dry-run.**

## What was added

- `backend/routes/devSync.js` — `POST /api/dev/sync/:deviceId`:
  - Development-only: mounted by `server.js` only when
    `NODE_ENV !== 'production'`, and the route itself refuses to serve under
    `NODE_ENV=production` (404).
  - Requires the caller to **own** the device (same JWT auth + ownership guard
    as the control routes) before invoking the sync service.
  - Calls `scheduleSyncService.manualSync(deviceId)` (a thin pass-through to the
    existing `syncDevice`) and returns the **full report** as JSON.
- `scheduleSyncService.js` — **report enrichment only, no behavior change to the
  apply path**:
  - `summary.plan` — JSON-safe compiled plan (`timers`, `rules`,
    `requiredTimerCount`).
  - `summary.allocation` — the logical→physical slot allocation chosen.
  - `summary.protected` — protected/unmanaged resources (`Timer3` user Rule1
    trigger, occupied unmanaged timers, user `Rule1`/`Rule3`, and `Rule2` when
    it holds user config).
  - `summary.intendedWrites` — now populated on every path (previously only when
    disabled), `summary.publishedWrites` (empty until a real apply), and
    `summary.verification` — per-resource readback **actual vs desired** with a
    `matches` flag after an enabled sync.
  - New exported helpers: `manualSync`, `protectedResources`, `planView`,
    `allocationView` (all JSON-safe). `Timer3`/`Rule1`/`Rule3` protection and
    the safe-empty-slot-only allocation are unchanged and covered by tests.

## Safety properties preserved

- **ScheduleEngine fully active and unchanged** — no modification to
  `scheduleEngine.js` or any schedule CRUD route.
- **Ownership is unchanged** — only safe empty (or previously STEES-managed)
  slots are ever allocated; user `Timer3`, `Rule1`, `Rule3`, occupied unmanaged
  slots and a user-occupied `Rule2` are reported as protected and never written.
- **Zero writes on dry-run** — with `TASMOTA_SCHEDULE_SYNC_ENABLED=false` the
  report shows `publishedWrites: []` and only empty-payload read commands are
  emitted.
- **Real apply is verified** — after writes the service reads back every
  modified Timer/Rule and reports `actual` vs `desired` per resource; mismatches
  retry up to `MAX_SYNC_ATTEMPTS` and finally latch `status: 'failed'` (never
  falsely `synced`).

## Files

- Added: `backend/routes/devSync.js`, `backend/test/devSyncRoute.test.js`.
- Modified (reporting only): `backend/services/scheduleSyncService.js`,
  `backend/test/scheduleSyncService.test.js`.
- Modified (dev-only mount): `backend/server.js`.
- Untouched and verified: `scheduleEngine.js`, `mqttGateway.js`, all schedule
  CRUD routes, `Device.js`, `Schedule.js`, Flutter, LAN fallback.

## Gates

- `node --check` clean on all changed/new files.
- Full backend suite: **`# tests 150, # pass 150, # fail 0`** (was 140;
  +10 new = +5 sync-service report tests, +5 devSync route tests).
- `git status`: `routes/devSync.js` untracked (new); modified = `server.js`
  (dev-only mount), `scheduleSyncService.js`, and its test file.

## Operator procedure (device 34987AC30304)

1. Run the backend in a non-production environment with
   `TASMOTA_SCHEDULE_SYNC_ENABLED=false`.
2. `POST /api/dev/sync/34987AC30304` (with a valid owner JWT) → confirms the
   compiled plan, chosen safe timer slots, protected resources, intended writes
   and `publishedWrites: []`.
3. Only after confirming step 2, restart the backend with
   `TASMOTA_SCHEDULE_SYNC_ENABLED=true` and run the **exact same** `POST` → the
   report includes the real `publishedWrites`, the full readback `verification`,
   and `status: 'synced'` (or `failed` with the per-resource mismatch).

STOP after Phase 6.5. No shadow mode, no migration, no Flutter, and no automatic
Tasmota execution were introduced.
