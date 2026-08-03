# STEES — Smart Irrigation System: Full Project Report

**Project:** STEES (Smart Irrigation Controller)
**Date:** 03 Aug 2026
**Scope:** End-to-end IoT system — ESP32 sensor nodes, Tasmota Sonoff relays, Node.js backend with MQTT, MongoDB, and a Flutter Android app.

---

## Table of contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [System components](#3-system-components)
4. [MQTT protocol](#4-mqtt-protocol)
5. [Backend API reference](#5-backend-api-reference)
6. [Key data flows](#6-key-data-flows)
7. [Data model](#7-data-model)
8. [Security](#8-security)
9. [Deployment & environment](#9-deployment--environment)
10. [Recent changes & design decisions](#10-recent-changes--design-decisions)
11. [Known limitations](#11-known-limitations)
12. [Getting started / local dev](#12-getting-started--local-dev)

---

## 1. Overview

STEES is a smart irrigation system that automates watering based on live soil-moisture readings:

- **ESP32 sensor nodes** measure soil moisture (0–100%) and publish readings over MQTT.
- **Tasmota-based Sonoff relays** (1-relay or 4-relay) switch the irrigation pumps/valves.
- A **Node.js backend** bridges MQTT ↔ REST ↔ Socket.IO ↔ MongoDB, verifies sensors, runs an automation rule engine, and tracks device liveness.
- A **Flutter Android app** gives the user a polished UI to manage devices, sensors, and automation rules, with real-time state.

The system supports **two directions of control**:
- App → physical relay (turn channels ON/OFF).
- Physical relay → app (reverse effect: a manual toggle updates the app instantly).

---

## 2. Architecture

```
┌─────────────┐  MQTT over TCP  ┌──────────────────────────────┐
│  ESP32 node  │  (public broker) │      Backend (Node.js)       │
│  soil/PIR    │  tele/…/SENSOR  │ ┌──────────────────────────┐ │
│  (firmware)  │ ───────────────▶ │ │  mqttGateway             │ │
└─────────────┘                    │ │  · subscribe/handle msgs │ │
                                   │ │  · sensor cache (RAM)    │ │
┌─────────────┐  stat/…/RESULT    │ │  · runtime device state  │ │
│ Tasmota     │  tele/…/STATE     │ │  · Socket.IO emit        │ │
│ Sonoff 1/4CH│  tele/…/LWT       │ ├──────────────────────────┤ │
│             │ ◀── cmnd/…/POWERn │ │  ruleEngine (every 10 s) │ │
└─────────────┘   ON | OFF        │ ├──────────────────────────┤ │
                                   │ │  REST API (Express)     │ │
                                   │ └───────────┬──────────────┘ │
                                   └─────────────┼────────────────┘
                                                 │ JWT auth (REST)
                                                 │ Socket.IO (live)
                                                 ▼
                                        ┌───────────────────┐
                                        │  MongoDB (Atlas)   │
                                        └───────────────────┘
                                        ┌───────────────────┐
                                        │  Flutter app       │
                                        │  (Android)         │
                                        └───────────────────┘
```

---

## 3. System components

### 3.1 Firmware — `firmware/esp32_sensor_node.ino`

A minimal ESP32 Arduino sketch using `PubSubClient`:

- Reads soil moisture via `analogRead(34)`, maps raw ADC to a percentage:
  `map(raw, DRY=3000, WET=1200, 0, 100)` clamped to 0–100.
- Publishes every 10 s to `tele/<SENSOR_ID>/SENSOR` with payload `{"value":42}`.
- The **sensor ID lives in the MQTT topic**, not the payload.
- Config placeholders: WiFi SSID/password, `MQTT_HOST=broker.emqx.io:1883`, `SENSOR_ID="soil_1"`, `SENSOR_PIN=34`.
- Auto-reconnects WiFi and MQTT; uses the ESP32 MAC as MQTT client ID.

### 3.2 Sonoff relays (Tasmota)

- **4-relay** controller (e.g. Sonoff 4CH Pro R3): reports `POWER1`..`POWER4`.
- **1-relay** controller (e.g. Sonoff Basic/R3): reports a bare `POWER` key (no number) and `stat/<id>/POWER` topics.
- Both publish `tele/<id>/STATE` periodically and `stat/<id>/RESULT` after each command.
- Liveness is signalled via the LWT topic `tele/<id>/LWT` ("Online"/"Offline").
- The app stores a per-device **`channels`** count (1–16), chosen at claim time.

### 3.3 Backend — `backend/`

| File | Responsibility |
|---|---|
| `server.js` | Express + Socket.IO bootstrap, MQTT/rule-engine init, routes, `/api/health`, `/api/mqtt/snapshot` |
| `services/mqttGateway.js` | MQTT client: subscriptions, message routing, sensor cache, device-state updates, Socket.IO emit, LWT handling |
| `services/ruleEngine.js` | Every-10s evaluation of enabled automation rules (edge-triggered fire) |
| `services/runtimeState.js` | In-memory per-device channel states + `online` flag |
| `services/deviceRegistry.js` | Claimed devices loaded from MongoDB into a Map |
| `models/*.js` | Mongoose schemas: User, Device, Sensor, Rule |
| `middleware/auth.js` | JWT `Bearer` verification |
| `routes/*.js` | auth, devices, sensors, rules, control |
| `virtual_mqtt_device.js`, `mock_tasmota.js` | Local dev simulators (4-channel) |

### 3.4 Flutter app — `flutter_app/lib/`

| File | Responsibility |
|---|---|
| `main.dart` | App entry, auth gate, home page (device chips, sensor cards, channel grid, live Socket.IO updates) |
| `screens/login_screen.dart` / `signup_screen.dart` | Auth UI |
| `screens/add_device_screen.dart` | Claim a Sonoff: Device ID + Name + Relay Count picker |
| `screens/add_sensor_screen.dart` | Link a sensor: Name + Sensor ID + device; verify-on-add dialog flow |
| `screens/sensor_rules_screen.dart` | Per-sensor rule list: enable toggle, delete, add |
| `screens/rule_form_screen.dart` | Create a rule: Name, Channel, Above/Below, Threshold, ON/OFF |
| `services/api_service.dart` | REST client (JWT + JSON) |
| `services/auth_service.dart` | Secure token storage (flutter_secure_storage) |
| `theme.dart` | Dark ocean palette: well #0B1922, submerged #1A2D3D, stream #2DD4BF, leaf #34D399 |

---

## 4. MQTT protocol

| Direction | Topic | Payload | Meaning |
|---|---|---|---|
| Sensor → | `tele/<SENSOR_ID>/SENSOR` | `{"value":42}` | Soil moisture reading |
| Backend → | `cmnd/<deviceId>/POWER<n>` | `ON`/`OFF` | Command a relay channel |
| Device → | `stat/<deviceId>/RESULT` | `{"POWER1":"ON"}` | Ack/state after a command |
| Device → | `tele/<deviceId>/STATE` | `{"POWER1":"OFF",...}` | Periodic full state |
| Device → | `tele/<deviceId>/LWT` | `Online`/`Offline` | Liveness (birth/will) |
| Device → | `tele/<SENSOR_ID>/SENSOR` (1-relay) | `{"POWER":"ON"}` | Bare-key single relay |

Gateway subscriptions: `tele/+/SENSOR`, `tele/+/STATE`, `tele/+/LWT`, `stat/+/RESULT`, `stat/+/POWER+`.

**Single-relay normalization:** `powerUpdatesFrom()` maps a bare `POWER` value to channel 1 whenever no numbered `POWERn` keys are present, so 1-relay devices work regardless of stored channel count.

---

## 5. Backend API reference

Auth: `Authorization: Bearer <JWT>` on all routes except auth/health/snapshot.

### Auth
| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/api/auth/signup` | `{username, password}` | `201 {token, user}` |
| POST | `/api/auth/login` | `{username, password}` | `200 {token, user}` |

### Devices
| Method | Path | Body | Notes |
|---|---|---|---|
| GET | `/api/devices` | – | User's claimed devices |
| POST | `/api/devices/claim` | `{deviceId, name, channels?}` | `channels` 1–16, default 4; sets `type` (`sonoff-1ch`, `sonoff-4ch`, …) |
| POST | `/api/devices/unclaim` | `{deviceId}` | Release ownership |
| DELETE | `/api/devices/:deviceId` | – | Remove device |

### Sensors
| Method | Path | Body | Notes |
|---|---|---|---|
| GET | `/api/sensors` | – | User's sensors + derived `status` (online/offline from `lastSeen`) |
| POST | `/api/sensors` | `{name, sensorId, deviceId}` | **Cache-verified** (see §6.1); `200 {success:true}` or `404 {success:false,message}` |
| DELETE | `/api/sensors/:sensorId` | – | Also deletes its rules |

### Rules
| Method | Path | Body | Notes |
|---|---|---|---|
| GET | `/api/rules` | – | Includes `sensorName`/`deviceName` |
| POST | `/api/rules` | `{name, sensorId, channel, condition, threshold, action}` | `deviceId` auto-derived from sensor; channel bounded by device relay count |
| PATCH | `/api/rules/:id/enable` | – | Toggle `enabled` |
| DELETE | `/api/rules/:id` | – | Delete rule |

### Control
| Method | Path | Body | Notes |
|---|---|---|---|
| POST | `/api/control` | `{deviceId, channel, state}` | `state` ON/OFF/TOGGLE; rejects offline devices (409) |
| GET | `/api/status?deviceId=…` | – | Channel states `{POWER1..POWERn}` |

### Debug (no auth)
| Method | Path | Returns |
|---|---|---|
| GET | `/api/health` | `status`, `mqtt`, `db`, `claimedDevices`, `seenOnMqtt` |
| GET | `/api/mqtt/snapshot` | sensors (cache) + claimed devices seen on the broker |

---

## 6. Key data flows

### 6.1 Adding a sensor (verified, non-blocking)
1. User enters Name + Sensor ID, picks a linked Sonoff, taps **Add Sensor**.
2. App shows a "Searching for sensor..." dialog and calls `POST /api/sensors`.
3. Backend reads the in-memory MQTT cache: `mqttGateway.getSensorReading(sensorId, 15s)` — **O(1) Map lookup, no waiting, no timeouts**.
4. Reading arrived in the last 15 s → sensor saved (with `lastValue`/`lastSeen`) → `200 {success:true}`.
5. Otherwise → instant `404 "Sensor not found. Make sure the ESP32 is online and the Sensor ID is correct."`
6. App shows success or failure dialog and returns to Home.

### 6.2 Reverse effect (physical → app)
1. User toggles the relay physically → Tasmota publishes `stat/<id>/RESULT` (or `tele/<id>/STATE`).
2. `powerUpdatesFrom()` extracts the new states for the device's channel count (bare `POWER` → channel 1).
3. Gateway updates `RuntimeState` and emits `device_update {deviceId, channel, state}` via Socket.IO.
4. The app's listener flips the matching card (gated by the selected device's `_deviceChannels`).

### 6.3 App control → physical (with offline check)
1. User taps a channel → optimistic UI update + `POST /api/control`.
2. Backend checks ownership, channel bounds, **and** `runtimeState.isOnline(deviceId)` (LWT "Online" or telemetry within 60 s).
3. Device offline/powered off → `409 "Device is not connected or is powered off"`; app reverts the card and shows the backend message.
4. Device online → publishes `cmnd/<id>/POWER<n> ON|OFF` → relay switches → its `RESULT` flows back via 6.2.

### 6.4 Rule automation
1. Sensor publishes → gateway updates `Sensor.lastValue` in MongoDB (and the in-memory cache).
2. `ruleEngine.evaluate()` every 10 s: for each enabled rule, compare the sensor's latest `lastValue` to `threshold` (`above`/`below`).
3. **Edge-triggered**: fires only when the condition flips from false→true (tracked in `this.prev`).
4. Fire → `publishCommandNoWait(rule.deviceId, rule.channel, rule.action)`.

---

## 7. Data model

**User** — `username` (unique, lowercase), `password` (bcrypt hash, stripped from JSON).

**Device** — `deviceId` (unique), `name`, `ownerId`, `type` (`sonoff-1ch`/`sonoff-Nch`), `channels` (1–16), `claimedAt`.

**Sensor** — `ownerId`, `name`, `sensorId` (**globally unique index** — MQTT looks it up by `sensorId` only), `deviceId`, `lastValue`, `lastSeen`, `createdAt`. No persisted `status` — online/offline is derived from `lastSeen`.

**Rule** — `ownerId`, `name`, `sensorId`, `deviceId`, `channel` (1–4), `condition` (`above`/`below`), `threshold`, `action` (`ON`/`OFF`), `enabled` (default true).

---

## 8. Security

- Passwords hashed with **bcrypt** (10 salt rounds).
- **JWT** (30-day expiry) required on all data routes via `authMiddleware`.
- Ownership enforced per route (`ownerId` checks) — users cannot act on others' devices/sensors/rules.
- `Sensor.sensorId` global-unique prevents cross-user collisions.
- `User.toJSON` strips the password hash; Device/Sensor/Rule strip `__v`.
- ⚠️ **Caveats:** `JWT_SECRET` defaults to a dev value; Mongo Atlas password `raouf2003` should be rotated; `/api/mqtt/snapshot` is intentionally unauthenticated for debugging.

---

## 9. Deployment & environment

| Item | Value |
|---|---|
| Live backend | `https://sonoff-3na2.onrender.com` (Render) |
| Repo | `github.com/Raouf2003/sonoff` (auto-deploy on push) |
| MQTT broker | Public `broker.emqx.io:1883` |
| MongoDB | Atlas database `kiosk`, user `raoufdb` |
| App | Android, package `com.example.smart_home_app`, device KB2003 (adb `e7eb39ec`) |
| Backend deps | express, mongoose, mqtt, socket.io, jsonwebtoken, bcryptjs, cors, bonjour |
| App deps | http, socket_io_client, flutter_secure_storage, google_fonts |

---

## 10. Recent changes & design decisions

1. **Non-blocking sensor verification** — replaced a 10 s blocking MQTT wait with a transient in-memory cache (`Map<sensorId, {value,lastSeen}>`); O(1) lookup, 15 s validity, near-instant responses.
2. **Multi-relay support** — per-device `channels`; claim accepts a Relay Count picker; control/status/rules honor the device channel count.
3. **1-relay reverse effect** — bare `POWER` keys/topics mapped to channel 1.
4. **Offline detection** — LWT subscription + `isOnline()` (LWT or 60 s telemetry freshness); control rejects offline devices with a clear message; app surfaces the backend error.
5. **Per-device sensor scoping** — the Home sensors section shows only sensors linked to the **selected** device.
6. **Rules owned by sensor card** — rules moved out of the Add Sensor flow into each sensor card (device always derived from the sensor, never user-picked).
7. **Debug visibility** — `[mqtt] … seen on broker` logs + `/api/mqtt/snapshot` endpoint.
8. **UX polish** — Add Device screen made scrollable to avoid keyboard overflow; dark theme throughout.

---

## 11. Known limitations

- **Public broker noise**: on `broker.emqx.io` the gateway sees thousands of third-party devices; logs/snapshot are noisy (only claimed devices / known sensors are acted on).
- **Firmware config placeholders**: WiFi credentials, sensor ID, and pin must be set per node.
- **No persisted device liveness**: `online` is in-memory only; a server restart re-derives it from the next telemetry/LWT.
- **Mongo Atlas credentials** are committed in dev history — rotate them.
- **`JWT_SECRET`** falls back to a well-known dev string unless `JWT_SECRET` is set in production.
- **No tests** currently defined for backend or Flutter.

---

## 12. Getting started / local dev

```bash
# Backend
cd backend
npm install
set MONGO_URI=<atlas-uri>; set MQTT_BROKER_URL=mqtt://broker.emqx.io:1883; set JWT_SECRET=<secret>
npm start            # or: npm run virtual / npm run dev (simulator)

# Flutter app
cd flutter_app
flutter pub get
flutter run -d <device>     # API base: https://sonoff-3na2.onrender.com (api_service.dart)

# Firmware
# open firmware/esp32_sensor_node.ino in Arduino IDE; set WiFi + sensor ID; flash ESP32
```

---

*Generated from the current state of the `withTasmota` workspace.*
