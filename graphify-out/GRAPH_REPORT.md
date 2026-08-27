# Graph Report - withTasmota  (2026-08-27)

## Corpus Check
- 201 files · ~205,991 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 2689 nodes · 3609 edges · 104 communities (96 shown, 8 thin omitted)
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 66 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Provision Device Screen.D
- Devices Page
- Provision Full Flow Test.
- Channel State Machine.Dar
- Devices Page Local Test.D
- Win32 Window
- Schedules Page
- Api Service
- Local Device Transport.Da
- Device Repository Service
- Stees Widgets
- Device Repository Service 2
- Sensor Rules Screen
- Reachability Monitor
- App Theme
- Root
- Mqttgateway
- Provisioning Service
- Schedule Form Screen
- Schedulesyncservice
- Schedule List Screen
- Rule Form Screen
- Rules Page
- Stees Nav Bar
- Add Sensor Screen
- Mainactivity
- Packageon
- Server
- Sensors Page
- Provision Device Screen.D 2
- Main
- Mqttcommand.Test
- Tasmotaconfigclient
- Provision Remove Device T
- Device Transport Test.Dar
- My Application.Cc
- Devices Page Delete Test.
- Local Device Discovery.Da
- Login Screen
- Schedulesyncservice.Test.
- Device Transport
- Rules
- Signup Screen
- Controlregistry.Test
- Scheduledryrunservice
- Main Shell
- Local Device Cache
- Deviceprovisioning.Test.J
- Root 2
- Project Report.Md
- Root 3
- Schedulecompiler
- Scheduleparity.Test
- Api Service Token Cache
- Schedulesroute.Test
- Deviceprovisioningservice
- Schedulecutover.Test
- Devices
- Schedulesynctrigger
- Local Ip
- Badge Truth Test
- Scheduleengine
- Theme Controller
- Control Timeline
- Cloud Device Transport.Da
- Schedules
- Schedulesyncretry
- Devices Page Local Test.D 2
- Auth Service
- Root 4
- Devsync
- Mqttgateway 2
- Schedulesyncretry 2
- Control.Test
- Manifeston
- Auth
- Ruleengine
- Devsyncroute.Test
- Channel State Machine.Dar 2
- Mock Tasmota
- Runtimestate
- Sensors
- Channel State Machine Tes
- Brokerinfo.Test
- Schedulesimulator
- Root 5
- Schedule
- Virtual Mqtt Device
- Root 6
- Virtual Sonoff
- Devices Page 2
- Reachability Monitor 2
- Api Service 2
- Login Screen 2
- Root 7
- Schedules Page 2
- Flutter App Lib
- Root 8
- Root 9
- Project Report.Md 2

## God Nodes (most connected - your core abstractions)
1. `MqttGateway` - 28 edges
2. `_` - 28 edges
3. `MainActivity` - 26 edges
4. `Win32Window` - 24 edges
5. `compile()` - 20 edges
6. `runSyncDevice()` - 16 edges
7. `TasmotaConfigClient` - 16 edges
8. `ApiService` - 14 edges
9. `DeviceRegistry` - 12 edges
10. `ScheduleSyncRetry` - 12 edges

## Surprising Connections (you probably didn't know these)
- `MongoDB Atlas` --shares_data_with--> `Node.js Backend`  [EXTRACTED]
  SYSTEM_REPORT.md → PROJECT_REPORT.md
- `REST API` --implements--> `Node.js Backend`  [EXTRACTED]
  SYSTEM_REPORT.md → PROJECT_REPORT.md
- `Dashboard HTML` --conceptually_related_to--> `Flutter App`  [INFERRED]
  dashboard.html → PROJECT_REPORT.md
- `wWinMain()` --calls--> `CreateAndAttachConsole()`  [INFERRED]
  flutter_app/windows/runner/main.cpp → flutter_app/windows/runner/utils.cpp
- `Win32Window::Win32Window()` --calls--> `Destroy`  [INFERRED]
  flutter_app/windows/runner/win32_window.cpp → flutter_app/windows/runner/win32_window.h

## Import Cycles
- None detected.

## Communities (104 total, 8 thin omitted)

### Community 0 - "Provision Device Screen.D"
Cohesion: 0.01
Nodes (245): active, _allowWaitRetry, _alreadyExistsMessage, _apAttempt, _apConnectChannel, _apConnectDisabled, _apConnectMode, _apConnectPending (+237 more)

