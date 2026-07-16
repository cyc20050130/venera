import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/core/upgrade/rewrite_upgrade_coordinator.dart';
import 'package:venera/foundation/bootstrap.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/backup_v2.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/io.dart';

enum RewriteUpgradeOperation { idle, inspecting, exportingBackup, resetting }

enum RewriteUpgradeFailedAction { inspect, exportBackup, reset }

typedef RewriteUpgradeExport = Future<File> Function();
typedef RewriteUpgradeValidate = Future<BackupManifestV2> Function(File file);
typedef RewriteUpgradeSave = Future<String?> Function(File file);

/// Presents one UI-facing state machine over the durable bootstrap gate.
class RewriteUpgradeFlowController extends ChangeNotifier {
  RewriteUpgradeFlowController({
    required this.bootstrap,
    RewriteUpgradeExport? exportBackup,
    RewriteUpgradeValidate? validateBackup,
    RewriteUpgradeSave? saveBackup,
    Duration completionDisplayDuration = const Duration(milliseconds: 650),
  }) : _exportBackup = exportBackup,
       _validateBackup = validateBackup,
       _saveBackup = saveBackup,
       _completionDisplayDuration = completionDisplayDuration {
    bootstrap.addListener(_handleBootstrapState);
    _handleBootstrapState();
  }

  final BootstrapController bootstrap;
  final RewriteUpgradeExport? _exportBackup;
  final RewriteUpgradeValidate? _validateBackup;
  final RewriteUpgradeSave? _saveBackup;
  final Duration _completionDisplayDuration;

  RewriteUpgradeOperation operation = RewriteUpgradeOperation.idle;
  RewriteUpgradeFailedAction? failedAction;
  String? localErrorMessage;
  Future<void>? _completionFuture;
  bool _disposed = false;

  RewriteUpgradeSnapshot? get snapshot => bootstrap.rewriteUpgradeSnapshot;

  String? get errorMessage {
    final local = localErrorMessage;
    if (local != null) return local;
    final bootstrapError = bootstrap.rewriteUpgradeError;
    return bootstrapError == null ? null : _displayError(bootstrapError);
  }

  RewriteUpgradeFailedAction? get effectiveFailedAction =>
      failedAction ??
      (bootstrap.rewriteUpgradeError == null
          ? null
          : RewriteUpgradeFailedAction.inspect);

