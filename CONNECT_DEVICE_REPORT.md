# STEES "Connect Device" Workflow — Report

## 1. Goal

Make the in-app **Provision Device** wizard work end-to-end on a real Tasmota device (tested on a **Sonoff Basic / ESP8266**, Tasmota 15.x, AP at `192.168.4.1`):

```
Join device AP (tasmota-XXXX)  →  Probe device AP  →  Provision (MQTT + Wi-Fi + Restart)
    →  Waiting poll (backend recentDevices)  →  Auto-claim  →  Device controllable in the app
```

The wizard replaces the manual flow of typing MQTT/Wi-Fi settings into the raw Tasmota web page (`http://192.168.4.1/cm`).

## 2. Architecture

| Layer | Role |
|---|---|
| **App** (`flutter_app`) | Wizard UI (`provision_device_screen.dart`) drives everything over `http://192.168.4.1/cm` while joined to the device AP. |
| **Native Android** (`MainActivity.kt`) | `stees/wifi_binding` channel: binds the process sockets to the WiFi interface and reports which network the phone is actually on. |
| **Backend** (`backend`) | MQTT Gateway on `broker.emqx.io:1883`, keeps a `recentDevices` map with a 320 s visibility window, exposes `GET /api/mqtt/snapshot` |
| | Claim API: `POST /api/devices/claim` persists the device to MongoDB so it is listed in the app. |
| **Tasmota device** | Performs `Backlog MqttHost…; Topic…; SSId1…; Password1…` then `Restart 1` to join the user's Wi-Fi and start publishing MQTT. |

### Backend config (production)
```env
MQTT_BROKER_URL=mqtt://broker.emqx.io:1883
MQTT_USERNAME=
MQTT_PASSWORD=
```
The app points at `kBaseUrl='https://sonoff-3na2.onrender.com'`; the backend
uses `RECENT_WINDOW_MS=320000`.

## 3. Full Flow (as designed in `app`)

1. **Step 1 — Connect:** the user is asked to join the device's AP (`tasmota-XXXX`). Tapping *Continue* → `_startSearch` → `_probeReachability` every 2 s until `GET http://192.168.4.1` succeeds, then moves to Step 2 (Configuration form). `_ensureBoundToWifi` (native bind) runs before each probe.
2. **Step 2 — Configure:** wizard pre-generates an MQTT topic `stees_<slug>_<rand`.
3. **Step 3 — Provision (`_sendTasmotaConfig`), two phases:**
   - Phase 1 (while still on device AP): `Backlog MqttHost <broker>; MqttPort 1883; [MqttUser xx; MqttPassword xx;] Topic <topic>; DeviceName <name>`
   - 500 ms pause → Phase 2: `Backlog SSId1 <ssid>; Password1 <pw>`
   - 500 ms pause → `Restart 1`
   - Writes MQTT **before** Wi-Fi so the device keeps both even if Tasmota drops the connection mid-restart.
4. **Release the Wi-Fi bind** immediately after provisioning succeeds (before the waiting poll) so backend calls go over normal internet; log `[PROVISION] wifi binding released, resuming default routing`.
5. **Waiting:** poll `GET /api/mqtt/snapshot` every 3 s for the generated topic `stees_<slug>_<rand>` until it appears in `recentDevices`, then `POST /api/devices/claim` (channels=4), pop back to device list.

## 4. Android plumbing (`MainActivity.kt`)

- Method channels:
  - `stees/wifi_settings` → `openWifiSettings`
  - `stees/wifi_binding` → `ensureBoundToWifi`, `releaseWifiBinding`, `getNetworkInfo`
- `ensureBound` uses `ConnectivityManager.request_network` with
  `TRANSPORT_WIFI` only (NO `NET_CAPABILITY_INTERNET`, since the device AP has none), then `bindProcessToNetwork(network)` unless already bound.
- `releaseWifiBinding` calls `bindProcessToNetwork(null)` and unregisters the callback.
- `getNetworkInfo` returns `{bound, wifi, internet, validated}` for the bound network (or the active default).
- Cleartext HTTP permitted only to `192.168.4.1` (`network_security_config.xml`).

AndroidManifest permissions: `INTERNET`, `ACCESS_NETWORK_STATE`, `CHANGE_NETWORK_STATE`. (Only the last two enable `requestNetwork`; without `CHANGE_NETWORK_STATE`, Android throws `SECURITY: Missing ACCESS_NETWORK_STATE`.)