### Community 1 - "Devices Page"
Cohesion: 0.01
Nodes (140): add_device_screen.dart, activeColor, _api, _applyChannelEffects, _applyStatusResult, _badgeSettleTimer, build, _buildAddButton (+132 more)

### Community 2 - "Provision Full Flow Test."
Cohesion: 0.02
Nodes (86): DeviceRepositoryService? repo,
  List, _ApConnectMock, _bodyFor, _brokerHost, brokerInfoDown, _brokerPort, calls, cancelCalls (+78 more)

### Community 3 - "Channel State Machine.Dar"
Cohesion: 0.02
Nodes (83): ControlRoute get, _applyCloudVerdict, _applyLwtOffline, _applyPollFailure, _applyReport, _applyRest, _applyTap, _applyTimeout (+75 more)

### Community 4 - "Devices Page Local Test.D"
Cohesion: 0.03
Nodes (69): Completer, _FakeRepo, ControlRoute, _BusyTimeoutRepo, cached, cachedAddress, cachedVerifiedAt, call (+61 more)

### Community 5 - "Win32 Window"
Cohesion: 0.05
Nodes (57): RegisterPlugins(), DartProject, HWND, LPARAM, LRESULT, UINT, WPARAM, FlutterWindow (+49 more)

### Community 6 - "Schedules Page"
Cohesion: 0.03
Nodes (60): _add, _api, _blindFallback, build, _buildDimmedWatchCard, _buildPageTitle, _channelsOf, _clearWatch (+52 more)

### Community 7 - "Api Service"
Cohesion: 0.03
Nodes (57): Client, Client get, _auth, _cachedToken, checkHealth, _checkList, _checkObject, _client (+49 more)

### Community 8 - "Local Device Transport.Da"
Cohesion: 0.04
Nodes (56): address, _asInt, _assertTarget, bootstrap, buffer, cause, _channelNumberFromKey, channels (+48 more)

### Community 9 - "Device Repository Service"
Cohesion: 0.04
Nodes (55): channel_state_machine.dart, cloud_device_transport.dart, control_timeline.dart, _buildLocal, _cache, cachedDevices, _canSkipIdentityVerify, _cloud (+47 more)

### Community 10 - "Stees Widgets"
Cohesion: 0.04
Nodes (53): EdgeInsetsGeometry?, _DropletToggle, _FlowPill, _HeroIcon, _OfflineBadge, _StatusPill, _SyncPill, _ConnectStepLine (+45 more)

### Community 11 - "Device Repository Service 2"
Cohesion: 0.04
Nodes (49): cached, cachedAddress, cachedQueries, cachedVerifiedAt, call, called, candidates, candidateStores (+41 more)

### Community 12 - "Sensor Rules Screen"
Cohesion: 0.04
Nodes (47): Color?, _ActiveTag, _api, build, _buildEmpty, _buildRuleView, _channelsOf, color (+39 more)

### Community 13 - "Reachability Monitor"
Cohesion: 0.04
Nodes (48): device_repository_service.dart, _applyNegativeSignal, _applyPositiveSignal, _armBadgeSafetyCheck, _badgeFailCount, badgeLocalProofFresh, _badgeNegative, _badgePositive (+40 more)

### Community 14 - "App Theme"
Cohesion: 0.05
Nodes (44): BuildContext, dark_theme.dart, _, appColors, AppRadius, AppShadows, AppSpacing, AppTheme (+36 more)

### Community 15 - "Root"
Cohesion: 0.05
Nodes (30): Any, bonsoir_darwin, Cocoa, Flutter, AppDelegate, Bool, SceneDelegate, RunnerTests (+22 more)

### Community 16 - "Mqttgateway"
Cohesion: 0.08
Nodes (14): classifyIp(), classifyIpv4(), classifyIpv6(), isAllZerosV6(), isLoopbackV6(), isValidLocalIp(), net, MqttGateway (+6 more)

### Community 17 - "Provisioning Service"
Cohesion: 0.05
Nodes (40): body, _canonicalMacRe, ClaimDeviceSnapshot, classifyDeleteOutcome, classifyWifiTest, cleaned, containsMac, debugTrace (+32 more)

