// Localization audit for the STEES flutter_app.
//
// Usage: `dart tool/l10n_audit.dart` from flutter_app/.
// Exit code 0 = clean, 1 = problems found.
//
// Checks:
//   1. ARB key parity across en/ar/fr (+ non-empty, no TODO placeholders).
//   2. Remaining hardcoded user-facing literals in lib/ (heuristic allowlist).
//   3. Locale registration in main.dart (delegates + supportedLocales).
//   4. friendlyError() mapping covers every ApiService fallback literal, so
//      no client-side error message can silently bypass localization.
import 'dart:convert';
import 'dart:io';

const _locales = ['en', 'ar', 'fr'];

/// Suspicious literal patterns: likely user-visible strings.
final _suspicious = <RegExp>[
  RegExp(r'''\bText\(\s*'[^']{2,}'''),
  RegExp(r'''\bText\(\s*"[^"]{2,}'''),
  RegExp(r'''(hintText|helperText|labelText|semanticLabel|semanticsLabel)\s*:\s*['"][^'"]+['"]'''),
  RegExp(r'''\btooltip\s*:\s*'[^']{2,}'''),
  RegExp(r'''\btitle\s*:\s*Text\(\s*'[^']{2,}'''),
  // Error/feedback helpers called with a raw literal instead of l10n.
  RegExp(r'''\b_?(err|showError|setError|showInfo|showToast)\(\s*'[^']{2,}'''),
  // Dialog/snackbar content with a raw literal.
  RegExp(r'''\b(content|subtitle)\s*:\s*Text\(\s*'[^']{2,}'''),
  // Throwing a user-facing ApiException literal that friendlyError() cannot
  // map (must be added to _localizedFallback when intentional).
  RegExp(r'''\bthrow\s+(const\s+)?ApiException\(\s*'[^']{3,}'''),
];

/// Allowlisted findings: technical identifiers, not user-facing copy.
/// Each entry is matched against "relative/path.dart:line: code".
final _allowlist = <RegExp>[
  // Generated localizations.
  RegExp(r'lib/l10n/gen/'),
  // Single punctuation/placeholder literals.
  RegExp(r"Text\('\u2014'"),
  // Chart/timeline numerics and protocol-shaped strings.
  RegExp(r"Text\(\s*'\$"),
  // Channel-code chips (technical identifiers, intentionally untranslated).
  RegExp(r"label: 'CH"),
  // Provision trace labels (log tags, never rendered).
  RegExp(r'label: [A-Z][A-Z0-9_]+'),
  RegExp(r"label: 'STA_|label: 'AP_|label: 'BROKER_|label: 'TOPIC_|label: 'FULLTOPIC_|label: 'MODULE_|label: 'ALL_|label: 'RESTART_|label: 'IDENTITY_|label: 'WIFI_TEST_|label: 'WIFI_TEST'"),
  // Emoji-only advisory markers.
  RegExp(r"Text\(isOverlap \? '"),
  // Log/trace/debug lines.
  RegExp(r'debugPrint|traceLog|_logSetup|print\('),
  // Comments (audit only matches code lines containing the patterns above,
  // but a comment line can still trip `title:` — excluded by context below).
];

/// File basenames skipped wholesale (pure logic, no UI copy).
const _skippedFiles = {
  'app_theme.dart',
  'stees_colors.dart',
  'light_theme.dart',
  'dark_theme.dart',
  'theme_controller.dart',
  'auth_service.dart',
  'local_ip.dart',
  'control_timeline.dart',
  'channel_state_machine.dart',
  'device_transport.dart',
  'local_device_transport.dart',
  'cloud_device_transport.dart',
  'local_device_cache.dart',
  'local_device_discovery.dart',
  'reachability_monitor.dart',
  'reverse_geocode.dart',
  'device_profile.dart',
  'provisioning_service.dart', // pure English labels kept for logs/tests; UI uses l10n helpers
  'device_type.dart', // label kept for tests; UI uses localized relay keys
  'weather.dart',
};

int _failures = 0;

void _fail(String msg) {
  _failures++;
  stdout.writeln('FAIL: $msg');
}

void _ok(String msg) => stdout.writeln('ok: $msg');

