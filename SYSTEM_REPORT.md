# STEES — System Report

Smart Irrigation controller: ESP32 sensor nodes + Tasmota Sonoff relays + a Node.js/MQTT backend + a Flutter app.

---

## 1. Architecture at a glance

```
┌─────────────┐   MQTT (public broker)   ┌────────────────────────────┐
│  ESP32 node  │  tele/<SENSOR_ID>/SENSOR  │   Backend (Node.js, port 3001)│
│  (soil, PIR) │ ────────────────────────▶ │  mqttGateway  ← subscribes  │
└─────────────┘   {"value":42}            │   ruleEngine   ← every 10s    │
┌─────────────┐                           │   RuntimeState (in-memory)   │
│ Tasmota relay│  stat/<id>/RESULT        │   DeviceRegistry (claimed)   │
│ (1 or 4 ch) │  tele/<id>/STATE, LWT    │                              │
│             │ ◀──────────────────────── │  cmnd/<id>/POWER<n> ON/OFF   │
└─────────────┘   ON / OFF               └──────┬──────▲────────────────┘
                                                │ REST │ Socket.IO
                                                ▼      │
                                        ┌───────────────────┐
                                        │  Flutter app (Android) │
                                        └───────────────────┘
```

---

## 2. Components

### 2.1 ESP32 sensor node — `firmware/esp32_sensor_node.ino`
- Publishes soil moisture (0–100%) as `tele/<SENSOR_ID>/SENSOR` with payload `{"value":42}`.
- The sensor ID lives in the MQTT **topic**, not the payload.
- Config placeholders: WiFi credentials, `MQTT_HOST = broker.emqx.io:1883`, `SENSOR_ID = "soil_1"`, `SENSOR_PIN = 34`.
- Value mapping: `map(raw, DRY=3000, WET=1200, 0, 100)`.

### 2.2 Tasmota Sonoff relays
- Either a **4-relay** controller (reports `POWER1..POWER4`) or a **1-relay** controller (reports a bare `POWER`, no number).
- The app distinguishes them by a per-device `channels` field chosen at claim time (1 Relay / 4 Relays).
- Liveness is signalled over `tele/<id>/LWT` ("Online"/"Offline").

### 2.3 Backend — `backend/`
- **MQTT Gateway** (`services/mqttGateway.js`): connects to the broker, subscribes to `tele/+/SENSOR`, `tele/+/STATE`, `tele/+/LWT`, `stat/+/RESULT`, `stat/+/POWER+`. Routes messages, maintains the sensor cache, updates runtime device state, and pushes `device_update` over Socket.IO.
- **Sensor cache**: in-memory `Map<sensorId, {value, lastSeen}>`. Transient; used to verify a sensor exists before saving it (valid within 15 s).
- **Rule Engine** (`services/ruleEngine.js`): every 10 s evaluates enabled rules against the latest `Sensor.lastValue` from MongoDB. Fires once on the false→true edge (`cmnd/<deviceId>/POWER<n> ON|OFF`).
- **RuntimeState** (`services/runtimeState.js`): in-memory channel states + `online` flag per device.
- **DeviceRegistry** (`services/deviceRegistry.js`): claimed devices loaded from MongoDB.
- **Routes** (Express, JWT auth):
  - `/api/auth` — signup/login
  - `/api/devices` — claim (with `channels`), unclaim, list, delete
  - `/api/sensors` — add (MQTT-cache verified), list, delete
  - `/api/rules` — create, list, enable toggle, delete
  - `/api/control` — POST turn channel ON/OFF, GET status
  - `/api/health` — status + MQTT + DB + seen-on-MQTT count
  - `/api/mqtt/snapshot` — devices/sensors currently observed on the broker (no auth, for debugging)
- **MongoDB** (Atlas): `User`, `Device`, `Sensor`, `Rule` models. `Sensor.sensorId` is globally unique.