### Community 18 - "Schedule Form Screen"
Cohesion: 0.05
Nodes (39): _api, build, _buildRangeRow, _channels, child, _conflictMessage, createState, _dayLabels (+31 more)

### Community 19 - "Schedulesyncservice"
Cohesion: 0.10
Nodes (37): allocateSlots(), allocationView(), buildRuleText(), { compile, MAX_TIMERS, MAX_RULE_LENGTH }, computeWrites(), crypto, Device, deviceSyncGates (+29 more)

### Community 20 - "Schedule List Screen"
Cohesion: 0.05
Nodes (37): _ActiveTag, _add, _api, build, canAdd, canEdit, _channelsOf, createState (+29 more)

### Community 21 - "Rule Form Screen"
Cohesion: 0.06
Nodes (34): _action, _api, build, _channels, child, color, _condition, createState (+26 more)

### Community 22 - "Rules Page"
Cohesion: 0.06
Nodes (33): _addRule, _api, build, _buildHeader, _channelsOf, color, createState, _deleteRule (+25 more)

### Community 23 - "Stees Nav Bar"
Cohesion: 0.07
Nodes (30): channels, DeviceType, DeviceTypeInfo, build, DeviceTypePicker, icon, label, onChanged (+22 more)

### Community 24 - "Add Sensor Screen"
Cohesion: 0.06
Nodes (31): DropdownMenuItem, _add, _adding, _api, autoClose, build, _buildForm, _buildIntro (+23 more)

### Community 25 - "Mainactivity"
Cohesion: 0.15
Nodes (8): MainActivity, ConnectivityManager, FlutterActivity, FlutterEngine, IntArray, MethodChannel, Network, WifiManager

### Community 26 - "Packageon"
Cohesion: 0.06
Nodes (30): dependencies, bcryptjs, bonjour, cors, express, jsonwebtoken, luxon, mongoose (+22 more)

### Community 27 - "Server"
Cohesion: 0.07
Nodes (27): app, { authMiddleware, JWT_SECRET }, authRoutes, { configuredBrokerInfo }, controlRoutes, cors, delay(), Device (+19 more)

### Community 28 - "Sensors Page"
Cohesion: 0.07
Nodes (28): add_sensor_screen.dart, _AddButton, _api, build, _buildEmpty, _buildSensorList, createState, deviceName (+20 more)

### Community 29 - "Provision Device Screen.D 2"
Cohesion: 0.10
Nodes (29): _Field, AddDeviceScreen, _AddDeviceScreenState, AddSensorScreen, _AddSensorScreenState, _ResultDialog, _ResultDialogState, _WaterCardBody (+21 more)

### Community 30 - "Main"
Cohesion: 0.07
Nodes (28): _auth, AuthGate, _AuthGateState, build, ChannelConfig, channels, _checkAuth, _checking (+20 more)

### Community 31 - "Mqttcommand.Test"
Cohesion: 0.09
Nodes (13): DeviceRegistry, assert, assertTelemetryIpRejected(), gateway(), ipStateGateway(), makeClient(), { MqttGateway }, runtimeState (+5 more)

### Community 32 - "Tasmotaconfigclient"
Cohesion: 0.13
Nodes (11): CONFIG_CMD_TOPIC(), CONFIG_RESULT_TOPIC(), mqtt, TasmotaConfigClient, assert, configClient(), makeClient(), scheduleSyncService (+3 more)

### Community 33 - "Provision Remove Device T"
Cohesion: 0.08
Nodes (26): FilledButton, DeviceDuplicateStatus, getDevices, getMqttBrokerInfo, main, pumpWizard, code, deviceSeen (+18 more)

### Community 34 - "Device Transport Test.Dar"
Cohesion: 0.07
Nodes (27): call, called, _CmFake, control, controlCalls, controlError, delay, _deviceId (+19 more)

### Community 35 - "My Application.Cc"
Cohesion: 0.09
Nodes (22): FlPluginRegistry, fl_register_plugins(), main(), first_frame_cb(), my_application_activate(), my_application_class_init(), my_application_dispose(), my_application_init() (+14 more)

### Community 36 - "Devices Page Delete Test."
Cohesion: 0.07
Nodes (26): connect, deleteCalls, deleteDevice, _deviceId, disconnect, dispose, failWith, _FakeSocket (+18 more)

