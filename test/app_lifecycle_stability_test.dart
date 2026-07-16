import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/main.dart' as app;

void main() {
  test('authorization requirement tolerates malformed synced values', () {
    expect(app.shouldRequireAuthorization(true), isTrue);
    expect(app.shouldRequireAuthorization(false), isFalse);
    expect(app.shouldRequireAuthorization('true'), isTrue);
    expect(app.shouldRequireAuthorization('false'), isFalse);
    expect(app.shouldRequireAuthorization(1), isTrue);
    expect(app.shouldRequireAuthorization(0), isFalse);
    expect(app.shouldRequireAuthorization('bad'), isFalse);
    expect(app.shouldRequireAuthorization(['true']), isFalse);
    expect(app.shouldRequireAuthorization(null), isFalse);
  });

  test('root router preserves bootstrap and authorization gates', () {
    expect(
      app.resolveRootRouteRedirect(
        phaseAReady: false,
        rewriteUpgradeRequired: false,
        authorizationRequired: false,
        startupAuthorized: false,
        currentLocation: app.AppRoutePath.home,
      ),
      app.AppRoutePath.bootstrap,
    );
    expect(
      app.resolveRootRouteRedirect(
        phaseAReady: true,
        rewriteUpgradeRequired: false,
        authorizationRequired: true,
        startupAuthorized: false,
        currentLocation: app.AppRoutePath.bootstrap,
      ),
      app.AppRoutePath.unlock,
    );
    expect(
      app.resolveRootRouteRedirect(
        phaseAReady: true,
        rewriteUpgradeRequired: false,
        authorizationRequired: true,
        startupAuthorized: true,
        currentLocation: app.AppRoutePath.unlock,
      ),
      app.AppRoutePath.home,
    );
    expect(
      app.resolveRootRouteRedirect(
        phaseAReady: true,
        rewriteUpgradeRequired: false,
        authorizationRequired: false,
        startupAuthorized: false,
        currentLocation: app.AppRoutePath.home,
      ),
      isNull,
    );
    expect(
      app.resolveRootRouteRedirect(
        phaseAReady: true,
        rewriteUpgradeRequired: true,
        authorizationRequired: true,
        startupAuthorized: true,
        currentLocation: app.AppRoutePath.home,
      ),
      app.AppRoutePath.rewriteUpgrade,
    );
  });

  test('download flush is throttled across background lifecycle sequence', () {
    final now = DateTime(2026, 6, 3, 20);

    expect(
      app.shouldFlushDownloadsForLifecycleState(
        state: AppLifecycleState.inactive,
        appInitialized: true,
        phaseAReady: true,
        now: now,
        lastFlushAt: null,
      ),
      isTrue,
    );

    expect(
      app.shouldFlushDownloadsForLifecycleState(
        state: AppLifecycleState.hidden,
        appInitialized: true,
        phaseAReady: true,
        now: now.add(const Duration(milliseconds: 200)),
        lastFlushAt: now,
      ),
      isFalse,
    );

    expect(
      app.shouldFlushDownloadsForLifecycleState(
        state: AppLifecycleState.resumed,
        appInitialized: true,
        phaseAReady: true,
        now: now.add(const Duration(seconds: 2)),
        lastFlushAt: now,
      ),
      isFalse,
    );
  });

  test('privacy overlay only appears once and is removed on resume', () {
    expect(
      app.shouldShowLifecyclePrivacyOverlay(
        state: AppLifecycleState.inactive,
        isMobile: true,
        authorizationRequired: true,
        hasOverlay: false,
      ),
      isTrue,
    );

    expect(
      app.shouldShowLifecyclePrivacyOverlay(
        state: AppLifecycleState.inactive,
        isMobile: true,
        authorizationRequired: true,
        hasOverlay: true,
      ),
      isFalse,
    );

    expect(
      app.shouldRemoveLifecyclePrivacyOverlay(
        state: AppLifecycleState.resumed,
        hasOverlay: true,
      ),
      isTrue,
    );
  });

  test('auth page push is throttled for repeated hidden states', () {
    final now = DateTime(2026, 6, 3, 20);

    expect(
      app.shouldPushLifecycleAuthPage(
        state: AppLifecycleState.hidden,
        isMobile: true,
        authorizationRequired: true,
        isAuthPageActive: false,
        isSelectingFiles: false,
        now: now,
        lastAuthPromptAt: null,
      ),
      isTrue,
    );

    expect(
      app.shouldPushLifecycleAuthPage(
        state: AppLifecycleState.hidden,
        isMobile: true,
        authorizationRequired: true,
        isAuthPageActive: false,
        isSelectingFiles: false,
        now: now.add(const Duration(milliseconds: 500)),
        lastAuthPromptAt: now,
      ),
      isFalse,
    );

    expect(
      app.shouldPushLifecycleAuthPage(
        state: AppLifecycleState.hidden,
        isMobile: true,
        authorizationRequired: true,
        isAuthPageActive: false,
        isSelectingFiles: true,
        now: now.add(const Duration(seconds: 3)),
        lastAuthPromptAt: now,
      ),
      isFalse,
    );
  });
}
