import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:venera/utils/translations.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.onSuccessfulAuth});

  final void Function()? onSuccessfulAuth;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  bool _authInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (SchedulerBinding.instance.lifecycleState !=
          AppLifecycleState.paused) {
        auth();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          SystemNavigator.pop();
        }
      },
      child: Material(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.security, size: 36),
              const SizedBox(height: 16),
              Text("Authentication Required".tl),
              const SizedBox(height: 16),
              FilledButton(onPressed: auth, child: Text("Continue".tl)),
            ],
          ),
        ),
      ),
    );
  }

  void auth() async {
    if (_authInFlight) return;
    _authInFlight = true;
    var localAuth = LocalAuthentication();
    try {
      var canCheckBiometrics = await localAuth.canCheckBiometrics;
      if (!mounted) return;
      if (!canCheckBiometrics && !await localAuth.isDeviceSupported()) {
        if (mounted) {
          widget.onSuccessfulAuth?.call();
        }
        return;
      }
      if (!mounted) return;
      var isAuthorized = await localAuth.authenticate(
        localizedReason: "Please authenticate to continue".tl,
      );
      if (!mounted) return;
      if (isAuthorized) {
        widget.onSuccessfulAuth?.call();
      }
    } finally {
      _authInFlight = false;
    }
  }
}