  Future<void> exportAndVerifyBackup() async {
    if (operation != RewriteUpgradeOperation.idle ||
        snapshot?.phase != RewriteUpgradePhase.backupRequired) {
      return;
    }
    operation = RewriteUpgradeOperation.exportingBackup;
    _clearFailure();
    notifyListeners();

    File? temporaryBackup;
    try {
      temporaryBackup = await (_exportBackup ?? exportAppDataForRewrite)();
      final validate = _validateBackup ?? validateBackupV2Archive;
      var manifest = await validate(temporaryBackup);
      if (!manifest.isCompleteRewriteBackup) {
        throw const FormatException(
          'The exported backup is not a complete V2 backup',
        );
      }
      final savedPath = await (_saveBackup ?? _saveExportedBackup)(
        temporaryBackup,
      );
      if (savedPath == null || savedPath.trim().isEmpty) {
        operation = RewriteUpgradeOperation.idle;
        return;
      }

      // SAF paths are not always readable as dart:io files. When a normal path
      // is available, validate the saved copy and compare every manifest entry.
      final savedFile = File(savedPath);
      if (await savedFile.exists()) {
        final savedManifest = await validate(savedFile);
        if (!_sameManifest(manifest, savedManifest)) {
          throw const FormatException(
            'Saved backup does not match the exported backup',
          );
        }
        manifest = savedManifest;
      }

      final updated = await bootstrap.rewriteUpgradeCoordinator
          .recordVerifiedBackup(
            savedBackupPath: savedPath,
            backupAppVersion: manifest.appVersion,
            backupCreatedAt: manifest.createdAt,
            backupFingerprint: manifest.fingerprint,
            verifiedEntryPaths: manifest.entries.map((entry) => entry.path),
          );
      bootstrap.applyRewriteUpgradeSnapshot(updated);
      operation = RewriteUpgradeOperation.idle;
    } catch (error, stackTrace) {
      operation = RewriteUpgradeOperation.idle;
      failedAction = RewriteUpgradeFailedAction.exportBackup;
      localErrorMessage = _displayError(error);
      Log.error('Rewrite upgrade backup', error, stackTrace);
    } finally {
      await temporaryBackup?.deleteIgnoreError();
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> resetAfterConfirmation() async {
    if (operation != RewriteUpgradeOperation.idle ||
        snapshot?.phase != RewriteUpgradePhase.backupVerified) {
      return;
    }
    operation = RewriteUpgradeOperation.resetting;
    _clearFailure();
    notifyListeners();
    try {
      await _revalidateSavedBackupWhenReadable();
      final updated = await bootstrap.rewriteUpgradeCoordinator
          .resetAfterConfirmation(confirmed: true);
      operation = RewriteUpgradeOperation.idle;
      bootstrap.applyRewriteUpgradeSnapshot(updated);
      await _finishCompletedUpgrade();
    } catch (error, stackTrace) {
      operation = RewriteUpgradeOperation.idle;
      failedAction = RewriteUpgradeFailedAction.reset;
      localErrorMessage = _displayError(error);
      Log.error('Rewrite upgrade reset', error, stackTrace);
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _revalidateSavedBackupWhenReadable() async {
    final current = snapshot;
    final savedPath = current?.savedBackupPath;
    if (current == null || savedPath == null || savedPath.trim().isEmpty) {
      throw const FormatException('The verified backup path is missing');
    }
    final localFile = _localFileForSavedBackup(savedPath);
    if (localFile == null) {
      // Android document-provider URIs cannot always be reopened through
      // dart:io. A successful platform save is the strongest available proof.
      return;
    }
    if (!await localFile.exists()) {
      throw const FormatException(
        'The verified backup no longer exists; export it again',
      );
    }
    final validate = _validateBackup ?? validateBackupV2Archive;
    final manifest = await validate(localFile);
    if (!manifest.isCompleteRewriteBackup ||
        manifest.fingerprint != current.backupFingerprint) {
      throw const FormatException(
        'The verified backup changed; export it again before resetting',
      );
    }
  }

  Future<void> retry() async {
    switch (effectiveFailedAction) {
      case RewriteUpgradeFailedAction.inspect:
      case RewriteUpgradeFailedAction.reset:
        operation = RewriteUpgradeOperation.inspecting;
        _clearFailure();
        notifyListeners();
        await bootstrap.retryRewriteUpgradeInspection();
        operation = RewriteUpgradeOperation.idle;
        if (!_disposed) notifyListeners();
        return;
      case RewriteUpgradeFailedAction.exportBackup:
        await exportAndVerifyBackup();
        return;
      case null:
        return;
    }
  }

  void _clearFailure() {
    localErrorMessage = null;
    failedAction = null;
  }

  void _handleBootstrapState() {
    if (snapshot?.phase == RewriteUpgradePhase.resetCompleted &&
        _completionFuture == null) {
      unawaited(_finishCompletedUpgrade());
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _finishCompletedUpgrade() {
    final existing = _completionFuture;
    if (existing != null) return existing;
    final completer = Completer<void>();
    final future = completer.future;
    _completionFuture = future;
    unawaited(() async {
      try {
        await _runCompletedUpgrade();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        if (identical(_completionFuture, future)) {
          _completionFuture = null;
        }
      }
    }());
    return future;
  }

  Future<void> _runCompletedUpgrade() async {
    if (!_disposed) notifyListeners();
    try {
      if (_completionDisplayDuration > Duration.zero) {
        await Future<void>.delayed(_completionDisplayDuration);
      }
      await bootstrap.finishRewriteUpgrade();
    } catch (error, stackTrace) {
      failedAction = RewriteUpgradeFailedAction.reset;
      localErrorMessage = _displayError(error);
      Log.error('Rewrite upgrade completion', error, stackTrace);
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  Future<String?> _saveExportedBackup(File file) {
    final now = DateTime.now().toUtc();
    final date =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    return saveFile(filename: 'venera-backup-$date.venera', file: file);
  }

  @override
  void dispose() {
    _disposed = true;
    bootstrap.removeListener(_handleBootstrapState);
    super.dispose();
  }
}

File? _localFileForSavedBackup(String value) {
  final trimmed = value.trim();
  final isWindowsPath = RegExp(r'^[A-Za-z]:[/\\]').hasMatch(trimmed);
  if (isWindowsPath) return File(trimmed);
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.hasScheme) {
    if (uri.scheme.toLowerCase() != 'file') return null;
    try {
      return File(uri.toFilePath(windows: Platform.isWindows));
    } catch (_) {
      return File(trimmed);
    }
  }
  return File(trimmed);
}

bool _sameManifest(BackupManifestV2 a, BackupManifestV2 b) {
  if (a.appVersion != b.appVersion ||
      a.createdAt.toUtc() != b.createdAt.toUtc() ||
      a.isFullBackup != b.isFullBackup ||
      a.entries.length != b.entries.length) {
    return false;
  }
  for (var index = 0; index < a.entries.length; index++) {
    final left = a.entries[index];
    final right = b.entries[index];
    if (left.path != right.path ||
        left.length != right.length ||
        left.sha256 != right.sha256 ||
        left.kind != right.kind) {
      return false;
    }
  }
  return true;
}

String _displayError(Object error) {
  final message = error.toString().trim();
  return message
      .replaceFirst(RegExp(r'^(FormatException|StateError):\s*'), '')
      .trim();
}
