import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';

import 'components.dart';

@visibleForTesting
List<Map<String, dynamic>> normalizeJsDialogActions(Object? value) {
  if (value is! Iterable) {
    return <Map<String, dynamic>>[];
  }
  final result = <Map<String, dynamic>>[];
  for (final item in value) {
    if (item is! Map) {
      continue;
    }
    final action = <String, dynamic>{};
    for (final entry in item.entries) {
      final key = entry.key;
      if (key is String) {
        action[key] = entry.value;
      }
    }
    if (action.isNotEmpty) {
      result.add(action);
    }
  }
  return result;
}

@visibleForTesting
String? normalizeJsLaunchUrl(Object? value) {
  if (value is! String) {
    return null;
  }
  final url = value.trim();
  return url.isEmpty ? null : url;
}

@visibleForTesting
Object? runJsUiCallbackSafely(
  Object? Function() callback, {
  required String label,
}) {
  try {
    final result = callback();
    if (result is Future) {
      return result.catchError((Object e, StackTrace s) {
        Log.error("JsUi", "Failed to run $label: $e", s);
        return null;
      });
    }
    return result;
  } catch (e, s) {
    Log.error("JsUi", "Failed to run $label: $e", s);
    return null;
  }
}

@visibleForTesting
FutureOr<String?> runJsInputValidatorSafely(
  Object? Function() validator, {
  String failureMessage = 'Validation failed',
}) {
  String? normalizeResult(Object? result) {
    return result?.toString();
  }

  try {
    final result = validator();
    if (result is Future) {
      return result.then<String?>(normalizeResult).catchError((
        Object e,
        StackTrace s,
      ) {
        Log.error("JsUi", "Failed to run input validator: $e", s);
        return failureMessage;
      });
    }
    return normalizeResult(result);
  } catch (e, s) {
    Log.error("JsUi", "Failed to run input validator: $e", s);
    return failureMessage;
  }
}

