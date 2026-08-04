# STEES Flutter App — UI/UX Inventory & Documentation

Reference document for planning future design changes. Read-only analysis of `flutter_app/lib/`. No code was modified.

App: **STEES — Smart Irrigation**. Remote-controllable irrigation via Sonoff/Tasmota relays + ESP32 sensors over MQTT, with rule-engine and time-schedule control.

---

## 1. Screen Inventory

Every screen file in `flutter_app/lib/screens/` plus the Home page (defined in `main.dart`).

---

### 1.1 AuthGate (in `main.dart`, lines 46–108)

- **File:** `flutter_app/lib/main.dart`
- **Class:** `AuthGate` (widget) + `_SteesLogo` (lines 110–133)
- **Purpose:** App entry point; shows a branded splash while checking the stored JWT, then routes to Home or Login.
- **Navigation:**
  - Entered: first screen via `home: const AuthGate()` in `MaterialApp`.
  - Exit: `_loggedIn ? HomePage() : LoginScreen()` (swaps child; not a route push).
  - Reached again after logout via `pushReplacement` from Home, and via the `/home` named route (which also just renders this gate).
- **Layout structure:**
  ```
  MaterialApp
  └─ AuthGate
     ├─ (checking) Scaffold > GradientContainer > Center > FadeIn(Opacity) > Column [SteesLogo, Spinner]
     └─ (decided) HomePage | LoginScreen
  ```
- **Key UI elements:**
  - `_SteesLogo`: circular gradient (stream→leaf) badge with "S" letter, glow shadow. Size param (72 splash / 32 header).
  - Fading splash with `TweenAnimationBuilder` (1.2 s) and a `CircularProgressIndicator`.
- **State shown:** `_checking` (splash vs. decided), `_loggedIn`.
- **Conditional/dynamic:** None beyond the auth state swap.

---

### 1.2 HomePage (in `main.dart`, lines 248–762)

- **File:** `flutter_app/lib/main.dart`
- **Class:** `HomePage` / `_HomePageState` (with `TickerProviderStateMixin`); supporting widgets `_ActionRail` (135–195), `_RailCell` (197–231), `_WaterCard` (764–805), `_WaterCardBody` (808–916), `_DropletToggle` (918–965), `_WaterRippleIcon` (967–995), `_ConnectionPip` (997–1047).
- **Purpose:** Main control dashboard — select a device, toggle irrigation channels (water zones), view linked sensors, and reach add-device / add-sensor / schedules / logout.
- **Navigation:**
  - Entered: after successful auth (gate), or `/home` named route.
  - Exit: pushes `AddDeviceScreen`, `AddSensorScreen`, `SensorRulesScreen`, `RuleFormScreen`, `ScheduleListScreen`; logout `pushReplacement` → `AuthGate`.
  - Channel toggles call the control API (no navigation).
- **Layout structure:**
  ```
  Scaffold > GradientContainer > SafeArea > Column
  ├─ _buildHeader()      Row [SteesLogo, STEES/Smart Irrigation, _ConnectionPip, _ActionRail]
  ├─ _buildDeviceSelector()  (hidden when ≤1 device) horizontal chip ListView
  └─ Expanded > _buildBody()
     ├─ (loading) spinner
     ├─ (no devices) empty state
     └─ Column
        ├─ (if sensors) SENSORS header + sensor cards (each: name/id/online tag/device/value + Rules & Add Rule buttons)
        └─ Expanded > GridView.count of _WaterCard
  ```
- **Key UI elements:**
  - `_ActionRail`: a fixed 38 px pill with 4 `_RailCell`s divided by hairlines — **Add device** (stream, filled), **Add sensor** (leaf), **Schedules** (sunlight), **Logout** (FF7A7A). Tooltips on each.
  - `_ConnectionPip`: pulsing 10–13 px dot, green `stream` when socket connected, grey `mist` when not.
  - Device selector: horizontal scrolling `AnimatedContainer` chips; selected = filled `stream`, unselected = outline `mist`.
  - `_WaterCard`: an animated 24 px-radius tile per channel. Entrance scale/fade (`Curves.easeOutBack`, staggered 120 ms), hover scale (2%), border/shadow color shift on toggle, `FLOWING`/`DRY` status text, water-drop icon.
  - `_DropletToggle`: 44×26 custom switch, sliding round knob, loading spinner state, droplet glyph.
  - `_WaterRippleIcon`: pulsing expanding ring + icon when channel is ON.
  - Sensor card: circular icon, name/ID, Online/Offline pill, value (`_fmtValue`, e.g. "42%"), `Rules` outlined button + `Add Rule` filled button.
