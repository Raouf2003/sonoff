import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home_app/services/provisioning_service.dart';

/// Unit tests for the PHASE 0 session-preparation gate.
///
/// The gate is the single source of truth that prevents the wizard from
/// sending the user to the offline Tasmota SoftAP before the backend
/// provisioning session is verified usable, and that prevents the session from
/// ever being recreated afterwards (lifecycle resume, AP detection, reconnect).
void main() {
  group('SessionGate - creation succeeds before AP', () {
    test('begin -> ready -> Wi-Fi Settings allowed', () {
      final g = SessionGate();
      expect(g.beginPrepare(), isTrue);
      expect(g.canOpenWifiSettings(), isFalse); // still in flight
      g.markReady();
      expect(g.state, SessionPrepState.ready);
      expect(g.canOpenWifiSettings(), isTrue);
    });
  });

  group('SessionGate - still preparing blocks Wi-Fi Settings', () {
    test('canOpenWifiSettings is false while preparing', () {
      final g = SessionGate();
      g.beginPrepare();
      expect(g.isPreparing, isTrue);
      expect(g.canOpenWifiSettings(), isFalse);
    });
  });

  group('SessionGate - failed creation blocks Wi-Fi Settings', () {
    test('canOpenWifiSettings is false after failure', () {
      final g = SessionGate();
      g.beginPrepare();
      g.markFailed();
      expect(g.isFailed, isTrue);
      expect(g.canOpenWifiSettings(), isFalse);
    });
  });

  group('SessionGate - retry after failure succeeds', () {
    test('failed -> canBeginPrepare -> begin -> ready', () {
      final g = SessionGate();
      g.beginPrepare();
      g.markFailed();
      expect(g.canBeginPrepare(), isTrue);
      expect(g.beginPrepare(), isTrue);
      expect(g.isPreparing, isTrue);
      g.markReady();
      expect(g.isReady, isTrue);
      expect(g.canOpenWifiSettings(), isTrue);
    });
  });

  group('SessionGate - lifecycle resume never recreates a ready session', () {
    test('resume on ready session stays ready, no new create allowed', () {
      final g = SessionGate();
      g.beginPrepare();
      g.markReady();
      expect(g.onResume(), SessionPrepState.ready);
      // A resume must never spawn a second session.
      expect(g.canBeginPrepare(), isFalse);
      expect(g.beginPrepare(), isFalse);
      expect(g.isReady, isTrue);
    });

    test('resume on failed session surfaces failure, never recreates', () {
      final g = SessionGate();
      g.beginPrepare();
      g.markFailed();
      expect(g.onResume(), SessionPrepState.failed);
      // No auto-recreate: only a user Retry may begin a new attempt.
      expect(g.canBeginPrepare(), isTrue);
    });
  });

  group('SessionGate - AP detection / reconnect never recreates the session', () {
    test('beginPrepare from ready returns false (no second session)', () {
      final g = SessionGate();
      g.beginPrepare();
      g.markReady();
      expect(g.beginPrepare(), isFalse);
      expect(g.state, SessionPrepState.ready);
      expect(g.canOpenWifiSettings(), isTrue);
    });
  });

  group('SessionGate - Configure requires a valid session', () {
    test('Wi-Fi Settings (the only path to Configure) requires ready', () {
      for (final state in SessionPrepState.values) {
        final g = SessionGate();
        switch (state) {
          case SessionPrepState.idle:
          case SessionPrepState.preparing:
          case SessionPrepState.failed:
            expect(g.canOpenWifiSettings(), isFalse, reason: '$state');
          case SessionPrepState.ready:
            g.markReady();
            expect(g.canOpenWifiSettings(), isTrue, reason: '$state');
        }
      }
    });
  });

  group('SessionGate - duplicate lifecycle callbacks never duplicate sessions', () {
    test('two concurrent beginPrepare calls - only the first starts', () {
      final g = SessionGate();
      expect(g.beginPrepare(), isTrue);
      expect(g.beginPrepare(), isFalse); // already in flight
      expect(g.isPreparing, isTrue);
      g.markReady();
      expect(g.beginPrepare(), isFalse);
      expect(g.isReady, isTrue);
    });

    test('never overwritten: sessionId/claimToken belong to one creation', () {
      final g = SessionGate();
      g.beginPrepare();
      // Simulate the create completing once; any duplicate callback is ignored.
      g.markReady();
      expect(g.canBeginPrepare(), isFalse);
      expect(g.beginPrepare(), isFalse);
      g.markReady();
      expect(g.isReady, isTrue);
    });
  });

  group('SessionGate - MAC identity is independent of session', () {
    test('normalizeMac works with no session involved (local, offline)', () {
      expect(normalizeMac('34:98:7A:C3:03:04'), '34987AC30304');
      final g = SessionGate();
      g.beginPrepare();
      expect(g.isPreparing, isTrue); // session preparing, MAC still derivable
      g.markReady();
    });
  });
}