mixin class JsUiApi {
  final Map<int, LoadingDialogController> _loadingDialogControllers = {};

  dynamic handleUIMessage(Map<String, dynamic> message) {
    switch (message['function']) {
      case 'showMessage':
        var m = message['message'];
        if (m.toString().isNotEmpty) {
          App.rootContext.showMessage(message: m.toString());
        }
      case 'showDialog':
        return _showDialog(message);
      case 'launchUrl':
        final url = normalizeJsLaunchUrl(message['url']);
        if (url != null) {
          unawaited(
            launchUrlString(url).catchError((Object e, StackTrace s) {
              Log.error("JsUi", "Failed to launch URL: $url\n$e", s);
              return false;
            }),
          );
        }
      case 'showLoading':
        var onCancel = message['onCancel'];
        if (onCancel != null && onCancel is! JSInvokable) {
          return;
        }
        return _showLoading(onCancel);
      case 'cancelLoading':
        var id = message['id'];
        if (id is int) {
          _cancelLoading(id);
        }
      case 'showInputDialog':
        var title = message['title'];
        var validator = message['validator'];
        var image = message['image'];
        if (title is! String) return;
        if (validator != null && validator is! JSInvokable) return;
        return _showInputDialog(title, validator, image);
      case 'showSelectDialog':
        var title = message['title'];
        var options = message['options'];
        var initialIndex = message['initialIndex'];
        if (title is! String) return;
        if (options is! List) return;
        if (initialIndex != null && initialIndex is! int) return;
        return _showSelectDialog(
          title,
          options.whereType<String>().toList(),
          initialIndex,
        );
    }
  }

  Future<void> _showDialog(Map<String, dynamic> message) {
    BuildContext? dialogContext;
    final title = message['title']?.toString();
    final content = message['content']?.toString() ?? '';
    var actions = <Widget>[];
    for (var action in normalizeJsDialogActions(message['actions'])) {
      if (action['callback'] is! JSInvokable) {
        continue;
      }
      var callback = action['callback'] as JSInvokable;
      var text = action['text'].toString();
      var style = (action['style'] ?? 'text').toString();
      actions.add(
        _JSCallbackButton(
          text: text,
          callback: JSAutoFreeFunction(callback),
          style: style,
          onCallbackFinished: () {
            dialogContext?.pop();
          },
        ),
      );
    }
    if (actions.isEmpty) {
      actions.add(
        TextButton(
          onPressed: () {
            dialogContext?.pop();
          },
          child: Text('OK'),
        ),
      );
    }
    return showDialog(
      context: App.rootContext,
      builder: (context) {
        dialogContext = context;
        return ContentDialog(
          title: title,
          content: Text(content).paddingHorizontal(16),
          actions: actions,
        );
      },
    ).then((value) {
      dialogContext = null;
    });
  }

  int _showLoading(JSInvokable? onCancel) {
    var func = onCancel == null ? null : JSAutoFreeFunction(onCancel);
    var i = 0;
    while (_loadingDialogControllers.containsKey(i)) {
      i++;
    }
    var controller = showLoadingDialog(
      App.rootContext,
      barrierDismissible: onCancel != null,
      allowCancel: onCancel != null,
      onCancel: onCancel == null
          ? null
          : () {
              runJsUiCallbackSafely(
                () => func?.call([]),
                label: "loading cancel callback",
              );
            },
      onClosed: () {
        _loadingDialogControllers.remove(i);
      },
    );
    _loadingDialogControllers[i] = controller;
    return i;
  }

  void _cancelLoading(int id) {
    var controller = _loadingDialogControllers.remove(id);
    controller?.close();
  }

  Future<String?> _showInputDialog(
    String title,
    JSInvokable? validator,
    dynamic image,
  ) async {
    String? result;
    var func = validator == null ? null : JSAutoFreeFunction(validator);
    String? imageUrl;
    Uint8List? imageData;
    if (image != null) {
      if (image is String) {
        imageUrl = image;
      } else if (image is Uint8List) {
        imageData = image;
      } else if (image is List<int>) {
        imageData = Uint8List.fromList(image);
      }
    }
    await showInputDialog(
      context: App.rootContext,
      title: title,
      image: imageUrl,
      imageData: imageData,
      onConfirm: (v) {
        if (func != null) {
          final res = runJsInputValidatorSafely(() => func.call([v]));
          if (res is Future) {
            final future = res as Future<String?>;
            return future.then<Object?>((error) {
              if (error == null) {
                result = v;
              }
              return error;
            });
          }
          if (res == null) {
            result = v;
          }
          return res;
        } else {
          result = v;
        }
        return null;
      },
    );
    return result;
  }

  Future<int?> _showSelectDialog(
    String title,
    List<String> options,
    int? initialIndex,
  ) {
    if (options.isEmpty) {
      return Future.value(null);
    }
    if (initialIndex != null &&
        (initialIndex >= options.length || initialIndex < 0)) {
      initialIndex = null;
    }
    return showSelectDialog(
      title: title,
      options: options,
      initialIndex: initialIndex,
    );
  }
}

class _JSCallbackButton extends StatefulWidget {
  const _JSCallbackButton({
    required this.text,
    required this.callback,
    required this.style,
    this.onCallbackFinished,
  });

  final JSAutoFreeFunction callback;

  final String text;

  final String style;

  final void Function()? onCallbackFinished;

  @override
  State<_JSCallbackButton> createState() => _JSCallbackButtonState();
}

class _JSCallbackButtonState extends State<_JSCallbackButton> {
  bool isLoading = false;

  void onClick() async {
    if (isLoading) {
      return;
    }
    Object? res;
    try {
      res = widget.callback.call([]);
      if (res is Future) {
        setState(() {
          isLoading = true;
        });
        await res;
      }
    } catch (e, s) {
      Log.error("JsUi", "Failed to run dialog action: $e", s);
      return;
    } finally {
      if (mounted && isLoading) {
        setState(() {
          isLoading = false;
        });
      }
    }
    if (!mounted) return;
    widget.onCallbackFinished?.call();
  }

  @override
  Widget build(BuildContext context) {
    return switch (widget.style) {
      "filled" => FilledButton(
        onPressed: onClick,
        child: isLoading
            ? CircularProgressIndicator(
                strokeWidth: 1.4,
              ).fixWidth(18).fixHeight(18)
            : Text(widget.text),
      ),
      "danger" => FilledButton(
        onPressed: onClick,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(context.colorScheme.error),
        ),
        child: isLoading
            ? CircularProgressIndicator(
                strokeWidth: 1.4,
              ).fixWidth(18).fixHeight(18)
            : Text(widget.text),
      ),
      _ => TextButton(
        onPressed: onClick,
        child: isLoading
            ? CircularProgressIndicator(
                strokeWidth: 1.4,
              ).fixWidth(18).fixHeight(18)
            : Text(widget.text),
      ),
    };
  }
}