### 2.4 Flutter app — `flutter_app/lib/`
- **Login/Register** → JWT stored locally.
- **Home** (`main.dart`): header with connection droplet, Add Device / Add Sensor / Logout. Device selector chips (per claimed device). A **Sensors** section showing only the sensors linked to the **selected** device, each card with Online/Offline badge, live value, **Rules** and **Add Rule** buttons. Below, a channel grid sized to the device's relay count (1 → one full-width card, 4 → 2×2). Socket.IO live updates flip cards when the physical relay changes.
- **Add Device**: Device ID + Name + Relay Count picker.
- **Add Sensor**: Name + Sensor ID + linked device. On submit: "Searching for sensor..." dialog → success ("Sensor connected successfully.") or failure ("Sensor not found…").
- **Rules screens**: `sensor_rules_screen.dart` (list per sensor, enable toggle, delete) and `rule_form_screen.dart` (Name, Channel, Above/Below, Threshold, ON/OFF action; the device is always auto-derived from the sensor).

---

## 3. Key data flows

### 3.1 Adding a sensor (verified, non-blocking)
1. User enters Name, Sensor ID, picks a linked Sonoff device, taps **Add Sensor**.
2. App shows a loading dialog and calls `POST /api/sensors`.
3. Backend reads the **in-memory MQTT cache**: `getSensorReading(sensorId, 15s)`.
4. If a reading arrived in the last 15 s → saves the sensor (with `lastValue`/`lastSeen`) → `200 {success:true}`.
5. Otherwise → instant `404 "Sensor not found…"`. **No blocking, no timeouts, O(1) lookup.**

### 3.2 Reverse effect (physical → app)
1. Physical toggle → Tasmota publishes `stat/<id>/RESULT` (JSON `{"POWER1":"ON"}` or `{"POWER":"ON"}`) and/or `tele/<id>/STATE`.
2. `powerUpdatesFrom()` extracts the states for the device's channel count (bare `POWER` → channel 1).
3. Gateway updates `RuntimeState` and emits `device_update` over Socket.IO.
4. App flips the matching card in real time.

### 3.3 App control → physical (with offline check)
1. User taps a channel → optimistic UI + `POST /api/control`.
2. Backend verifies the device is owned **and online** (`runtimeState.isOnline()` from LWT or recent telemetry).
3. Offline/powered off → `409 "Device is not connected or is powered off"`; the app reverts the card and shows the message.
4. Online → publishes `cmnd/<id>/POWER<n> ON|OFF` → the relay switches; its `RESULT` flows back through 3.2.

### 3.4 Automation (rule)
1. Sensor publishes → gateway updates `Sensor.lastValue` in MongoDB.
2. `ruleEngine` every 10 s: for each enabled rule, compare `lastValue` to threshold (`above`/`below`).
3. On the false→true edge, publishes the configured action to the sensor's linked device/channel.

---

## 4. Recent changes

- **MQTT cache verification**: sensor add no longer blocks 10 s waiting for a message; it checks a transient cache (15 s validity).
- **Multi-relay support**: devices store `channels` (1–16); claim accepts a relay-count picker; control/status/rules honor per-device channel count.
- **1-relay reverse effect**: bare `POWER` keys/topics are mapped to channel 1 so physical toggles reflect in the app.
- **Offline detection**: gateway subscribes to Tasmota LWT; `isOnline()` = LWT "Online" or telemetry within 60 s; control rejects offline devices with a clear message; the app surfaces the backend error.
- **Debug visibility**: `[mqtt] … seen on broker` logs and an unauthenticated `/api/mqtt/snapshot` endpoint (currently noisy on the shared public broker).

---

## 5. Environment / ops

- **Live backend**: `https://sonoff-3na2.onrender.com` (Render auto-deploys from `github.com/Raouf2003/sonoff`, branch main/HEAD `6f1a65a`).
- **Broker**: public `broker.emqx.io:1883` — the gateway sees many third-party devices; only claimed devices and known sensor IDs are acted on.
- **Database**: MongoDB Atlas `kiosk`, user `raoufdb` — **rotate the password** `raouf2003`.
- **App**: Android, package `com.example.smart_home_app`, device KB2003 (adb `e7eb39ec`).
- To deploy backend changes: `git add -A && git commit && git push` (Render redeploys).