### Community 37 - "Local Device Discovery.Da"
Cohesion: 0.08
Nodes (24): dart:async, addresses, _browseTasmota, cachedAddress, _CachedEntry, cachedVerifiedAt, _decodeEntry, DeviceLocator (+16 more)

### Community 38 - "Login Screen"
Cohesion: 0.08
Nodes (23): AnimationController, _api, _auth, controller, createState, dispose, _err, _fade (+15 more)

### Community 39 - "Schedulesyncservice.Test."
Cohesion: 0.11
Nodes (17): assert, { compile }, dailySchedule(), defaultTimer(), deviceDoc, deviceState(), fakeDeviceModel, fakeScheduleModel (+9 more)

### Community 40 - "Device Transport"
Cohesion: 0.08
Nodes (23): cause, ChannelReport, channels, code, control, DeviceTransportSource, getStatus, isAvailabilityFailure (+15 more)

### Community 41 - "Rules"
Cohesion: 0.09
Nodes (17): mongoose, ruleSchema, mongoose, sensorSchema, Device, express, router, Rule (+9 more)

### Community 42 - "Signup Screen"
Cohesion: 0.09
Nodes (22): _api, _auth, build, _confirmCtl, controller, createState, dispose, _err (+14 more)

### Community 43 - "Controlregistry.Test"
Cohesion: 0.10
Nodes (19): Device, deviceRegistry, express, mqttGateway, router, runtimeState, { timeline }, Device (+11 more)

### Community 44 - "Scheduledryrunservice"
Cohesion: 0.13
Nodes (18): buildDryRun(), buildPreview(), { compile }, { DateTime }, Device, dryRunForDevice(), PROBE_MINUTES, referenceScheduleState() (+10 more)

### Community 45 - "Main Shell"
Cohesion: 0.09
Nodes (21): devices_page.dart, _auth, build, _buildHeader, createState, _currentIndex, dispose, _handleSessionExpired (+13 more)

### Community 46 - "Local Device Cache"
Cohesion: 0.10
Nodes (20): auth_service.dart, _accountScopeOverride, cachedDevices, _defaultScope, kAccountSnapshotKey, kLocalDevicesKey, loadAccountSnapshotMacs, LocalDeviceCache (+12 more)

### Community 47 - "Deviceprovisioning.Test.J"
Cohesion: 0.10
Nodes (10): authMiddleware(), jwt, assert, { authMiddleware, JWT_SECRET }, CID, { DeviceProvisioningService }, FakeDeviceModel, jwt (+2 more)

### Community 48 - "Root 2"
Cohesion: 0.11
Nodes (15): main, _id, main, _id, _key, main, main, main (+7 more)

### Community 49 - "Project Report.Md"
Cohesion: 0.12
Nodes (20): Dashboard HTML, Device Provisioning, Device Registry, ESP32 Sensor Node, Flutter App, JWT Authentication, MQTT Gateway, MQTT Protocol (+12 more)

### Community 50 - "Root 3"
Cohesion: 0.11
Nodes (17): build, createState, _openWizard, _wifiChannel, build, compact, _drawWindow, _totalMin (+9 more)

### Community 51 - "Schedulecompiler"
Cohesion: 0.18
Nodes (16): ALL_DAYS, channelsForSchedule(), compile(), daysMask(), expandDays(), scheduleKey(), scheduleLabel(), statesForDay() (+8 more)

### Community 52 - "Scheduleparity.Test"
Cohesion: 0.14
Nodes (16): assert, assertParity(), BOUNDARY, { compile }, { DateTime }, DEVICE, hhmm(), mismatchReport() (+8 more)

### Community 53 - "Api Service Token Cache"
Cohesion: 0.11
Nodes (18): dart:convert, Duration, AuthService, calls, close, closed, _CountingAuth, delay (+10 more)

### Community 54 - "Schedulesroute.Test"
Cohesion: 0.12
Nodes (15): assert, Device, express, invalidBody, makeApp(), originals, Schedule, scheduleEngine (+7 more)

### Community 55 - "Deviceprovisioningservice"
Cohesion: 0.16
Nodes (10): Device, DeviceProvisioningService, deviceRegistry, mqttGateway, { normalizeMac }, RuntimeState, normalizeMac(), assert (+2 more)

