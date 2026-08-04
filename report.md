# STEES Smart Irrigation Controller — Full Application Report

> Generated: Tue Aug 04 2026

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  Flutter Mobile App (Dart, Material 3, dark-mode)          │
│  ┌──────────┐  ┌──────────────┐  ┌────────────────────┐   │
│  │ AuthSvc  │  │  ApiService   │  │  Socket.IO client  │   │
│  │ (JWT +   │  │  (REST via    │  │  (real-time push)  │   │
│  │  secure  │  │   https)      │  │                    │   │
│  │ storage) │  │               │  │                    │   │
│  └────┬─────┘  └──────┬───────┘  └─────────┬──────────┘   │
└───────┼────────────────┼────────────────────┼───────────────┘
        │                │                    │
        ▼                ▼                    ▼
┌─────────────────────────────────────────────────────────────┐
│  Express Backend  (Node 20, Render)                         │
│  ┌──────────┐ ┌───────────────┐ ┌────────────────────────┐ │
│  │ JWT Auth │ │  REST Routes  │ │  Socket.IO server      │ │
│  │ /auth/*  │ │  /devices     │ │  device_update events  │ │
│  │          │ │  /sensors     │ │  sensor_update events  │ │
│  │          │ │  /rules       │ │                        │ │
│  │          │ │  /schedules   │ │                        │ │
│  │          │ │  /control     │ │                        │ │
│  └──────────┘ └───────┬───────┘ └────────────────────────┘ │
│                        │                                     │
│  ┌─────────────────────┼──────────────────────────────────┐ │
│  │              Service Layer                              │ │
│  │  mqttGateway  ruleEngine  scheduleEngine  deviceReg    │ │
│  │  runtimeState sensorIngest                              │ │
│  └─────────────────────┬──────────────────────────────────┘ │
└────────────────────────┼────────────────────────────────────┘
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
   ┌────────────┐ ┌────────────┐ ┌──────────────┐
   │ HiveMQ     │ │ MongoDB    │ │  Sonoff 4CH  │
   │ Cloud      │ │ Atlas      │ │  Pro R3      │
   │ (MQTT TLS) │ │            │ │  (Tasmota)   │
   └─────┬──────┘ └────────────┘ └──────┬───────┘
         │                              │
         ▼                              ▼
   ┌────────────┐               ┌──────────────┐
   │ ESP32      │               │  Relay CH1-4 │
   │ Soil       │               │  (POWER1-4)  │
   │ Moisture   │               │              │
   │ Sensors    │               │              │
   └────────────┘               └──────────────┘
```

**Data flow:**
- **Sensors** → MQTT `tele/<sensorId>/SENSOR` → `mqttGateway` → MongoDB `Sensor.lastValue` + Socket.IO push to Flutter
- **Relays** → MQTT `cmnd/<deviceId>/POWER<n>` → Tasmota executes → state echoed back on `stat/<deviceId>/RESULT`
- **Rules** → 10s tick → read sensor threshold → if crossed, publish MQTT command → Tasmota toggles relay
- **Schedules** → 30s tick → luxon timezone-aware → if time window active, publish MQTT command → Tasmota toggles relay
- **Flutter** → REST for CRUD, Socket.IO for live device/sensor updates

---

## 2. Backend

### 2.1 Entry Point

| File | Lines | Purpose |
|---|---|---|
| `backend/server.js` | ~200 | Express app, middleware (CORS, JSON, JWT), route mounting, service initialization |

**Mounted routes:**
- `/api/auth` → `routes/auth.js` (signup, login)
- `/api/devices` → `routes/devices.js` (CRUD, claim, unclaim, status, control)
- `/api/sensors` → `routes/sensors.js` (CRUD, MQTT verification)
- `/api/rules` → `routes/rules.js` (CRUD, enable/disable)
- `/api/schedules` → `routes/schedules.js` (CRUD, enable/disable)
- `/api/control` → `routes/control.js` (relay toggle)

**Services initialized at startup:**
- `mqttGateway.connect()` — connects to HiveMQ Cloud
- `deviceRegistry.load()` — loads claimed devices from DB
- `ruleEngine.start()` — 10s interval
- `scheduleEngine.start()` — 30s interval

### 2.2 Models (MongoDB/Mongoose)

#### User (`models/User.js`)
| Field | Type | Notes |
|---|---|---|
| `username` | String, unique | Indexed |
| `password` | String | bcrypt hashed |

#### Device (`models/Device.js`)
| Field | Type | Notes |
|---|---|---|
| `deviceId` | String, unique | Tasmota device ID |
| `name` | String | User-assigned display name |
| `channels` | Number | 1 or 4 |
| `userId` | ObjectId ref User | Owner |
| `claimedAt` | Date | auto |

#### Sensor (`models/Sensor.js`)
| Field | Type | Notes |
|---|---|---|
| `sensorId` | String, unique | Indexed, matches MQTT topic |
| `name` | String | User-assigned display name |
| `deviceId` | ObjectId ref Device | Parent device |
| `userId` | ObjectId ref User | Owner |
| `lastValue` | Number | Latest reading |
| `lastSeen` | Date | Last MQTT publish |

#### Rule (`models/Rule.js`)
| Field | Type | Notes |
|---|---|---|
| `name` | String | |
| `sensorId` | ObjectId ref Sensor | |
| `channel` | Number | 1-4 |
| `condition` | String | `"below"` or `"above"` |
| `threshold` | Number | Trigger value |
| `action` | String | `"ON"` or `"OFF"` |
| `enabled` | Boolean | default true |
| `lastConditionState` | Boolean | Edge-trigger state (true = already fired) |
| `userId` | ObjectId ref User | |

#### Schedule (`models/Schedule.js`)
| Field | Type | Notes |
|---|---|---|
| `name` | String | |
| `deviceId` | ObjectId ref Device | |
| `channels` | [Number] | e.g. [1,2] |
| `recurrence` | String | `"daily"` or `"custom"` |
| `daysOfWeek` | [Number] | 0=Mon..6=Sun (custom only) |
| `timeRanges` | [{start, end}] | `"HH:MM"` strings |
| `enabled` | Boolean | default true |
| `lastAppliedState` | Map(String,Boolean) | Per-channel last sent state |
| `userId` | ObjectId ref User | |

### 2.3 Services

#### mqttGateway (`services/mqttGateway.js`)
- Connects to `mqtts://5a86e38080744eb89c62cd93cf7b9249.s1.eu.hivemq.cloud:8883`
- Subscribes to `tele/+/SENSOR`, `stat/+/RESULT`, `tele/+/LWT`
- On `SENSOR` message: extracts value from JSON payload, updates `Sensor.lastValue`, emits `sensor_update` via Socket.IO
- On `RESULT` message: updates device relay states
- On `LWT` message: updates online/offline status
- `publish(topic, payload)` — sends MQTT commands to Tasmota devices

#### ruleEngine (`services/ruleEngine.js`)
- **10-second tick** via `setInterval`
- For each enabled rule: checks sensor value vs threshold, fires edge-trigger (only on transition)
- Uses `this.prev` Map for edge detection (key: ruleId, value: lastConditionState)
- `invalidate(ruleId)` — deletes from `this.prev`, forcing re-read from DB on next tick
- `_primeCache(ruleId)` — reads `lastConditionState` from DB, caches in `this.prev`
- `_logStuckCandidates()` — one-time startup log listing rules with `lastConditionState=true`

#### scheduleEngine (`services/scheduleEngine.js`)
- **30-second tick** via `setInterval`, luxon timezone-aware (`APP_TIMEZONE`, default `Africa/Algiers` UTC+1)
- For each enabled schedule: checks current time against `timeRanges`, current day against `daysOfWeek`
- Uses `this.stateCache` Map (key: scheduleId, value: Map of channel→bool)
- `invalidate(scheduleId)` — deletes from `this.stateCache`
- `release(schedule)` — sends OFF to channels held ON by the schedule
- `_primeCache(scheduleId)` — reads `lastAppliedState` from DB

#### runtimeState (`services/runtimeState.js`)
- In-memory device state store
- `isOnline(deviceId)` — checks `lastSeen` within 60s (configurable `FRESH_MS`)
- `getState(deviceId)` / `setState(deviceId, state)` — read/write relay states

#### deviceRegistry (`services/deviceRegistry.js`)
- Manages claimed devices in memory + DB
- `load()` — loads all devices from DB on startup
- `claim(deviceId, name, userId, channels)` — creates DB record
- `unclaim(deviceId)` — removes from DB

#### sensorIngest (`services/sensorIngest.js`)
- Processes incoming MQTT sensor messages
- Extracts soil moisture value from ESP32 JSON payload
- Updates `Sensor.lastValue` and `Sensor.lastSeen` in DB
- Emits `sensor_update` via Socket.IO for Flutter push

### 2.4 Routes

#### Auth (`routes/auth.js`)
| Method | Endpoint | Auth | Body | Returns |
|---|---|---|---|---|
| POST | `/api/auth/signup` | No | `{username, password}` | `{token, user}` |
| POST | `/api/auth/login` | No | `{username, password}` | `{token, user}` |

#### Devices (`routes/devices.js`)
| Method | Endpoint | Auth | Body/Query | Returns |
|---|---|---|---|---|
| GET | `/api/devices` | JWT | — | `[{deviceId, name, channels}]` |
| POST | `/api/devices/claim` | JWT | `{deviceId, name, channels}` | `{device}` |
| POST | `/api/devices/unclaim` | JWT | `{deviceId}` | void |
| DELETE | `/api/devices/:id` | JWT | — | void |
| GET | `/api/status` | JWT | `?deviceId=` | `{POWER1: "ON", ...}` |
| POST | `/api/control` | JWT | `{deviceId, channel, state}` | `{ok}` |

#### Sensors (`routes/sensors.js`)
| Method | Endpoint | Auth | Body | Returns |
|---|---|---|---|---|
| GET | `/api/sensors` | JWT | — | `[{sensorId, name, lastValue}]` |
| POST | `/api/sensors` | JWT | `{sensorId, name, deviceId}` | `{sensor}` (waits for MQTT verification) |
| DELETE | `/api/sensors/:id` | JWT | — | void |

#### Rules (`routes/rules.js`)
| Method | Endpoint | Auth | Body | Returns |
|---|---|---|---|---|
| GET | `/api/rules` | JWT | — | `[{rule}]` |
| POST | `/api/rules` | JWT | `{name, sensorId, channel, condition, threshold, action}` | `{rule}` |
| PATCH | `/api/rules/:id/enable` | JWT | — | `{rule}` (toggles enabled) |
| DELETE | `/api/rules/:id` | JWT | — | void |

#### Schedules (`routes/schedules.js`)
| Method | Endpoint | Auth | Body | Returns |
|---|---|---|---|---|
| GET | `/api/schedules` | JWT | — | `[{schedule}]` |
| POST | `/api/schedules` | JWT | `{name, deviceId, channels, recurrence, daysOfWeek, timeRanges}` | `{schedule}` |
| PATCH | `/api/schedules/:id` | JWT | partial update | `{schedule}` (calls `invalidate`) |
| PATCH | `/api/schedules/:id/enable` | JWT | — | `{schedule}` (toggles enabled, calls `invalidate`) |
| DELETE | `/api/schedules/:id` | JWT | — | void (calls `release` + `invalidate`) |

### 2.5 Auth & Security

- Passwords hashed with bcrypt (10 rounds)
- JWT tokens issued on login/signup (secret from `JWT_SECRET` env var)
- All `/api/*` routes except `/api/auth/*` require `Authorization: Bearer <token>` header
- MQTT broker uses TLS (port 8883) with username/password auth
- MongoDB Atlas with IP whitelist

---

## 3. Flutter App

### 3.1 Dependencies

| Package | Version | Purpose |
|---|---|---|
| `http` | ^1.2.0 | REST API calls |
| `socket_io_client` | ^3.1.0 | Real-time WebSocket |
| `flutter_secure_storage` | ^9.2.0 | Encrypted JWT storage |
| `google_fonts` | ^6.1.0 | Inter font family |

### 3.2 Entry Point & Navigation

**`lib/main.dart`** (1047 lines) — contains:
- `SteesApp` — root widget, dark theme, Material 3
- `AuthGate` — checks `AuthService.isLoggedIn()`, shows splash → `LoginScreen` or `HomePage`
- `HomePage` — main dashboard (device selector, sensor cards, 4-zone relay grid)
- Private widgets: `_ActionRail`, `_RailCell`, `_WaterCard`, `_WaterCardBody`, `_DropletToggle`, `_WaterRippleIcon`, `_ConnectionPip`, `_SteesLogo`

**Navigation flow:**
```
AuthGate
  ├─ LoginScreen → SignupScreen (toggle)
  └─ HomePage (after login)
       ├─ AddDeviceScreen (push)
       ├─ AddSensorScreen (push)
       ├─ SensorRulesScreen (push, per sensor)
       │    └─ RuleFormScreen (push)
       └─ ScheduleListScreen (push)
            └─ ScheduleFormScreen (push, create/edit)
```

### 3.3 Screens

| Screen | File | Lines | Purpose |
|---|---|---|---|
| `LoginScreen` | `screens/login_screen.dart` | 190 | Username/password login, fade-in animation |
| `SignupScreen` | `screens/signup_screen.dart` | 162 | Registration with password match validation |
| `AddDeviceScreen` | `screens/add_device_screen.dart` | 188 | Claim Tasmota device (ID, name, 1/4 channels) |
| `AddSensorScreen` | `screens/add_sensor_screen.dart` | 387 | Link ESP32 sensor with MQTT verification dialog |
| `SensorRulesScreen` | `screens/sensor_rules_screen.dart` | 229 | Per-sensor rule list, toggle/delete |
| `RuleFormScreen` | `screens/rule_form_screen.dart` | 252 | Create rule (channel, condition, threshold, action) |
| `ScheduleListScreen` | `screens/schedule_list_screen.dart` | 448 | Grouped-by-device schedule list with `WindowTimeline` |
| `ScheduleFormScreen` | `screens/schedule_form_screen.dart` | 575 | Create/edit schedule (channels, recurrence, time windows) |

### 3.4 Services

| Service | File | Lines | Purpose |
|---|---|---|---|
| `AuthService` | `services/auth_service.dart` | 33 | JWT + username encrypted storage |
| `ApiService` | `services/api_service.dart` | 275 | Central HTTP client (auto-injects JWT) |

**ApiService endpoints used:**
- Auth: `login`, `signup`
- Devices: `getDevices`, `claimDevice`, `getStatus`, `control`, `unclaimDevice`, `deleteDevice`
- Sensors: `getSensors`, `createSensor`, `deleteSensor`
- Rules: `getRules`, `createRule`, `toggleRule`, `deleteRule`
- Schedules: `getSchedules`, `createSchedule`, `updateSchedule`, `toggleSchedule`, `deleteSchedule`

### 3.5 Shared Widgets

| Widget | File | Lines | Purpose |
|---|---|---|---|
| `WindowTimeline` | `widgets/window_timeline.dart` | 98 | 24-hour visual timeline strip with gradient bars |

---

## 4. Design System

### 4.1 Color Palette (`lib/theme.dart`)

| Name | Hex | Role |
|---|---|---|
| `well` | `#0B1922` | Scaffold background (deep navy) |
| `submerged` | `#1A2D3D` | Card/surface fill |
| `stream` | `#2DD4BF` | Primary accent (teal) |
| `leaf` | `#34D399` | Secondary/success (green) |
| `sunlight` | `#FBBF24` | Tertiary/schedule accent (amber) |
| `mist` | `#94A3B8` | Muted text/icons (slate) |
| `foam` | `#F1F5F9` | Primary text (near-white) |

### 4.2 Typography
- Font: Inter (via `google_fonts`)
- Weights used: 400 (regular), 500 (medium), 600 (semibold), 700 (bold)

### 4.3 Design Patterns
- Dark mode enforced globally via `ThemeData.dark()`
- Material 3 enabled
- Consistent card style: `submerged` fill, 16px border radius, 1px border `well` shade
- Animated transitions: fade-in for screen entry, scale+fade for card entrance
- `_ActionRail`: horizontal pill toolbar with icon buttons and hairline separators
- `_ConnectionPip`: pulsing circle for Socket.IO status
- `_DropletToggle`: animated pill switch with water-drop icon

---

## 5. Firmware / Device Simulation

### virtual_mqtt_device.js
- Tasmota 4CH simulator for local development
- Connects to HiveMQ Cloud broker
- Publishes `tele/<deviceId>/SENSOR` with soil moisture readings
- Subscribes to `cmnd/<deviceId>/POWER1..4` and responds with state
- Publishes LWT `Online`/`Offline`

---

## 6. Deployment

| Component | Platform | URL |
|---|---|---|
| Backend | Render | `https://sonoff-3na2.onrender.com` |
| Database | MongoDB Atlas | (connection string in env) |
| MQTT Broker | HiveMQ Cloud | `mqtts://5a86e38080744eb89c62cd93cf7b9249.s1.eu.hivemq.cloud:8883` |
| Flutter App | Local build | Built on developer machine |

**Auto-deploy:** Push to `main` branch triggers Render rebuild (~2-3 min).

**Env vars required:**
- `MONGODB_URI` — MongoDB Atlas connection string
- `JWT_SECRET` — JWT signing secret
- `MQTT_URL` — HiveMQ broker URL
- `MQTT_USER` — HiveMQ username
- `MQTT_PASS` — HiveMQ password
- `APP_TIMEZONE` — IANA timezone (default: `Africa/Algiers`)

---

## 7. Git History (Recent)

```
af6fef5 fix(schedules): fix day-of-week mapping, stale cache, and doc consistency
4e22fdf feat(schedules): group by device, add button per section
fe64fb7 fix(ui): coalesce header actions into fixed _ActionRail
8988b28 feat(schedules): support edit from list
68941ff fix(schedule-form): fix overflow in range row
b615e99 fix(schedules): release held channels on delete
196c936 feat(schedules): redesign schedule form/list UI
```

---

## 8. Known Issues & Technical Debt

| # | Issue | Severity | Notes |
|---|---|---|---|
| 1 | `isOnline` 60s `FRESH_MS` vs Tasmota 300s `TelePeriod` | Medium | Schedule/rule engines gate on `runtimeState.isOnline()`, but sensors report every 300s. A sensor can be "offline" in memory while still active. |
| 2 | Hardcoded hex colors in Login/Signup/AddDevice | Low | These screens use inline hex colors instead of `AppColors` constants. |
| 3 | Duplicated `_Field` widget across screens | Low | 4 nearly identical private `_Field` widgets in login, signup, add_device, add_sensor. |
| 4 | Duplicated error SnackBar pattern | Low | `_err(m)` pattern repeated in multiple screens. |
| 5 | No shared delete-confirm dialog | Low | Each screen implements its own confirmation dialog. |
| 6 | Overnight time ranges not supported | Low | `ScheduleFormScreen` validates end > start (no crossing midnight). |

---

## 9. File Inventory

### Backend (Node.js)
| File | Lines |
|---|---|
| `backend/server.js` | ~200 |
| `backend/models/User.js` | ~30 |
| `backend/models/Device.js` | ~30 |
| `backend/models/Sensor.js` | ~35 |
| `backend/models/Rule.js` | ~40 |
| `backend/models/Schedule.js` | ~50 |
| `backend/services/mqttGateway.js` | ~250 |
| `backend/services/ruleEngine.js` | ~200 |
| `backend/services/scheduleEngine.js` | ~250 |
| `backend/services/runtimeState.js` | ~60 |
| `backend/services/deviceRegistry.js` | ~80 |
| `backend/services/sensorIngest.js` | ~80 |
| `backend/routes/auth.js` | ~60 |
| `backend/routes/devices.js` | ~120 |
| `backend/routes/sensors.js` | ~80 |
| `backend/routes/rules.js` | ~80 |
| `backend/routes/schedules.js` | ~100 |
| `backend/routes/control.js` | ~40 |

### Flutter (Dart)
| File | Lines |
|---|---|
| `flutter_app/pubspec.yaml` | 24 |
| `flutter_app/lib/main.dart` | 1047 |
| `flutter_app/lib/theme.dart` | 11 |
| `flutter_app/lib/services/auth_service.dart` | 33 |
| `flutter_app/lib/services/api_service.dart` | 275 |
| `flutter_app/lib/screens/login_screen.dart` | 190 |
| `flutter_app/lib/screens/signup_screen.dart` | 162 |
| `flutter_app/lib/screens/add_device_screen.dart` | 188 |
| `flutter_app/lib/screens/add_sensor_screen.dart` | 387 |
| `flutter_app/lib/screens/sensor_rules_screen.dart` | 229 |
| `flutter_app/lib/screens/rule_form_screen.dart` | 252 |
| `flutter_app/lib/screens/schedule_list_screen.dart` | 448 |
| `flutter_app/lib/screens/schedule_form_screen.dart` | 575 |
| `flutter_app/lib/widgets/window_timeline.dart` | 98 |

### Other
| File | Lines |
|---|---|
| `virtual_mqtt_device.js` | ~150 |
| `UI_UX_REPORT.md` | ~300 |