## 5. Diagnostics / key log lines

- `[PROVISION] wifi bound=true`
- `[PROVISION] after bind: bound=true wifi=true internet=true validated=true` → **on a network with internet (router), not the device AP.**
- `[PROVISION] probe failed: bound=true wifi=true internet=true validated=true` → that explains `Could not find the device. Open Wi-Fi settings and connect to it.`
- **Expected healthy pattern** on the real device AP:
  `[PROVISION] after bind: bound=true wifi=true internet=false validated=false` (reads `internet` / `validated` false), and the 2 s probe to `192.168.4.1` succeeds.

When the probe fails **and** `internet=true`, the wizard now shows a specific, actionable error instead of the generic one (new in the current code):

> "You're connected to a network with internet (your router), not the device access point. Disable Mobile data at all, forget/trigger-off your router Wi-Fi, connect to the device network, then retry."

## 6. Root causes found & fixed

| Symptom | Root cause | Fix |
|---|---|---|
| `SECURITY: Missing ACCESS_NETWORK_STATE` | `requestNetwork` needs the correct permission (the error text names the wrong one) | Added `CHANGE_NETWORK_STATE` to the manifest |
| `MissingPluginException` calling `get-network-info` | Hot-reload does **not** install new native Kotlin code (old binary kept running) | Full reinstall (`flutter run` after quitting), not hot-reload |
| Kotlin compile failure | `e.message` is a `String?` but the channel `error()` wants `String` | `e.message ?: "Unknown error"` |
| Probe fails while it seems the phone is on the AP (the original "Could not find the device" loop) | Phone's active Wi-Fi is the **router** (`internet=true`), routing the probe to the wrong network; Android auto-reverts off the "no internet" AP | Root cause confirmed via `getNetworkInfo`; specific error message + user must forget/off the router Wi-Fi and disable mobile data during Step 1 |
| Provision lost MQTT settings when Wi-Fi changed | Tasmota clears some settings on network switch | Two-phase command order: MQTT first, Wi-Fi second, restart last |

## 7. Current status

- `flutter analyze` clean; debug APK builds.
- `[PENDING]:` backend still un-deployed — `RECENT_WINDOW_MS` must be **increased to 320 s** and released to Render (currently the polling has no window in prod = the claim-poll can miss).
- Won't fully validate the wizard until a test run where the phone is truly on the device AP (`internet=false`), the device provisions, and appears as the generated topic in `recentDevices`.
- Device-side MQTT already proven manually: manual `Backlog MqttHost broker.emqx.io; MqttPort 1883; Topic stees_testx…` → device published with the LWT and `tele/stees_testx/STATE`.

## 8. Next steps (corrected test procedure)
1. **Phone prep:** disable Mobile data; temporarily forget/off the router Wi-Fi so the phone can't auto-revert; connect to `tasmota-XXXX`.
2. Full reinstall of the app (not hot-reload), run wizard. Watch console.
3. Expected logs: `[PROVISION] wifi bound=true` → `after bind: bound=true wifi=true internet=false validated=false` → `status=200 body={"Backlog":"Done"}` → `wifi binding released, resuming default routing`.
4. After `Restart 1`, the ESP joins the home Wi-Fi and starts MQTT; within the 320 s window it should appear in `recentDevices`, be claimed, and show up in the app's device list.
5. Deploy the backend change (`RECENT_WINDOW_MS`) to Render so the claim-poll can observe it.

## 9. Relevant files

- `flutter_app/lib/screens/provision_device_screen.dart` — the whole wizard (`_startSearch`, `_probeReachability`, `_ensureBoundToWifi`, `_releaseWifiBinding`, `_isReachable` + router-vs-AP message, `_sendTasmotaConfig`, `_pollSnapshot`, `_runClaim`, lifecycle observer).
- `flutter_app/android/app/src/main/kotlin/com/example/smart_home_app/MainActivity.kt` — channel impl, network binding, network info.
- `flutter_app/android/app/src/main/AndroidManifest.xml` and `res/xml/network_security_config.xml` — permissions + cleartext-only-to-`192.168.4.1`.
- `flutter_app/lib/services/api_service.dart` — `kBaseUrl`, `fetch/snapshot`, `claimDevice`.
- `backend/services/mqttGateway.js` — `RECENT_WINDOW_MS`, `recentDevices`, windowed snapshot.
- `backend/.env` — `MQTT_BROKER_URL=mqtt://broker.emqx.io:1883`, blank creds.