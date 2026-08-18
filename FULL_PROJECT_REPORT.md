# STEES — Full Project Report (current state)

**Project:** STEES — Smart Irrigation Controller
**Generated:** 18 Aug 2026
**Scope:** End-to-end IoT system — ESP32 sensor nodes, Tasmota Sonoff relays, Node.js/MQTT/MongoDB backend, and a Flutter Android app with both cloud (MQTT) and LAN (direct HTTP) control.

> This report reflects the **current** state of the `withTasmota` workspace, not any of the historical phase reports (`PROJECT_REPORT.md`, `report.md`, `SYSTEM_REPORT.md`, `HARDENING_PHASE_REPORT.md`, `SCHEDULE_MIGRATION_AUDIT.md`, `CONNECT_DEVICE_REPORT.md`, `UI_UX_REPORT.md`) which document earlier snapshots.

---

## Table of contents

1. [Overview](#1-overview)
2. [Repository layout](#2-repository-layout)
3. [Architecture](#3-architecture)
4. [Firmware](#4-firmware)
5. [Backend](#5-backend)
6. [Flutter app](#6-flutter-app)
7. [MQTT protocol](#7-mqtt-protocol)
8. [REST API reference](#8-rest-api-reference)
9. [Device identity & provisioning](#9-device-identity--provisioning)
10. [Cloud vs LAN control](#10-cloud-vs-lan-control)
11. [Automation: rules, schedules, Tasmota sync](#11-automation-rules-schedules-tasmota-sync)
12. [Security](#12-security)
13. [Testing](#13-testing)
14. [Deployment & environment](#14-deployment--environment)
15. [Recent changes (git history)](#15-recent-changes-git-history)
16. [Known limitations & technical debt](#16-known-limitations--technical-debt)
17. [Getting started](#17-getting-started)

---

## 1. Overview

STEES automates watering based on live soil-moisture readings:

- **ESP32 sensor nodes** read soil moisture (0–100%) and publish over MQTT to `tele/<sensorId>/SENSOR`.
- **Tasmota-based Sonoff relays** (1 or 4 channel) switch irrigation pumps/valves. They are controlled **two ways**:
  - **Cloud path**: backend publishes `cmnd/<deviceId>/POWER<n>` over MQTT; the device ACKs on `stat/<deviceId>/RESULT`.
  - **LAN path**: the phone talks **directly to the relay over HTTP** (`http://<ip>/cm?cmnd=...`), with identity verified by MAC before every use.
- A **Node.js backend** bridges MQTT ↔ REST ↔ Socket.IO ↔ MongoDB: sensor ingestion, relay state tracking, liveness (LWT), a rule engine (sensor-threshold automation) and a schedule engine (time-window automation).
- A **Flutter Android app** provides the UI: device grid with animated water cards, sensor cards, schedules, rules, and an in-app **3-step device provisioning wizard** that configures a fresh Tasmota device over its own Wi-Fi access point.

Two control directions are supported:
- App → relay (cloud MQTT, or LAN HTTP fallback when the cloud is proven down).
- Relay → app (physical toggle is reflected live via MQTT `RESULT`/`STATE` → Socket.IO `device_update`, or via direct LAN status reads).

---

## 2. Repository layout

| Path | Role |
|---|---|
| `backend/` | Node.js/Express backend (routes, models, services, tests, simulators) |
| `firmware/` | ESP32 Arduino sketches (`esp32_sensor_node.ino`, `esp32_soil_sensor_mqtt.ino`) |
| `flutter_app/` | Flutter Android app (`smart_home_app`) |
| `dashboard.html` | Standalone single-file web dashboard (MQTT-over-WSS + Socket.IO) |
| `virtual_sonoff.js` | Minimal HTTP-only virtual Sonoff 4CH (no MQTT) |
| `*.md` | Phase/audit reports from earlier development snapshots |
| `.gitignore` | Ignores `node_modules/`, `.env` |

---

## 3. Architecture

```
┌─────────────┐   MQTT (public broker broker.emqx.io:1883)   ┌──────────────────────────────┐
│  ESP32 node │   tele/<SENSOR_ID>/SENSOR {"value":42}        │   Backend (Node.js, :3001)   │
│  (soil/PIR) │ ────────────────────────────────────────────▶ │  mqttGateway (MQTT gateway)  │
└─────────────┘                                               │  ruleEngine (10 s tick)      │
┌─────────────┐   stat/<id>/RESULT, tele/<id>/STATE, LWT      │  scheduleEngine (30 s tick)  │
│ Tasmota     │ ◀──────────────────────────────────────────── │  runtimeState (in-memory)    │
│ Sonoff 1/4CH│   cmnd/<id>/POWER<n> ON|OFF                   │  deviceRegistry (claimed)    │
└─────────────┘                                               │  scheduleSyncService (opt)   │
       ▲                                                      │  tasmotaConfigClient         │
       │  LAN path: http://<ip>/cm?cmnd=... (SetOption128)    └──────┬───────────────┬───────┘
       │  MAC-verified via Status 5 (phone ↔ relay directly)         │ REST (JWT)    │ Socket.IO
       ▼                                                             ▼               ▼
┌─────────────┐                                             ┌──────────────────────────────┐
│ Flutter app │                                             │ MongoDB Atlas                │
│ (Android)   │  ── cloud-first, LAN-fallback control ───▶ │ User, Device, Sensor,        │
└─────────────┘                                             │ Rule, Schedule               │
                                                           └──────────────────────────────┘
```

**Data flow in short:**
- Sensor → MQTT `tele/<sensorId>/SENSOR` → gateway updates `Sensor.lastValue` in MongoDB + in-memory cache → Socket.IO `sensor_update` to the owning user's room.
- Relay state → MQTT `RESULT`/`STATE`/`LWT` → gateway updates `runtimeState` → `device_update`/`device_status` Socket.IO events.
- App control → `POST /api/control` → `cmnd/<id>/POWER<n>` → relay → `RESULT` ACK resolves the pending promise (5 s timeout) → `device_update` back to the app.
- Rules → 10 s tick, edge-triggered threshold compares → MQTT command.
- Schedules → 30 s tick, timezone-aware (Luxon, `Africa/Algiers` default) → MQTT command on window boundaries.
- (Optional, off-by-default) schedules compiled into native Tasmota `Timer<n>`/`Rule2` configs and synced to the device.

---

## 4. Firmware

### `firmware/esp32_sensor_node.ino` (95 lines)
- Minimal MQTT publisher. Reads soil moisture on analog pin 34 (12-bit), maps raw ADC `map(raw, DRY=3000, WET=1200, 0, 100)`, clamps 0–100.
- Publishes `{"value":<pct>}` to `tele/soil_1/SENSOR` every 10 s.
- WiFi/MQTT auto-reconnect; client ID = ESP32 MAC. Broker `broker.emqx.io:1883`, no credentials.
- Config placeholders: `WIFI_SSID`, `WIFI_PASSWORD`, `SENSOR_ID`, `SENSOR_PIN`, `SENSOR_DRY/WET`.

### `firmware/esp32_soil_sensor_mqtt.ino` (426 lines)
- ESP32-S3 dual-mode device: **AP + STA**, built-in French web dashboard (port 80, `/` + `/data` JSON) plus MQTT publishing and optional relay control.
- Publishes `tele/<DEVICE_ID>/SENSOR` (`{"Time":..., "soil_1":42}`) and `tele/<DEVICE_ID>/STATE` (`{"POWER1".."POWER4"}`) every 10 s.
- Subscribes `cmnd/<DEVICE_ID>/#`; handles `POWER1` ON/OFF/TOGGLE on GPIO25 (relay, `-1` disables) and ACKs on `stat/<DEVICE_ID>/RESULT`.
- Same calibration math as the node sketch. Config placeholders marked `A PERSONNALISER` / `A CALIBRER`.

---

## 5. Backend

Stack: Express 4, Mongoose 8, mqtt.js v5, Socket.IO 4, jsonwebtoken, bcryptjs, Luxon, bonjour. Tests via Node's built-in `node:test`.

### 5.1 Entry point — `server.js`
- Express + Socket.IO bootstrap, MongoDB connect (non-fatal on failure), service init, route mounting.
- **Socket.IO auth**: every socket authenticates with the same JWT from the handshake `auth` field; each socket joins `user:<userId>` so events reach only that user's clients.
- `provision_watch` socket event: an authenticated client may join `provision:<mac>` to get a fast `device_seen` wake-up; joining is gated on not being owned by another account.
- `GET /api/health` and `GET /api/mqtt/snapshot` are unauthenticated debug endpoints.
- DevSync routes (`/api/dev`) mounted only when `NODE_ENV !== 'production'` or `ENABLE_SCHEDULE_SYNC_ROUTE=true`.
- After the DB loads, the registry requests current `STATE` from every claimed device (`requestStateSync`) so runtime state recovers fast.

### 5.2 Routes

| Route file | Endpoints |
|---|---|
| `routes/auth.js` | `POST /api/auth/signup`, `POST /api/auth/login` (public) |
| `routes/devices.js` | `GET /api/devices`, `POST /api/devices/provision`, `GET /api/devices/seen`, `GET /api/devices/check`, `POST /api/devices/unclaim`, `DELETE /api/devices/:deviceId`, `POST /api/devices/:deviceId/mqtt-command` |
| `routes/control.js` | `POST /api/control`, `GET /api/status?deviceId=` |
| `routes/sensors.js` | `GET/POST /api/sensors`, `DELETE /api/sensors/:sensorId` |
| `routes/rules.js` | `GET/POST /api/rules`, `PATCH /api/rules/:id`, `PATCH /api/rules/:id/enable`, `DELETE /api/rules/:id` |
| `routes/schedules.js` | `GET/POST /api/schedules`, `PATCH /api/schedules/:id`, `PATCH /api/schedules/:id/enable`, `DELETE /api/schedules/:id` (each CRUD fire-and-forget triggers a device sync via `scheduleSyncTrigger`) |
| `routes/devSync.js` | `POST /api/dev/sync/:deviceId` (dev-only, ownership-guarded) |

### 5.3 Models (MongoDB/Mongoose)

- **User** — `username` (unique, lowercase, 3–30), `password` (bcrypt, min 6), `createdAt`; toJSON strips password + `__v`.
- **Device** — `deviceId` (unique; **canonical Tasmota MAC** — never rewritten after creation), `name` (max 50), `ownerId`, `type` (`sonoff-4ch` default), `channels` (**1–32**, default 4), `claimedAt`, `lastIp` (LAN hint from telemetry, IP-validated), `hardwareId` (legacy compat), `scheduleSyncInfo` (`select:false`, owned by the sync service). toJSON strips `__v`.
- **Sensor** — `ownerId`, `name`, `sensorId` (**global unique index** — MQTT ingestion looks up by `sensorId` only), `deviceId`, `lastValue` (Mixed), `lastSeen`. No persisted status; online/offline derived from `lastSeen`.
- **Rule** — `ownerId`, `name`, `sensorId`, `deviceId`, `channels: [Number]` (validated non-empty ints, no dupes), `condition` (`above`/`below`), `threshold`, `action` (`ON`/`OFF`), `enabled` (default true), `lastConditionState` (persisted edge-trigger state). Legacy single `channel` auto-migrated to `channels`.
- **Schedule** — `ownerId`, `name`, `deviceId`, `channels`, `recurrence: {type: daily|custom, daysOfWeek 0=Mon..6=Sun}`, `timeRanges: [{start, end}]` (**same-day only**, end > start), `enabled`, `lastAppliedState` (hidden), hidden sync metadata (`syncStatus`, `lastSyncedAt`, `syncError`).

### 5.4 Services

| Service | Responsibility |
|---|---|
| `mqttGateway.js` | All device MQTT traffic. Subscribes `stat/+/RESULT`, `tele/+/STATE`, `tele/+/LWT` (qos1) and `tele/+/SENSOR` (qos0). ACK-based `publishCommand` (5 s timeout, same device+channel supersede), `publishCommandNoWait`, `publishTasmotaCommand`. `powerUpdatesFrom` normalizes `POWER1..n` and bare `POWER`→channel 1. LWT offline is authoritative. Sensor cache + owner cache for live verification. `hasRecent(mac)` possession gate. Bounded pruning of transient maps. `requestStateSync()`/`For()` read-only recovery. LAN IP recording (rejects `0.0.0.0`, loopback, multicast). |
| `deviceRegistry.js` | In-memory map of claimed devices (loaded from DB at startup). |
| `runtimeState.js` | Per-device channel states + online verdict. `freshMs` default 5 min (`DEVICE_FRESH_MS`). LWT offline latches until a positive report. Never fabricates `OFF`. |
| `deviceProvisioningService.js` | MAC-based provisioning: normalize MAC → validate → conflict check → **possession gate** (`hasRecent`) → create/reclaim legacy row → warm runtimeState → `requestStateSyncFor`. Ownership of another account never disclosed. |
| `macIdentity.js` | `normalizeMac()` — 12 uppercase hex chars, strips `:`/`-`/space; deterministic canonical identity. |
| `ipValidation.js` | `classifyIp()` — rejects unspecified/loopback/multicast before persisting `lastIp`. |
| `ruleEngine.js` | 10 s tick; edge-triggered threshold automation; persists `lastConditionState`; `oppositeAction` for the else-branch; `invalidate(id)`. |
| `scheduleEngine.js` | 30 s tick; timezone-aware (Luxon, `APP_TIMEZONE` default `Africa/Algiers`); publishes only on state change; `release()` reverts channels on disable/delete; offline skip logged once/minute. |
| `scheduleCompiler.js` | Pure compiler → Tasmota `Timer<n>` + optional `Rule1` clauses. `MAX_TIMERS=16`, `MAX_RULE_LENGTH=511`; `daysMask` uses SMTWTFS order with `pos=(steesDay+1)%7`. |
| `scheduleSimulator.js` | Pure simulator of a compiled plan (mirrors Tasmota firmware behavior) for parity testing. |
| `scheduleDryRunService.js` | Dry-run/compile report + 7-day × 15-probe parity sampling; ON-wins reference state. |
| `scheduleSyncService.js` | Read → compile → allocate → diff → apply → verify pipeline (flag-gated, see §11). Ownership contract: Timer3/Rule1/Rule3 never touched; Rule2 STEES-reserved. Per-device serialization. |
| `scheduleSyncTrigger.js` | Fire-and-forget CRUD integration with per-device coalescing (in-flight sync + one follow-up). |
| `tasmotaConfigClient.js` | Isolated request/response MQTT channel for config commands (`Timer<n>`, `Rule<n>`), fully separate from the POWER ACK channel; per-device FIFO; key-correlated replies; lazy connection. |
| `timeline.js` | Debug end-to-end command timeline (monotonic ms), disabled with `DISABLE_CONTROL_TIMELINE=1`. |

### 5.5 Simulators & scripts
- `virtual_mqtt_device.js` — full MQTT virtual Tasmota 4CH + a sine-wave soil sensor (`npm run virtual`).
- `mock_tasmota.js` — HTTP-only mock Tasmota (`GET /cm?cmnd=...`, handles `Status`, `Power<n>`, advertises bonjour `_tasmota._tcp`) for LAN-path testing.
- `seed.js` — upserts 3 demo devices into MongoDB.

---

## 6. Flutter app

Flutter (`smart_home_app`, SDK `^3.12.1`, Material 3). Dependencies: `http`, `socket_io_client`, `flutter_secure_storage`, `google_fonts`, `shared_preferences`, `url_launcher`, `bonsoir` (mDNS LAN discovery).

### 6.1 Screens (`lib/screens/`, 14 files)
- `main_shell.dart` — 4-tab shell (Devices, Sensors, Schedules, Rules), global 401→logout hook, tab badge counts.
- `devices_page.dart` (~1860 lines) — core control UI. Socket.IO monitor (JWT-authed), 5 s health probe with 2-failure cloud-down detection, water-card relay grid with ripple animation + FLOWING/DRY/SYNCING/OFFLINE pills, optimistic taps + haptic, stale-report protection, progressive load from cached list.
- `provision_device_screen.dart` (~2800 lines) — the 3-step provisioning wizard (§9).
- `add_device_screen.dart` — wizard entry point (no manual ID form).
- `login_screen.dart`, `signup_screen.dart` — JWT auth.
- `sensors_page.dart`, `add_sensor_screen.dart` — sensor list + verified add.
- `schedules_page.dart`, `schedule_list_screen.dart`, `schedule_form_screen.dart` — schedule CRUD with `WindowTimeline` preview.
- `rules_page.dart`, `sensor_rules_screen.dart`, `rule_form_screen.dart` — rule CRUD (device auto-derived from the sensor; channel bound by device count).

### 6.2 Services (`lib/services/`, 11 files)
- `api_service.dart` — REST client, `kBaseUrl`, 15 s timeout, classified `ApiException` (`TIMEOUT`/`NETWORK_ERROR`), global 401 hook, preflight decision logic.
- `auth_service.dart` — secure storage of JWT + username.
- `cloud_device_transport.dart` — cloud transport (documented primary).
- `local_device_transport.dart` (~646 lines) — LAN transport: `/cm` HTTP with 2 s timeouts, HTTP Basic auth, optional Referer, `Status 5` MAC identity gate, read-back confirm (`UNCONFIRMED` on mismatch), `SetOption128 1` enable, state parsing.
- `device_repository_service.dart` (~976 lines) — the cloud↔LAN orchestrator: **cloud-first control, LAN fallback only on proven cloud unavailability; status reads local-first**; logical rejections never reroute; discovery ladder (warm endpoint → verified-IP cache → mDNS), single-flight discovery, DHCP self-heal.
- `local_device_cache.dart` — SharedPreferences mirror (display metadata only).
- `local_device_discovery.dart` — cached IP + bonsoir mDNS browse (`_tasmota._tcp`).
- `local_ip.dart` — endpoint/IP validation helpers.
- `provisioning_service.dart` — 21-state provisioning machine, Wi-Fi test classification (`WifiTest3`), MAC normalization, delete outcome classification.
- `control_timeline.dart` — opId generator + debug timeline.

### 6.3 Theme (`lib/theme/`)
Light and dark Material-3 themes with a full `SteesColors` theme-extension token set (dark `well` `#0F141A`, `stream` `#4A8B84`, `leaf` `#7FBF97`; light mirror), `AppSpacing`/`AppRadius`/`AppShadows` design tokens, `ThemeController` persisting the mode in SharedPreferences.

### 6.4 Android native (`MainActivity.kt`)
Two method channels:
- `stees/wifi_settings` — `openWifiSettings`, `scanWifi` (passive scan + 1200 ms delayed read; runtime location permission on M+/Q+).
- `stees/wifi_binding` — `ensureBoundToActiveWifi` (binds process sockets to the currently active network, wildcard SSID match for `tasmota-XXXX`), `getNetworkInfo`, `releaseWifiBinding`.

Manifest permissions: INTERNET, ACCESS_NETWORK_STATE, CHANGE_NETWORK_STATE, ACCESS_WIFI_STATE, CHANGE_WIFI_MULTICAST_STATE (mDNS), COARSE/FINE location (Wi-Fi scan), NEARBY_WIFI_DEVICES. `network_security_config.xml` allows cleartext (LAN IPs are DHCP-assigned and only known at runtime) while the production backend stays HTTPS.

---

## 7. MQTT protocol

| Direction | Topic | Payload | Meaning |
|---|---|---|---|
| Sensor → | `tele/<sensorId>/SENSOR` | `{"value":42}` | Soil moisture reading |
| Backend → | `cmnd/<deviceId>/POWER<n>` | `ON`/`OFF`/`TOGGLE` | Command a relay channel |
| Device → | `stat/<deviceId>/RESULT` | `{"POWER1":"ON"}` | ACK/state after command |
| Device → | `tele/<deviceId>/STATE` | `{"POWER1":"ON",...}` | Periodic full state (+ `IPAddress`) |
| Device → | `tele/<deviceId>/LWT` | `Online`/`Offline` | Liveness (birth/will) |
| Backend → | `cmnd/<deviceId>/State` | (empty) | Read-only state sync request |
| Backend → | `cmnd/<deviceId>/SetOption128 1` | (empty) | Enable HTTP API (LAN path) |
| Backend → | `cmnd/<deviceId>/Timer<n>` / `Rule<n>` | JSON / empty | Schedule-sync config reads/writes |

Gateway subscriptions: `stat/+/RESULT`, `tele/+/STATE`, `tele/+/LWT` (qos1), `tele/+/SENSOR` (qos0). The `tasmotaConfigClient` adds its own per-device `stat/<id>/RESULT` subscription.

**Single-relay normalization:** a bare `POWER` value maps to channel 1 whenever no numbered `POWERn` keys are present, so 1-relay devices work regardless of stored channel count.

**ACK protocol:** `publishCommand` registers a pending key `deviceId:channel`, and resolves only when the RESULT value matches the expected state (TOGGLE resolves on any ON/OFF). Timeout 5 s (`ACK_TIMEOUT`). A concurrent command on the same device+channel supersedes the older one (`SUPERSEDED`). Pending ACKs are correlated with the app via an `opId` echoed on the `device_update` socket event.

---

## 8. REST API reference

Auth: `Authorization: Bearer <JWT>` on everything except `/api/auth/*`, `/api/health`, `/api/mqtt/snapshot`.

| Method | Path | Body/Query | Notes |
|---|---|---|---|
| POST | `/api/auth/signup` | `{username, password}` | 201 `{token, user}`; username ≥3, password ≥6; duplicate → 409 |
| POST | `/api/auth/login` | `{username, password}` | `{token, user}`; uniform 401 on failure |
| GET | `/api/devices` | – | User's devices |
| POST | `/api/devices/provision` | `{deviceId (MAC), name, channels}` | Possession-gated; 409 on duplicate/not-seen; `DEVICE_NOT_SEEN` etc. mapped codes |
| GET | `/api/devices/seen` | `?deviceId=` | `{seen}` — possession hint |
| GET | `/api/devices/check` | `?deviceId=` | `{status: mine\|others\|not_found}` — non-authoritative UX pre-check |
| POST | `/api/devices/unclaim` | `{deviceId}` | Release ownership |
| DELETE | `/api/devices/:deviceId` | – | Cascades sensors + rules + schedules (with relay release) |
| POST | `/api/devices/:deviceId/mqtt-command` | `{command}` | Arbitrary Tasmota command over MQTT (no ACK wait) |
| POST | `/api/control` | `{deviceId, channel, state, opId?}` | ON/OFF/TOGGLE; 404/403/400/409(offline)/503(mqtt down); errors: `ACK_TIMEOUT`→504, `SUPERSEDED`→409, MQTT down→503 |
| GET | `/api/status` | `?deviceId=` | `channels` map (+ legacy flat `POWERn`), `online`, `lastIp`; never fabricates OFF |
| GET | `/api/sensors` | – | Derived `status` (online within 5 min) |
| POST | `/api/sensors` | `{name, sensorId, deviceId}` | **Live-verified** via MQTT cache (15 s); 404 if no fresh reading; 409 duplicate |
| DELETE | `/api/sensors/:sensorId` | – | Deletes its rules too |
| GET | `/api/rules` | – | Includes `sensorName`/`deviceName` |
| POST | `/api/rules` | `{name, sensorId, channels, condition, threshold, action}` | One rule per sensor; channels bounded by device |
| PATCH | `/api/rules/:id` | partial | Updates + engine invalidate |
| PATCH | `/api/rules/:id/enable` | – | Toggle |
| DELETE | `/api/rules/:id` | – | Delete |
| GET | `/api/schedules` | – | Includes `deviceName` |
| POST | `/api/schedules` | `{name, deviceId, channels, recurrence, timeRanges}` | Validated same-day; triggers device sync |
| PATCH | `/api/schedules/:id` | partial | Resets `lastAppliedState`; engine invalidate; sync trigger |
| PATCH | `/api/schedules/:id/enable` | – | On disable, `release()` reverts held-ON channels |
| DELETE | `/api/schedules/:id` | – | Best-effort release + delete + sync trigger |
| GET | `/api/health` | – | `status`, `mqtt`, `db`, `claimedDevices`, `seenOnMqtt` (no auth) |
| GET | `/api/mqtt/snapshot` | – | Sensor cache + claimed devices (no auth, debug) |
| POST | `/api/dev/sync/:deviceId` | – | Dev-only manual schedule sync trigger (full report) |

---

## 9. Device identity & provisioning

### Identity model
The **canonical identity everywhere is the Tasmota MAC** (12 uppercase hex, `normalizeMac`), which doubles as the MQTT topic and the `deviceId`. It is:
- read from the physical device (`Status 5`) during provisioning,
- used as the MQTT `Topic` written to the device,
- the possession gate (`hasRecent(mac)`) for claiming,
- re-verified before every LAN use.

### Provisioning wizard (in-app, 3 steps)
1. **Connect** — user joins the device AP (`tasmota-XXXX`); the app binds sockets to the active Wi-Fi network (`stees/wifi_binding`), probes `http://192.168.4.1` until reachable, reads the MAC via `Status 5`. A specific error is shown if the phone is on a network with internet (router) instead of the AP.
2. **Configure** — the app writes, via `/cm?cmnd=Backlog ...`: MQTT broker (MqttHost/Port/User/Password) → `Topic`/`FullTopic` (each standalone — restart-prone, never bundled into the broker Backlog) → `DeviceName` → **WifiTest3 pre-flight** (test without persisting/restarting) → `SSId1`/`Password1` → read-back verify → `Restart 1`. Config write order is MQTT-first, Wi-Fi-second, restart-last so settings survive the network switch.
3. **Wait** — poll `GET /api/devices/seen` (authoritative) up to 6 min + Socket.IO `device_seen` fast path (room `provision:<mac>`); then `POST /api/devices/provision` (possession-gated), local cache upsert, background `SetOption128 1` (enable HTTP API for LAN control).

---

## 10. Cloud vs LAN control

The app supports two control paths; `device_repository_service.dart` is the single orchestrator the UI uses.

- **Relay control = cloud-first**: a tap goes to MQTT immediately; the LAN is the fallback **only when the cloud is genuinely unavailable** (`isAvailabilityFailure` — no status code, 5xx, or an uncoded 409 "device offline"). Logical rejections (identity mismatch, unconfirmed command, 4xx, coded 409) are never rerouted.
- **Status reads = local-first**: the device's own HTTP endpoint is the freshest truth.
- `cloudDown=true` inverts to local-first with a fast cached-IP-only path (400 ms, never mDNS) so cloud fallback is immediate; the cloud remains the safety fallback.
- **Discovery ladder** for the LAN: warm in-memory endpoint → persisted verified-IP cache (10 min TTL, re-verified) → mDNS (`bonsoir`, `_tasmota._tcp`). Every endpoint is MAC-verified (`Status 5`) before use; foreign IPs are discarded.
- `enableLocalHttpApi()` — after claiming, the app enables Tasmota's HTTP API (`SetOption128 1`) via a Referer-matching bootstrap so pre-setup devices accept it, then verifies.
- **Local mode can only display/control already-registered devices** — it can never add, claim, or unclaim.

---

## 11. Automation: rules, schedules, Tasmota sync

### Rules (sensor-threshold)
Every 10 s the rule engine evaluates enabled rules: sensor `lastValue` vs `threshold` (`above`/`below`). Edge-triggered (false→true), state persisted in `lastConditionState`, and re-publish is suppressed while the desired action is unchanged. Offline devices are skipped without flipping edge state, so rules retry when the device returns. The "else" branch sends `oppositeAction` (ON↔OFF).

### Schedules (time-window)
Every 30 s the schedule engine evaluates enabled schedules against the current time (Luxon, `APP_TIMEZONE` default `Africa/Algiers`), computing `_desiredState` (half-open `[start, end)`, ON-wins per channel across schedules). Publishes only on change; tracks `lastAppliedState`; `release()` reverts channels to OFF on disable/delete. Days: `0=Mon..6=Sun`. Overnight ranges are rejected (same-day only).

### Schedule → Tasmota native sync (off by default)
A pipeline (`scheduleCompiler` → `scheduleSimulator` → `scheduleDryRunService` → `scheduleSyncService`) can compile STEES schedules into native Tasmota `Timer<n>` configs (+ a `Rule2` clause for multi-channel events) and sync them onto the device over an **isolated request/response channel** (`tasmotaConfigClient`), with read-back verification and up to 3 retry attempts.

- **Ownership contract:** Timer3 (user Rule1 trigger) is never managed; Rule1/Rule3 are user rules, never written; Rule2 is STEES-reserved and only written when empty or identical (else reported as an unsupported conflict); only empty or previously-STEES-managed timer slots are allocated (sticky ownership).
- **Gates:** `TASMOTA_SCHEDULE_SYNC_ENABLED` (default `false`) controls any write; CRUD integration via `scheduleSyncTrigger` (per-device coalescing, never breaks the CRUD response); dev-only manual trigger `POST /api/dev/sync/:deviceId` returns a full dry-run/report.
- **Parity evidence:** 4655 deterministic + 10000 randomized simulated timestamps compared against the real `scheduleEngine._desiredState()` with **0 mismatches**.

---

## 12. Security

- Passwords bcrypt-hashed (10 rounds); JWT 30-day expiry (`JWT_EXPIRES_IN`); all data routes behind `authMiddleware`.
- Ownership enforced per route; another account's device ownership is never disclosed (generic errors, `not_authorized` on watch).
- `Sensor.sensorId` globally unique; `deviceId` unique.
- Provisioning is **possession-gated** by `hasRecent(mac)` (device must announce itself on the broker) — not a claimable name/token.
- LAN transport: MAC identity verified before every command; read-back confirmation; no credentials in logs; cleartext HTTP restricted at the OS config level.
- LWT-offline is authoritative; stale/unspecified IPs (`0.0.0.0`, loopback, multicast) never persisted.
- **Caveats:** `JWT_SECRET` falls back to a dev string unless set; `/api/mqtt/snapshot` and `/api/health` are intentionally unauthenticated; the `.env.example` still references the old HiveMQ Cloud broker/credentials and an old `MONGO_URI`/`JWT_SECRET` sample — rotate real secrets (see §14).

---

## 13. Testing

### Backend — `node --test test/` (16 files, **194 tests**)
Covers: auth middleware, device provisioning (MAC/possession/legacy/concurrency), MQTT ACK flow (supersede/timeout/disconnect), LWT liveness, IP recording/validation, control route shapes, status/UNKNOWN defaults, rules, schedule compiler (limits, day masks, merging), schedule sync service (ownership, flag-gating, verification/retries, serialization), config client isolation (key correlation, per-device FIFO, timeouts), devSync route, schedule parity (compiler vs engine), runtime state.

### Flutter — `flutter test` (11 files, **260+ test declarations**)
Covers: transport failure classification, Status-5 identity parsing, relay command + read-back confirm, bounded timeouts, referer semantics, endpoint normalization, repository orchestration (cloud-first/fallback/never-reroute, discovery ladder, DHCP self-heal, `enableLocalHttpApi` cases), local cache/discovery/mac normalization, Wi-Fi test classification, provisioning remove-device terminal states, `SteesError` widget, app smoke test.

Earlier hardening runs reported: `flutter analyze` clean, debug APK builds, backend `node --check` clean.

---

## 14. Deployment & environment

| Item | Value |
|---|---|
| Live backend | `https://sonoff-3na2.onrender.com` (Render, auto-deploy from `github.com/Raouf2003/sonoff` on push) |
| MQTT broker (prod) | Public `broker.emqx.io:1883` (log-confirmed), no auth |
| Database | MongoDB Atlas (`MONGO_URI` in env) |
| Repo | `withTasmota` — 126 commits, branch `main` |
| Backend deps | express, mongoose, mqtt, socket.io, socket.io-client, jsonwebtoken, bcryptjs, cors, bonjour, luxon |
| App deps | http, socket_io_client, flutter_secure_storage, google_fonts, shared_preferences, url_launcher, bonsoir |

**Key env vars** (backend): `MQTT_BROKER_URL`, `MQTT_USERNAME`, `MQTT_PASSWORD`, `MONGO_URI`, `JWT_SECRET`, `JWT_EXPIRES_IN` (default `30d`), `PORT` (3001), `CORS_ORIGIN` (`*`), `NODE_ENV`, `APP_TIMEZONE` (`Africa/Algiers`), `DEVICE_FRESH_MS` (`300000`), `TASMOTA_SCHEDULE_SYNC_ENABLED` (`false`), `ENABLE_SCHEDULE_SYNC_ROUTE`, `DISABLE_CONTROL_TIMELINE`. `backend/.env` and `backend/.env.example` both exist (`.env` is git-ignored).

**Live log evidence** (`server.out.log`): ruleEngine 10 s, scheduleEngine 30 s in `Africa/Algiers`, MongoDB connected, 1 claimed device loaded, MQTT connected to `mqtt://broker.emqx.io:1883`, continuous broker discovery of third-party Tasmota devices (expected noise on the shared public broker).

---

## 15. Recent changes (git history)

Most recent commits (newest first):
- `loc fix` ×7 / `local fix` ×2 — LAN/local-control refinement commits.
- `fix: simplify MQTT ACK flow and prevent duplicate state updates` ×2 — the ACK/supersede protocol of §7.
- `improve delay off/on` (+v2) ×5 — tap latency / optimistic UI tuning on the devices page.
- `after tasmota timer` ×5 — schedule-sync phase work.
- `Auto-sync Tasmota schedules on CRUD via per-device coalescing trigger` — `scheduleSyncTrigger` integration.
- `Wait for lazy config MQTT connection instead of failing early` — config client robustness.
- `Allow dev sync route in production only when ENABLE_SCHEDULE_SYNC_ROUTE=true` ×2 — production guard for `/api/dev/sync`.
- Earlier: `after Wifi` ×4, `Add sonsores` (2026-08-02) — the Wi-Fi-bind/provisioning and web-dashboard history.

---

## 16. Known limitations & technical debt

1. **Shared public broker noise** — on `broker.emqx.io` the gateway observes thousands of third-party devices; only claimed devices and known sensors are acted on, but logs/snapshot are noisy.
2. **`isOnline` freshness window** — `DEVICE_FRESH_MS` default 5 min vs Tasmota `TelePeriod` 300 s: a device can be judged offline between telemetry bursts if LWT hasn't latched (mitigated by LWT + requestStateSync).
3. **No persisted liveness** — `runtimeState` is in-memory; a restart re-derives it from the next telemetry/LWT/State sync.
4. **Credentials in env files/history** — rotate Mongo Atlas and broker credentials; `JWT_SECRET` still has a dev fallback.
5. **`scheduleCompiler` limits** — max 16 Tasmota timers, 511-char Rule text; larger plans reported as unsupported/conflict.
6. **Schedules are same-day only** — overnight/inverted ranges rejected by schema.
7. **Tasmota sync is off by default** — real-device write-path still needs a hardware-approved run; the provisioning `WifiTest3` verdict strings across all firmware variants aren't fully exhausted.
8. **Legacy singular `channel`** migration path is effectively dead code but not cleaned up.
9. **No refresh-token flow** — 401→logout is the only client-side session handling.
10. **Inconsistent broker docs** — `.env.example` still references HiveMQ Cloud while production uses `broker.emqx.io`.

---

## 17. Getting started

```bash
# Backend
cd backend
npm install
# set MONGO_URI, MQTT_BROKER_URL, JWT_SECRET (see .env.example)
npm start            # or: npm run virtual  (full MQTT simulator)

# Backend tests
npm test

# Flutter app
cd flutter_app
flutter pub get
flutter run -d <device>      # API base: https://sonoff-3na2.onrender.com (api_service.dart)
flutter test

# Firmware
# open firmware/esp32_sensor_node.ino in Arduino IDE; set WiFi + sensor ID; flash ESP32
# (or esp32_soil_sensor_mqtt.ino for the AP+web+relay variant)
```

*Generated from the current state of the `withTasmota` workspace.*