- **State shown:** `_connected` (socket), `_devices`, `_sensors`, `_selectedDeviceId`, `_deviceChannels`, per-channel `channelStates`/`_loading`, live values from socket events (`device_update`, `sensor_update`).
- **Conditional/dynamic:**
  - Device selector hidden if `_devices.length <= 1`.
  - Channel grid: `crossAxisCount` = **1** full-width card if `_deviceChannels == 1`, else **2×2** (aspect 0.85 vs 1.0).
  - Sensors section only when the selected device has sensors; filtered by `deviceId`.
  - Socket events only update sensors already on screen for the selected device.

---

### 1.3 LoginScreen (`screens/login_screen.dart`)

- **Class:** `LoginScreen` / `_LoginScreenState` (with `SingleTickerProviderStateMixin`); helper `_Field`.
- **Purpose:** Authenticate returning users (username + password) and store the JWT.
- **Navigation:**
  - Entered: from `AuthGate` when no stored token.
  - Exit: on success `pushReplacementNamed('/home')`; "Sign Up" `TextButton` pushes `SignupScreen`; back gesture returns to gate.
- **Layout structure:**
  ```
  Scaffold > GradientContainer > SafeArea > FadeTransition > Center > SingleChildScrollView > Column
  ├─ Brand circle ("S") + STEES + Smart Irrigation
  ├─ _Field(Username)      (next action)
  ├─ _Field(Password)      (obscured, visibility toggle, done → submit)
  ├─ FilledButton "Sign In" (loading spinner)
  └─ TextButton "Don't have an account? Sign Up"
  ```
- **Key UI elements:** two text fields, visibility toggle, full-width submit button (52 px), spinner-on-loading, inline "Sign Up" link.
- **State shown:** `_loading`, `_obscure`.
- **Conditional/dynamic:** Password suffix toggle; button disabled+spinner while loading.

---

### 1.4 SignupScreen (`screens/signup_screen.dart`)