Map<String, dynamic> _readArb(String code) {
  final file = File('lib/l10n/app_$code.arb');
  if (!file.existsSync()) {
    _fail('lib/l10n/app_$code.arb is missing');
    return {};
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void _checkParity() {
  final maps = {for (final c in _locales) c: _readArb(c)};
  Set<String> keys(String c) => maps[c]!
      .keys
      .where((k) => !k.startsWith('@'))
      .toSet();
  final en = keys('en');
  if (en.isEmpty) {
    _fail('English ARB has no keys');
    return;
  }
  for (final c in ['ar', 'fr']) {
    final mine = keys(c);
    for (final missing in en.difference(mine)) {
      _fail('$c is missing key "$missing"');
    }
    for (final extra in mine.difference(en)) {
      _fail('$c has extra key "$extra"');
    }
  }
  for (final c in _locales) {
    for (final k in keys(c)) {
      final v = (maps[c]![k] as String).trim();
      if (v.isEmpty) _fail('$c:"$k" is empty');
      if (v.toLowerCase().contains('todo') ||
          v.contains('translation needed')) {
        _fail('$c:"$k" looks like an untranslated placeholder');
      }
    }
  }
  if (_failures == 0) _ok('ARB parity en/ar/fr (${en.length} keys each)');
}

bool _isComment(String line) {
  final t = line.trimLeft();
  return t.startsWith('//') || t.startsWith('*') || t.startsWith('/*');
}

void _checkHardcoded() {
  final lib = Directory('lib');
  var suspects = 0;
  for (final f in lib.listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    final name = f.path.split(Platform.pathSeparator).last;
    if (_skippedFiles.contains(name)) continue;
    final lines = File(f.path).readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isComment(line)) continue;
      final hit = _suspicious.any((re) => re.hasMatch(line));
      if (!hit) continue;
      final ctx = '${f.path}:${i + 1}: ${line.trim()}';
      if (_allowlist.any((re) => re.hasMatch(ctx))) continue;
      _fail('possible hardcoded UI string — $ctx');
      suspects++;
    }
  }
  if (suspects == 0) _ok('no hardcoded user-facing literals in lib/');
}

void _checkRegistration() {  final main = File('lib/main.dart').readAsStringSync();
  for (final token in [
    'AppLocalizations.delegate',
    'GlobalMaterialLocalizations.delegate',
    'supportedLocales',
    'locale:',
    'LocaleController',
  ]) {
    if (!main.contains(token)) {
      _fail('main.dart does not reference "$token"');
      return;
    }
  }
  _ok('locale wiring present in main.dart');
}

void _checkMappingCoverage() {
  // Every English literal ApiService can surface as ApiException.message must
  // have an exact-match entry in _localizedFallback (l10n_helpers.dart),
  // otherwise it would reach the UI in English under ar/fr.
  final api = File('lib/services/api_service.dart').readAsStringSync();
  final helpers = File('lib/l10n/l10n_helpers.dart').readAsStringSync();
  final literalRe = RegExp(
      r'''(?:_checkObject\([^;]*?,\s*|_checkList\([^;]*?,\s*|ApiException\(\s*)'((?:[^'\\]|\\.)+)'\,?''');
  final found = <String>{};
  for (final m in literalRe.allMatches(api)) {
    final lit = m.group(1)!;
    // Skip JSON keys, codes, protocol fragments and short tokens.
    if (lit.length < 4) continue;
    if (!RegExp(r'[a-z]{3,}').hasMatch(lit)) continue;
    if (lit.contains('\$') || lit.contains('/') || lit.contains(':')) {
      continue;
    }
    if (RegExp(r'^[A-Z0-9_]+$').hasMatch(lit)) continue; // codes like TIMEOUT
    found.add(lit);
  }
  var missing = 0;
  for (final lit in found.toList()..sort()) {
    if (!helpers.contains("'$lit'")) {
      _fail('friendlyError() has no mapping for ApiService message "$lit"');
      missing++;
    }
  }
  if (missing == 0) _ok('friendlyError() maps all ${found.length} ApiService messages');
}

void main() {
  _checkParity();
  _checkHardcoded();
  _checkRegistration();
  _checkMappingCoverage();
  if (_failures > 0) {
    stdout.writeln('l10n audit: $_failures problem(s)');
    exit(1);
  }
  stdout.writeln('l10n audit: clean');
}
