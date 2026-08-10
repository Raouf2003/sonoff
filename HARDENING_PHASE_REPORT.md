# STEES Production-Readiness Hardening — Report

Scope: online-first hardening of the existing STEES system (backend, Flutter app,
provisioning, MQTT). No Local/Offline mode, no MQTT TLS, no redesign of the
hardware-verified Tasmota provisioning sequence.

## A. Files changed

### Backend
- `backend/services/mqttGateway.js` — defensive message handling, bounded
  in-memory maps, `.catch` on sensor push.
- `backend/services/runtimeState.js` — `isOnline()` now uses the same
  configurable `freshMs` window as `touchDevice` (was a hardcoded 60s).
- `backend/routes/devices.js` — device DELETE now cascades to its sensors,
  their rules, and its schedules (releasing relays a schedule left ON).
- `backend/models/Rule.js` — channels validator no longer hard-caps at 4
  (route already bounds by the device's real channel count).
- `backend/package.json` — added `test` script.
- `backend/test/runtimeState.test.js`, `ruleModel.test.js`, `mqttPower.test.js`
  — new (12 tests).

### Flutter
- `lib/services/api_service.dart` — every call now runs under a 15s timeout;
  transport failures are classified (`TIMEOUT`/`NETWORK_ERROR`); all endpoints
  throw `ApiException` with `statusCode` + machine `code`; global 401 hook.
- `lib/screens/main_shell.dart` — registers/unregisters a global 401 handler
  that logs the user out; shared `_routeToLogin`.
- `lib/screens/login_screen.dart`, `signup_screen.dart` — friendly error
  mapping, re-entrancy guard, signup password-obscure now applies to BOTH
  password & confirm fields.
- `lib/screens/devices_page.dart` — distinct error-vs-empty state with retry,
  ripples stop when a channel is OFF, state reset on device switch, guarded
  socket payload casts, safe channel-config fallback beyond the 4-entry palette.
- `lib/screens/sensors_page.dart`, `rules_page.dart`, `schedules_page.dart`,
  `sensor_rules_screen.dart` — distinct error+retry state, mounted guards,
  user-facing error messages for toggle/delete failures.
- `lib/screens/rule_form_screen.dart` — resolves the sensor's real device
  channel count (no more silent cap at CH4), friendly save errors.
- `lib/screens/schedule_form_screen.dart` — friendly save errors.
- `lib/screens/add_sensor_screen.dart` — surfaces the real API error in the
  result dialog instead of a generic message.
- `lib/widgets/stees_widgets.dart` — new shared `SteesError` component.
- `test/stees_error_test.dart` — new (2 tests).

## B. Bugs fixed
1. `runtimeState.isOnline()` used a hidden 60s `FRESH_MS` fallback while the
   rest of the system treats a device as fresh for 5 minutes — devices with a
   long Tasmota TelePeriod (300s default) could flip offline and block
   rules/schedules between telemetry bursts. Now consistent with `freshMs`.
2. Rules targeting channels 5+ on a multi-relay device passed route validation
   (bounded by device) then failed Mongoose validation → 500. Model validator
   now matches the route contract.
3. Deleting a device left orphaned sensors, rules and schedules, and a stale
   in-memory runtime state; relays a schedule had left ON could stay stuck.
   Now: full cascade + best-effort release.
4. `devices_page` indexed the 4-entry channel palette with `_deviceChannels` —
   a device claimed with >4 channels crashed the relay grid (`RangeError`).
   Now falls back to generated labels/icons.
5. Signup screen: password field was hardcoded `obscure: true` while the eye
   toggle only affected the confirm field.
6. Rule form: channel picker was capped at 4 even for 8+ channel devices.
7. Devices list conflated "failed to load" with "no devices" (showed the happy
   empty state on a network failure); same for sensors/rules/schedules/
   sensor-rules screens.
8. Devices screen: ripples never stopped when polling reported a channel OFF,
   and switching devices left the previous device's states/animations in the
   grid.
9. Login/signup could double-fire via password `onSubmit` during an in-flight
   login.
10. Unhandled socket payload casts and a raw-exception echo in the provision
    wizard's peers could crash UI handlers.

## C. UX improvements
- All list screens now show a consistent, explicit error state with a Retry
  button instead of the misleading "nothing here yet" empty state.
- Error messages are consistent and user-safe everywhere (no raw exception
  text) and always carry the real backend message where available.
- A 15s ceiling on every HTTP call means a hung socket can never leave a page
  on an endless spinner.
- Expired/invalid sessions now bounce the user to Login instead of leaving
  every tab showing generic failures.
- Deleting a rule/schedule that fails now explains why instead of silently
  doing nothing.

## D. Reliability improvements
- MQTT message handling is fully guarded: malformed/hostile payloads are
  logged and dropped, never able to crash the process.
- The transient in-memory broker maps (`recentDevices`, `sensorCache`,
  `sensorOwnerCache`, `seenLog`) are pruned on a timer, so a shared public
  broker can't grow them without bound.
- The fire-and-forget sensor push is `.catch`-guarded.
- `ApiService` classifies timeouts/network errors so callers can respond
  appropriately instead of treating them as server errors.
- Provisioning wizard audit: timer/socket/wifi-binding cleanup on dispose,
  mounted guards, deadline-bound waiting, graded terminal-vs-recoverable claim
  errors — confirmed already correct, unchanged.

## E. Security improvements
- No secrets are logged anywhere in the changes (Wi-Fi passwords, tokens still
  only appear inside request URLs intended for the device).
- The claim flow remains possession-gated by `device_seen` proof + one-time
  hashed token; untouched.
- 401 handling clears stored credentials reliably across the app.

## F. Tests performed
- Backend: `node --check` on every JS source file (clean); new `node --test`
  suite — 12 passed (runtimeState freshMs fallback, rule channels validation,
  MQTT power-payload mapping incl. bare `POWER` and malformed payloads).
- Flutter: `flutter analyze` — 0 issues; `flutter test` — 31 passed (28
  WifiTest classifier incl. capital-F `WiFiTest`, 1 auth-gate widget test, 2
  new `SteesError` widget tests).
- Android: `flutter build apk --debug` — built successfully.

## G. Remaining limitations
- Legacy devices storing a singular `channel` field (pre-`channels` schema)
  cannot materialize it under Mongoose strict mode; the `channelsCompat`
  virtual and pre-save migration are effectively dead and only affect ancient
  documents. Not regressed, but not fully cleaned up.
- JWT has no expiry check client-side beyond the new 401→logout handling; there
  is no refresh-token flow (by design — out of scope).
- Schedules remain same-day only; overnight ranges are rejected by the schema.
- Provisioning success is verified via the classifier/polling/logs only; the
  exact `WifiTest` verdict strings on all firmware variants are not exhausted.

## H. Deferred items (explicitly out of scope)
- MQTT TLS / MQTTS and credential hardening — separate security phase.
- Local/LAN control mode.
- Any redesign of the Tasmota provisioning sequence (Topic/FullTopic remain
  standalone; no single-restart experiment; claim-token possession retained).
- Refresh tokens / token rotation.
- Overnight scheduling support.
- Clean removal of the legacy singular-`channel` migration path.

## I. Real-hardware tests required before claiming hardware-verified
1. Full provision on physical Tasmota 4CH (and an 8-channel device) through the
   wizard: correct and wrong home Wi-Fi, wrong password, 5 GHz-only network.
2. Confirm the Wi-Fi pre-flight (WifiTest3) verdicts on the target firmware
   version(s), including the `@`-suites value and localized "Connect failed"
   strings.
3. Reboot timing: AP reappearance after Topic/FullTopic writes, and the window
   between `Restart 1` and the first MQTT announce.
4. Relay toggle ACK/TOGGLE behavior across PowerModule variants.
5. Broker disconnect → command reject (503) → reconnect → re-publish path with
   a physical device; same for device power loss (LWT offline) while a schedule
   is in-window.
6. Deleting a device that a schedule left ON — confirm relays release.