### Community 56 - "Schedulecutover.Test"
Cohesion: 0.12
Nodes (10): assert, { dailySchedule }, Device, runtimeState, Schedule, scheduleEngine, scheduleSyncRetry, scheduleSyncService (+2 more)

### Community 57 - "Devices"
Cohesion: 0.12
Nodes (15): { authMiddleware }, Device, deviceProvisioningService, deviceRegistry, express, mqttGateway, { normalizeMac }, PROVISION_ERROR_STATUS (+7 more)

### Community 58 - "Schedulesynctrigger"
Cohesion: 0.14
Nodes (7): scheduleSyncService, ScheduleSyncTrigger, assert, makeAutoSync(), { ScheduleSyncTrigger }, syncService, { test, afterEach }

### Community 59 - "Local Ip"
Cohesion: 0.12
Nodes (15): dart:io, a, addr, endpointHost, firstColon, host, _isUnspecified, isUsableHttpHost (+7 more)

### Community 60 - "Badge Truth Test"
Cohesion: 0.13
Nodes (14): DateTime?, DeviceRepositoryService, buildMonitor, _FakeRepo, isDeviceOnSameNetwork, main, now, sameWifi (+6 more)

### Community 61 - "Scheduleengine"
Cohesion: 0.21
Nodes (5): { DateTime }, minutesFromHhmm(), runtimeState, Schedule, ScheduleEngine

### Community 62 - "Theme Controller"
Cohesion: 0.15
Nodes (12): bool get, ChangeNotifier, isDark, load, _prefKey, setDark, ThemeController, _themeMode (+4 more)

### Community 63 - "Control Timeline"
Cohesion: 0.15
Nodes (12): _anchors, begin, ControlTimeline, end, mark, _monoMs, _monotonic, nextControlOpId (+4 more)

### Community 64 - "Cloud Device Transport.Da"
Cohesion: 0.17
Nodes (11): api_service.dart, device_transport.dart, DeviceTransportSource get, _api, CloudDeviceTransport, control, getDevices, getStatus (+3 more)

### Community 65 - "Schedules"
Cohesion: 0.18
Nodes (9): Device, express, minutesFromHhmm(), router, Schedule, scheduleEngine, scheduleSyncService, scheduleSyncTrigger (+1 more)

### Community 67 - "Devices Page Local Test.D 2"
Cohesion: 0.17
Nodes (12): ApiService, _FakeCloudApi, _FakeCloudApi, _DeleteApi, _CloudApi, _CloudDownApi, _HangingCloudApi, _ConnectFakeApi (+4 more)

### Community 68 - "Auth Service"
Cohesion: 0.17
Nodes (11): clear, getToken, getUsername, isLoggedIn, saveToken, saveUsername, _storage, _tokenKey (+3 more)

### Community 69 - "Root 4"
Cohesion: 0.24
Nodes (9): wWinMain(), string, wchar_t, CreateAndAttachConsole(), GetCommandLineArguments(), Utf8FromUtf16(), _In_, _In_opt_ (+1 more)

### Community 70 - "Devsync"
Cohesion: 0.18
Nodes (8): deviceSchema, mongoose, Device, express, router, scheduleSyncService, mongoose, seed()

### Community 71 - "Mqttgateway 2"
Cohesion: 0.20
Nodes (9): { classifyIp }, Device, mqtt, powerUpdatesFrom(), Sensor, { timeline }, assert, { powerUpdatesFrom } (+1 more)

### Community 72 - "Schedulesyncretry 2"
Cohesion: 0.18
Nodes (8): Device, runtimeState, Schedule, scheduleSyncService, scheduleSyncTrigger, assert, runtimeState, { test }

### Community 73 - "Control.Test"
Cohesion: 0.22
Nodes (10): assert, controlRouter, Device, express, makeApp(), mqttGateway, originals, runtimeState (+2 more)

### Community 74 - "Manifeston"
Cohesion: 0.18
Nodes (10): background_color, description, display, icons, name, orientation, prefer_related_applications, short_name (+2 more)

### Community 75 - "Auth"
Cohesion: 0.20
Nodes (8): mongoose, userSchema, bcrypt, express, jwt, { JWT_SECRET }, router, User

### Community 77 - "Devsyncroute.Test"
Cohesion: 0.24
Nodes (9): assert, Device, devSyncRouter, express, makeApp(), originals, scheduleSyncService, start() (+1 more)