- **Class:** `SignupScreen` / `_SignupScreenState`; helper `_Field` (duplicate of Login's).
- **Purpose:** Create a new account.
- **Navigation:**
  - Entered: pushed from `LoginScreen` ("Sign Up").
  - Exit: on success `pushNamedAndRemoveUntil('/home', (_) => false)` (clears stack); "Already have an account? Sign In" `TextButton` pops back; back button pops.
- **Layout structure:** mirrors Login (no logo) — Title "Create Account" + "Join STEES", three fields (Username, Password, Confirm Password), submit button, sign-in link. Wrapped in `SingleChildScrollView` for keyboard safety.
- **Key UI elements:** 3 text fields, password visibility toggle on confirm field, full-width submit (52 px), spinner-on-loading.
- **State shown:** `_loading`, `_obscure`.
- **Conditional/dynamic:** None notable beyond loading state.

---

### 1.5 AddDeviceScreen (`screens/add_device_screen.dart`)

- **Class:** `AddDeviceScreen` / `_AddDeviceScreenState`; helpers `_DeviceTypePicker`, `_Field` (subtitle variant).
- **Purpose:** Claim a Tasmota controller by Device ID so its channels can be controlled.
- **Navigation:**
  - Entered: pushed from Home `_ActionRail` → "Add device".
  - Exit: on success `Navigator.pop(true)` → Home reloads device list; back arrow / swipe pops.
- **Layout structure:**
  ```
  Scaffold > AppBar("Add Device") > GradientContainer > SafeArea > SingleChildScrollView
  └─ Column > intro card > _Field(Device ID) > _Field(Device Name) > _DeviceTypePicker > FilledButton "Claim Device"
  ```
  (Intro card: water-drop icon + "Enter the Device ID from your Tasmota controller.")
- **Key UI elements:**
  - Two text fields with helper subtitles (`sonoff_8F9BC4`, `Garden Controller`).
  - `_DeviceTypePicker`: `SegmentedButton` "1 Relay" / "4 Relays" (lightbulb vs grid icons).
  - Full-width "Claim Device" button (50 px), spinner-on-loading.
- **State shown:** `_channels` (1 or 4).
- **Conditional/dynamic:** Segmented button toggles channel count; button disabled while claiming. Note: the intro card content is only visible above the fold; scrollable so keyboard doesn't overflow (this is the known keyboard-overflow fix site).

---

### 1.6 AddSensorScreen (`screens/add_sensor_screen.dart`)

- **Class:** `AddSensorScreen` / `_AddSensorScreenState`; helpers `_SearchingDialog`, `_ResultDialog`, `_DeviceDropdown`, `_Field`.
- **Purpose:** Link an ESP32 sensor to a claimed Sonoff device (verified over MQTT before saving).
- **Navigation:**
  - Entered: pushed from Home `_ActionRail` → "Add sensor".
  - Exit: on success pops `true` (Home reloads sensors); back arrow pops.
- **Layout structure:**
  ```
  Scaffold > AppBar("Add Sensor") > GradientContainer > SafeArea > SingleChildScrollView > Column
  ├─ intro card ("LINK A SENSOR" + verification note)
  └─ form card ("Sensor details")
     ├─ _Field(Sensor Name)   (e.g. Soil Moisture)
     ├─ _Field(Sensor ID)     (e.g. soil_1, done → add)
     └─ _DeviceDropdown        (choose Sonoff device)
  └─ FilledButton "Add Sensor"
  ```
- **Key UI elements:**
  - Two text fields, `DropdownButtonFormField` listing claimed devices as "name (deviceId)".
  - `_SearchingDialog`: modal spinner "Searching for sensor…" (non-dismissible).
  - `_ResultDialog`: modal icon + title + message; auto-closes (1.5 s) on success, has OK button on failure. Green `leaf` check for success, red `FF7A7A` error icon for failure.
- **State shown:** `_devices`, `_selectedDeviceId`, `_adding`.
- **Conditional/dynamic:** Dropdown hint switches to "No Sonoff devices yet" when empty; sensor-ID field submit triggers add; dialogs replace each other via `rootNavigator` pop then show.

---

### 1.7 SensorRulesScreen (`screens/sensor_rules_screen.dart`)

- **Class:** `SensorRulesScreen` / `_SensorRulesScreenState`.
- **Purpose:** List and manage sensor-triggered rules for one sensor.
- **Navigation:**
  - Entered: from Home sensor card → "Rules" outlined button, passing `sensorId` + `sensorName`.
  - Exit: "Add Rule" pushes `RuleFormScreen` (with sensor context); back arrow pops; returns to Home.
- **Layout structure:**
  ```
  Scaffold > AppBar("Rules") > GradientContainer > SafeArea > Column
  ├─ header (sensor name + ID)
  ├─ FilledButton.icon "Add Rule"
  └─ Expanded
     ├─ spinner | empty state
     └─ ListView.separated of rule tiles
  ```
- **Key UI elements:**
  - Rule tile: name + descriptive line (`CH1 -> below 30 -> ON`), enable `Switch`, delete `IconButton`.
  - Delete confirmation via `AlertDialog` ("Delete rule?").
- **State shown:** `_rules` (filtered by `sensorId`), `_loading`.
- **Conditional/dynamic:** empty-state with `rule_outlined` icon; optimistic toggle with revert-on-error.

---

### 1.8 RuleFormScreen (`screens/rule_form_screen.dart`)

- **Class:** `RuleFormScreen` / `_RuleFormScreenState`.
- **Purpose:** Create a sensor rule (channel + condition + threshold + action). Note: **create-only**, no edit mode.
- **Navigation:**
  - Entered: pushed from `SensorRulesScreen` ("Add Rule") or directly from Home sensor card ("Add Rule").
  - Exit: on success pops `true` (caller reloads rules); back pops.
- **Layout structure:**
  ```
  Scaffold > AppBar("Add Rule") > GradientContainer > SafeArea > SingleChildScrollView > Column
  ├─ SENSOR banner (name + ID)
  └─ form card ("Rule details")
     ├─ _Field(Rule name)
     ├─ CHANNEL: Dropdown (CH1..maxChannel) + SegmentedButton ON/OFF
     ├─ WHEN VALUE IS: SegmentedButton Below/Above
     ├─ _Field(Threshold, numeric decimal)
     └─ FilledButton "Create Rule"
  ```
- **Key UI elements:** name field, channel dropdown (up to `maxChannel`), two `SegmentedButton`s (ON/OFF with leaf/sunlight colors; Below/Above with stream), numeric threshold field, full-width submit (50 px).
- **State shown:** `_channel`, `_action`, `_condition`, `_saving`.
- **Conditional/dynamic:** ON/OFF segment colors switch (leaf vs sunlight); button spinner while saving.

---

### 1.9 ScheduleListScreen (`screens/schedule_list_screen.dart`)

- **Class:** `ScheduleListScreen` / `_ScheduleListScreenState`; helpers `_DeviceSection`, `_ScheduleTile`, `_EmptyDevices`, `_ActiveTag`.
- **Purpose:** View and manage time-based schedules, grouped per device (each device has its own section with its own Add button).
- **Navigation:**
  - Entered: from Home `_ActionRail` → "Schedules".
  - Exit: per-device "Add" pushes `ScheduleFormScreen`; tile tap → edit form; back arrow pops.
- **Layout structure:**
  ```
  Scaffold > AppBar("Schedules") > GradientContainer > SafeArea
  ├─ spinner | (no devices) empty state
  └─ ListView > for each device: _DeviceSection
     ├─ header Row [device name + ID, FilledButton "Add"]
     ├─ "CH1–CHn" caption
     └─ list of _ScheduleTile | "No schedules for this device" placeholder
  ```
- **Key UI elements:**
  - `_DeviceSection`: device title, `ID:` line, per-device Add button, channel-range caption.
  - `_ScheduleTile`: name + `_ActiveTag` (Active/Off pill), "Channels: CH1, CH2", `WindowTimeline` preview (compact), recurrence summary, enable `Switch`, edit + delete `IconButton`s in a bottom-right action row.
  - Delete `AlertDialog` confirmation.
- **State shown:** `_devices`, `_schedules` (all, grouped in-build), `_loading`.
- **Conditional/dynamic:** `_ActiveTag` green/grey by `enabled`; per-device section shows placeholder when that device has none; add buttons are per-device, not global.

---

### 1.10 ScheduleFormScreen (`screens/schedule_form_screen.dart`)

- **Class:** `ScheduleFormScreen` / `_ScheduleFormScreenState`; helpers `_DeviceBanner`, `_SectionCard`, `_ChannelChip`, plus inline `_buildRangeRow` / `_timeButton`.
- **Purpose:** Create or **edit** a time schedule (name, channels, recurrence, windows) for a specific device.
- **Navigation:**
  - Entered: from `ScheduleListScreen` (per-device "Add", or tapping an existing tile to edit).
  - Exit: on save pops `true` (list reloads); back pops.
- **Layout structure:**
  ```
  Scaffold > AppBar("New/Edit Schedule") > GradientContainer > SafeArea > SingleChildScrollView
  └─ Column
     ├─ _DeviceBanner (device name + ID)
     ├─ _SectionCard "NAME"      → TextField
     ├─ _SectionCard "CHANNELS"  → Wrap of _ChannelChip (CH1..maxChannel)
     ├─ _SectionCard "REPEATS"   → SegmentedButton Daily/Custom days
     │                              └─ (custom) Wrap of day chips Mon..Sun
     ├─ _SectionCard "WINDOWS"   → WindowTimeline + repeatable time-range rows
     │                              (each: Start time button | End time button | remove icon)
     │                              + "Add another window" TextButton
     └─ FilledButton "Create/Save Schedule"
  ```
- **Key UI elements:**
  - `_SectionCard`: eyebrow label with 2 px accent underline + optional description; consistent 20 px radius container.
  - `_ChannelChip`: tappable pill, filled w/ glow when selected.
  - Repeatable time-range rows: each is a card with two `_timeButton`s (label + HH:mm) and a remove icon (hidden when only one row). Up to 6 windows; "Add another window" disabled at 6.
  - `WindowTimeline` (live 24 h preview of current ranges).
  - Day picker (custom recurrence): 7 `_ChannelChip`s labeled Mon…Sun.
- **State shown:** form fields incl. `_channels` (Set), `_recurrenceType`, `_daysOfWeek` (Set), `_rangeStarts`/`_rangeEnds` (Lists of `TimeOfDay`), `_saving`, `_isEdit`.
- **Conditional/dynamic:**
  - Day-of-week picker only shown when `_recurrenceType == 'custom'`.
  - Channel chips count = device `maxChannel`.
  - Range-row remove icon only when >1 row.
  - Validation rejects overnight/inverted ranges and empty custom-day sets (inline SnackBar errors).
  - Edit mode prefills from `existing` and switches button label to "Save Changes".

---

## 2. Design System Inventory

### 2.1 Colors (`flutter_app/lib/theme.dart` → `AppColors`)

| Name | Hex | Typical usage |
|---|---|---|
| `well` | `#0B1922` | Deep background base, card fill for inputs, scaffold bg, text-on-accent |
| `submerged` | `#1A2D3D` | Card/surface fill, input fill on login, dropdown menu |
| `stream` | `#2DD4BF` | Primary teal accent — active/online accents, primary buttons, focused borders, selected chips, brand gradient |
| `leaf` | `#34D399` | Secondary green — online sensor tags, ON/action accents, success dialog, schedule ON borders |
| `sunlight` | `#FBBF24` | Amber — recurrence/event icons, "OFF" action segment |
| `mist` | `#94A3B8` | Secondary text, muted icons, inactive tags, disabled affordances |
| `foam` | `#F1F5F9` | Primary text (near-white) |

**Ad-hoc colors not in the palette:**
- `Color(0xFF0F2332)` — mid-gradient stop used in **every** screen's background gradient (hardcoded everywhere; not in `AppColors`).
- `Color(0xFFFF7A7A)` — delete/error red, used across main, sensor_rules, schedule_list, schedule_form, add_sensor.
- `Colors.redAccent.shade200` — error SnackBar background (everywhere).
- `Colors.white.withValues(alpha: 0.06–0.08)` — hairline borders.
- Gradient brand: `stream → leaf` (logo, WindowTimeline bars).

### 2.2 Typography

- **Global text theme:** `GoogleFonts.interTextTheme(ThemeData.dark().textTheme)` in `MaterialApp` (main.dart:37).
- **Headings / emphasis:** `GoogleFonts.sora` (weights 600/700) — app title, card titles, section eyebrows (with `letterSpacing` 1.6–2.2), button labels.
- **Body / secondary:** `GoogleFonts.inter` — fields, descriptions, captions, values.
- **Common sizes:** 10–12 captions, 13–14 body, 15–18 titles, 24–28 brand. No size constants; sizes are hardcoded per-widget.

### 2.3 Reusable style constants

There are **no shared constants files** for radius/spacing/shadow. Recurring values repeated inline:
- Border radius: **14** (inputs/buttons), **16–20** (cards), **18** (tiles), **24** (channel cards), **12** (small controls/chips), **8** (pills/tags), **4–6** (timeline bars).
- Button heights: **50** (forms), **52** (auth), **46** (list-action buttons), **40** (section Add), **38** (action rail, chip height).
- Screen gradient: `LinearGradient(top→bottom, [well, 0xFF0F2332, well])` — copy-pasted into 9 build methods.
- Error SnackBar style: floating, radius 12, margin 16, red background — duplicated in **every** screen (`_err` methods).

### 2.4 Inconsistencies found

1. **Login/Signup/AddDevice use raw hex instead of `AppColors`.** `login_screen.dart`, `signup_screen.dart`, and `add_device_screen.dart` hardcode `Color(0xFF0B1922)`, `Color(0xFF1A2D3D)`, `Color(0xFF2DD4BF)`, `Color(0xFF94A3B8)`, `Color(0xFFF1F5F9)` throughout, while every newer screen imports and uses `AppColors`. Login's gradient also hardcodes the palette values (login lines 69) rather than `AppColors.well`.
2. **`_Field` widget is duplicated** in 4 files with 3 slightly different shapes:
   - `login_screen.dart` / `signup_screen.dart`: `_Field` with `suffix`/`onSubmit`/`next`, fill `#1A2D3D`.
   - `add_device_screen.dart`: `_Field` with `subtitle` (helperText), fill `#0B1922`.
   - `add_sensor_screen.dart` and `rule_form_screen.dart` / `schedule_form_screen.dart`: variant with `subtitle` + `onSubmit`, fill `AppColors.well`.
   These should be one shared `AppTextField`.
3. **Error SnackBar duplicated** as an `_err()` method in 8 classes (all screens + Home) with identical styling. Should be a shared helper.
4. **Screen background gradient duplicated** inline in 9 places (AuthGate, Login, Signup, Home, AddDevice, AddSensor, SensorRules, RuleForm, ScheduleList, ScheduleForm). Should be a shared `AppBackground` widget or theme constant.
5. **AppBar style duplicated** — every sub-screen sets the same `sora 18 w600 foam` title + `well` bg + `mist` icon theme inline.
6. **Online/status pill** logic duplicated: Home sensor card has an Online/Offline pill; schedule tile has `_ActiveTag`; rule tile uses a colored border instead. Three different visual encodings of the same "enabled/online" concept.
7. **Brand logo duplicated:** `_SteesLogo` in main.dart vs. an identical inline circle in `login_screen.dart` (and `signup_screen.dart` shows no logo). 
8. **SegmentedButton styling** duplicated across AddDevice, RuleForm, ScheduleForm with slightly different accent colors.
9. **Delete confirm `AlertDialog`** duplicated in `SensorRulesScreen` and `ScheduleListScreen` (near-identical markup).
10. **`_DeviceBanner` (ScheduleForm) vs. sensor banner (RuleForm) vs. header block (SensorRules)** are three variants of the same "context banner" pattern.

---

## 3. Reusable Widgets

### 3.1 Shared across screens (single source of truth)

| Widget | Defined in | Used by |
|---|---|---|
| `WindowTimeline` | `lib/widgets/window_timeline.dart` | `ScheduleFormScreen` (live preview), `ScheduleListScreen` (card preview). Uses `LayoutBuilder`; `compact` flag changes track/height. |
| `AppColors` | `lib/theme.dart` | All screens (except Login/Signup/AddDevice which hardcode). |
| `GoogleFonts` sora/inter | global | everywhere. |

### 3.2 Private widgets (file-scoped, used by one screen)

- main.dart: `_SteesLogo`, `_ActionRail`, `_RailCell`, `_WaterCard`, `_WaterCardBody`, `_DropletToggle`, `_WaterRippleIcon`, `_ConnectionPip`.
- login/signup: `_Field` (duplicated in both).
- add_device: `_DeviceTypePicker`, `_Field`.
- add_sensor: `_SearchingDialog`, `_ResultDialog`, `_DeviceDropdown`, `_Field`.
- sensor_rules: rule tile inline.
- rule_form: inline `_label`, `_inputDec`.
- schedule_list: `_DeviceSection`, `_ScheduleTile`, `_EmptyDevices`, `_ActiveTag`.
- schedule_form: `_DeviceBanner`, `_SectionCard`, `_ChannelChip`, inline `_buildRangeRow`, `_timeButton`, `_inputDec`.

### 3.3 Duplicated patterns flagged for extraction

- `_Field` text-input (4 copies — see §2.4.2).
- Error SnackBar `_err` (8 copies).
- Background gradient container (10 copies).
- Sub-screen AppBar (7 copies).
- Delete confirmation dialog (2 copies, near-identical).
- Online/enabled status pill (3 variants — Home, schedule `_ActiveTag`, rule tile border).
- Input decoration helper `_inputDec` (RuleForm + ScheduleForm).
- SegmentedButton config (3 screens).
- "SectionCard" pattern (ScheduleForm `_SectionCard`) is a good candidate to generalize for RuleForm/AddSensor form cards.

---

## 4. Navigation Map

```
[App launch]
   └─ AuthGate (checks stored JWT)
      ├─ no token ──► LoginScreen
      │                ├─ (submit) ──► Home
      │                └─ "Sign Up" ──► SignupScreen
      │                                    ├─ (submit) ──► Home (clears stack)
      │                                    └─ "Sign In" ──► (back) LoginScreen
      └─ token ──► Home

Home
  ├─ ActionRail "Add device"  ──► AddDeviceScreen ──(Claim)──► pop(true) → Home
  ├─ ActionRail "Add sensor"  ──► AddSensorScreen ──(Add, verified)──► pop(true) → Home
  ├─ ActionRail "Schedules"   ──► ScheduleListScreen
  │                              ├─ per-device "Add" ──► ScheduleFormScreen ──(Save)──► pop(true) → list
  │                              └─ tap schedule tile ──► ScheduleFormScreen(edit) ──(Save)──► pop(true) → list
  ├─ sensor card "Rules"      ──► SensorRulesScreen
  │                              ├─ "Add Rule" ──► RuleFormScreen ──(Create)──► pop(true) → rules
  │                              └─ delete ──► AlertDialog ──(confirm)──► delete
  ├─ sensor card "Add Rule"   ──► RuleFormScreen ──(Create)──► pop(true) → Home
  ├─ channel card tap         ──► (no nav) control API toggle
  └─ ActionRail "Log out"     ──► clear JWT ──► pushReplacement AuthGate ──► LoginScreen
```

All sub-screens except Home return to Home/list via `Navigator.pop`; Home reloads data when the pop returns `true`.

---

## 5. Responsiveness / Platform Notes

### 5.1 Form factor assumptions

- **Entirely phone-first.** No `OrientationBuilder`, no tablet/desktop breakpoints, no adaptive layouts. The only width-aware logic is `WindowTimeline` via `LayoutBuilder` (it scales its 24 h strip to available width) and the channel `GridView.count`.
- **Responsive pattern used:** `Expanded`/`Flexible` inside `Row`s (buttons, text ellipsis) and scrollables (`ListView`, `SingleChildScrollView`). No `MediaQuery` usage anywhere.

### 5.2 Keyboard overflow handling

- **Scrollable form screens (safe):** Login, Signup, AddDevice, AddSensor, RuleForm, ScheduleForm all wrap body content in `SingleChildScrollView` (with `BouncingScrollPhysics`), so the keyboard pushes content up instead of overflowing. AddDevice was explicitly made scrollable for this — the pattern is consistently applied to every form.
- **Non-scrollable concern — Home dashboard:** `HomePage._buildBody()` uses `Column > Expanded(GridView)` (main.dart:604). On very short screens the SENSORS header + sensor cards sit above the grid and are **not scrollable** — the whole column is in an `Expanded`; with many sensors or small viewport, sensor cards could push the grid or overflow. Potential overflow site.
- **SensorRulesScreen / ScheduleListScreen:** use `Column > Expanded(ListView)` — safe (list scrolls), but their header + action button rows are fixed (non-scroll), which is fine on phones but would waste space on tablets.
- **ScheduleFormScreen range rows:** repeatable up to 6 windows; the whole page scrolls, so no overflow — already fixed for the multi-window case (compact remove-icon + `Flexible` time label).
- **Home header:** previously fixed so the 4-button `_ActionRail` + logo + pip fit without horizontal scroll (title uses `Expanded` + ellipsis; rail is fixed 38 px).

### 5.3 Grid / sizing behavior

- Channel grid: `crossAxisCount` = 1 (aspect 1.0) when device has 1 channel, else 2 columns (aspect 0.85). Tile content is size-independent because cards use `Expanded`/`Spacer` inside a fixed-aspect cell — a **hardcoded aspect ratio** that may distort text on unusual screen sizes but is fine for standard phones.
- Device selector is a horizontal `ListView` (chips scroll horizontally).
- `WindowTimeline` is the only truly fluid (width-derived) widget.
- Button heights and paddings are fixed pixels everywhere; no density scaling.

### 5.4 Platform notes

- Uses `flutter_secure_storage` for the JWT (platform-backed keystore).
- WebSocket connection via `socket_io_client` for live device/sensor updates.
- Everything is Material 3 dark theme; no platform-specific widgets or per-platform branching.

---

### Appendix — File map

```
flutter_app/lib/
├── main.dart                    # App, AuthGate, HomePage + Home widgets, ChannelConfig
├── theme.dart                   # AppColors
├── services/
│   ├── api_service.dart         # HTTP client (login/signup/devices/sensors/rules/schedules/control/status)
│   └── auth_service.dart        # JWT + username secure storage
├── screens/
│   ├── login_screen.dart        # LoginScreen
│   ├── signup_screen.dart       # SignupScreen
│   ├── add_device_screen.dart   # AddDeviceScreen
│   ├── add_sensor_screen.dart   # AddSensorScreen
│   ├── sensor_rules_screen.dart # SensorRulesScreen
│   ├── rule_form_screen.dart    # RuleFormScreen
│   ├── schedule_list_screen.dart# ScheduleListScreen
│   └── schedule_form_screen.dart# ScheduleFormScreen
└── widgets/
    └── window_timeline.dart     # WindowTimeline
```
