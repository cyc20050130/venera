import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';

import 'app_page_route.dart';

class AppProgressDialogController {
  AppProgressDialogController._(this._delegate);

  final LoadingDialogController _delegate;

  void setProgress(double? value) => _delegate.setProgress(value);

  void setMessage(String message) => _delegate.setMessage(message);

  void close() => _delegate.close();
}

AppProgressDialogController showAppProgressDialog(
  BuildContext context, {
  required String message,
  required void Function() onCancel,
}) {
  return AppProgressDialogController._(
    showLoadingDialog(
      context,
      barrierDismissible: false,
      allowCancel: true,
      withProgress: true,
      message: message,
      onCancel: onCancel,
    ),
  );
}

extension Navigation on BuildContext {
  void pop<T>([T? result]) {
    if (mounted) {
      Navigator.of(this).pop(result);
    }
  }

  bool canPop() {
    if (!mounted) {
      return false;
    }
    return Navigator.of(this).canPop();
  }

  Future<T?> to<T>(Widget Function() builder, {bool allowSnapshotting = true}) {
    if (!mounted) {
      return Future<T?>.value();
    }
    return Navigator.of(this).push<T>(
      AppPageRoute(
        builder: (context) => builder(),
        allowSnapshotting: allowSnapshotting,
      ),
    );
  }

  Future<void> toReplacement<T>(
    Widget Function() builder, {
    bool allowSnapshotting = true,
  }) {
    if (!mounted) {
      return Future<void>.value();
    }
    return Navigator.of(this).pushReplacement(
      AppPageRoute(
        builder: (context) => builder(),
        allowSnapshotting: allowSnapshotting,
      ),
    );
  }

  double get width => MediaQuery.of(this).size.width;

  double get height => MediaQuery.of(this).size.height;

  EdgeInsets get padding => MediaQuery.of(this).padding;

  EdgeInsets get viewInsets => MediaQuery.of(this).viewInsets;

  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  Brightness get brightness => Theme.of(this).brightness;

  bool get isDarkMode => brightness == Brightness.dark;

  void showMessage({required String message}) {
    showToast(message: message, context: this);
  }

  Color useBackgroundColor(MaterialColor color) {
    return color[brightness == Brightness.light ? 100 : 800]!;
  }

  Color useTextColor(MaterialColor color) {
    return color[brightness == Brightness.light ? 800 : 100]!;
  }
}