### Community 78 - "Channel State Machine.Dar 2"
Cohesion: 0.20
Nodes (10): ChannelEvent, CloudHealth, CloudReport, LocalReport, LwtOffline, PollFailure, RestResponse, SocketUpdate (+2 more)

### Community 79 - "Mock Tasmota"
Cohesion: 0.28
Nodes (8): app, applyPower1(), bonjour, buildStatusPayload(), express, PORT, relays, runCommand()

### Community 81 - "Sensors"
Cohesion: 0.25
Nodes (6): Device, express, mqttGateway, router, Rule, Sensor

### Community 82 - "Channel State Machine Tes"
Cohesion: 0.25
Nodes (7): config, main, rep, t0, unchanged, package:smart_home_app/services/channel_state_machine.dart, package:smart_home_app/services/device_transport.dart

### Community 83 - "Brokerinfo.Test"
Cohesion: 0.43
Nodes (5): configuredBrokerInfo(), resolveBrokerInfo(), assert, {
  resolveBrokerInfo,
  configuredBrokerInfo,
}, { test }

### Community 84 - "Schedulesimulator"
Cohesion: 0.52
Nodes (6): extractRuleActions(), minutesFromTime(), minutesOfDay(), simulateCompiledPlan(), steesDay(), tasmotaDayPosition()

### Community 85 - "Root 5"
Cohesion: 0.29
Nodes (7): DevicesPage, _DevicesPageState, ProvisionDeviceScreen, _ProvisionDeviceScreenState, TickerProviderStateMixin, WidgetsBindingObserver, WithAck

### Community 86 - "Schedule"
Cohesion: 0.33
Nodes (3): mongoose, scheduleSchema, timeRangeSchema

### Community 87 - "Virtual Mqtt Device"
Cohesion: 0.40
Nodes (4): client, mqtt, relays, SENSOR_BASE

### Community 88 - "Root 6"
Cohesion: 0.50
Nodes (4): Exception, ApiException, DeviceTransportException, _RefererGatedException

### Community 89 - "Virtual Sonoff"
Cohesion: 0.50
Nodes (3): app, express, relays

### Community 90 - "Devices Page 2"
Cohesion: 0.67
Nodes (3): AnimatedWidget, _RippleIcon, _WaterCard

### Community 91 - "Reachability Monitor 2"
Cohesion: 0.67
Nodes (3): @immutable, BadgeTruthState, ReachabilityState

### Community 92 - "Api Service 2"
Cohesion: 0.67
Nodes (3): @visibleForTesting, clearTokenCacheForTesting, getCachedTokenForTesting

### Community 93 - "Login Screen 2"
Cohesion: 0.67
Nodes (3): build, _openRule, MaterialPageRoute

### Community 94 - "Root 7"
Cohesion: 0.67
Nodes (3): main, Route device_status, Route device_update

## Knowledge Gaps
- **1788 isolated node(s):** `jwt`, `express`, `bonjour`, `app`, `PORT` (+1783 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **8 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ApiService` connect `Devices Page Local Test.D 2` to `Provision Device Screen.D`, `Devices Page`, `Cloud Device Transport.Da`, `Api Service`?**
  _High betweenness centrality (0.015) - this node is a cross-community bridge._
- **Why does `_` connect `App Theme` to `Root 3`, `Sensor Rules Screen`?**
  _High betweenness centrality (0.006) - this node is a cross-community bridge._
- **Why does `DeviceRepositoryService` connect `Badge Truth Test` to `Provision Device Screen.D`, `Devices Page`, `Reachability Monitor`, `Device Repository Service`?**
  _High betweenness centrality (0.006) - this node is a cross-community bridge._
- **What connects `jwt`, `express`, `bonjour` to the rest of the system?**
  _1788 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Provision Device Screen.D` be split into smaller, more focused modules?**
  _Cohesion score 0.008130081300813009 - nodes in this community are weakly interconnected._
- **Should `Devices Page` be split into smaller, more focused modules?**
  _Cohesion score 0.014184397163120567 - nodes in this community are weakly interconnected._
- **Should `Provision Full Flow Test.` be split into smaller, more focused modules?**
  _Cohesion score 0.022988505747126436 - nodes in this community are weakly interconnected._