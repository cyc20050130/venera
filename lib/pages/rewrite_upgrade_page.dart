import 'package:flutter/material.dart';
import 'package:venera/design_system/app_design_system.dart';

enum RewriteUpgradeUiPhase {
  checking,
  backupRequired,
  exportingBackup,
  backupReady,
  resetting,
  completed,
  failed,
}

enum RewriteUpgradeUiFailureStep { inspection, backup, reset }

@immutable
class RewriteUpgradePageState {
  const RewriteUpgradePageState({
    required this.phase,
    this.backupPath,
    this.errorMessage,
    this.failureStep,
  });

  const RewriteUpgradePageState.checking()
    : this(phase: RewriteUpgradeUiPhase.checking);

  final RewriteUpgradeUiPhase phase;
  final String? backupPath;
  final String? errorMessage;
  final RewriteUpgradeUiFailureStep? failureStep;

  bool get isBusy =>
      phase == RewriteUpgradeUiPhase.checking ||
      phase == RewriteUpgradeUiPhase.exportingBackup ||
      phase == RewriteUpgradeUiPhase.resetting;
}

/// Blocking upgrade gate used before legacy managers open their databases.
///
/// The page deliberately owns no storage logic. The coordinator remains the
/// single source of truth and supplies an immutable state plus idempotent
/// actions. This keeps recovery decisions testable outside the widget tree.
class RewriteUpgradePage extends StatefulWidget {
  const RewriteUpgradePage({
    super.key,
    required this.state,
    required this.onExportBackup,
    required this.onReset,
    required this.onRetry,
  });

  final RewriteUpgradePageState state;
  final Future<void> Function() onExportBackup;
  final Future<void> Function() onReset;
  final Future<void> Function() onRetry;

  @override
  State<RewriteUpgradePage> createState() => _RewriteUpgradePageState();
}

class _RewriteUpgradePageState extends State<RewriteUpgradePage> {
  bool _actionInFlight = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_actionInFlight || widget.state.isBusy) return;
    setState(() => _actionInFlight = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _actionInFlight = false);
    }
  }

  Future<void> _confirmReset(_UpgradeCopy copy) async {
    if (_actionInFlight || widget.state.isBusy) return;
    var acknowledged = false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(copy.confirmTitle),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(copy.confirmMessage),
                    const SizedBox(height: AppSpacing.md),
                    _PreservedDataNotice(copy: copy, compact: true),
                    const SizedBox(height: AppSpacing.md),
                    CheckboxListTile(
                      key: const ValueKey('rewrite-upgrade-acknowledge'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: acknowledged,
                      title: Text(copy.confirmAcknowledgement),
                      onChanged: (value) {
                        setDialogState(() => acknowledged = value ?? false);
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  key: const ValueKey('rewrite-upgrade-cancel-reset'),
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(copy.cancel),
                ),
                FilledButton(
                  key: const ValueKey('rewrite-upgrade-confirm-reset'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: acknowledged
                      ? () => Navigator.of(dialogContext).pop(true)
                      : null,
                  child: Text(copy.confirmReset),
                ),
              ],
            );
          },
        );
      },
    );
    if (confirmed == true && mounted) {
      await _run(widget.onReset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = _UpgradeCopy.of(context);
    final phase = widget.state.phase;
    return PopScope(
      canPop: false,
      child: Scaffold(
        key: const ValueKey('rewrite-upgrade-page'),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: constraints.maxWidth < AppBreakpoints.compact
                      ? AppSpacing.md
                      : AppSpacing.xl,
                  vertical: AppSpacing.lg,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - AppSpacing.lg * 2,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: FocusTraversalGroup(
                        child: AnimatedSwitcher(
                          duration: AppMotion.standard(context),
                          child: switch (phase) {
                            RewriteUpgradeUiPhase.checking => _CheckingView(
                              key: const ValueKey('rewrite-upgrade-checking'),
                              copy: copy,
                            ),
                            RewriteUpgradeUiPhase.completed => _CompletedView(
                              key: const ValueKey('rewrite-upgrade-completed'),
                              copy: copy,
                            ),
                            _ => _UpgradeContent(
                              key: ValueKey(phase),
                              copy: copy,
                              state: widget.state,
                              actionInFlight: _actionInFlight,
                              onExport: () => _run(widget.onExportBackup),
                              onRetry: () => _run(widget.onRetry),
                              onReset: () => _confirmReset(copy),
                            ),
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CheckingView extends StatelessWidget {
  const _CheckingView({super.key, required this.copy});

  final _UpgradeCopy copy;

  @override
  Widget build(BuildContext context) {
    return AppStateView(
      icon: Icons.manage_search_rounded,
      title: copy.checkingTitle,
      message: copy.checkingMessage,
      loading: true,
    );
  }
}

class _CompletedView extends StatelessWidget {
  const _CompletedView({super.key, required this.copy});

  final _UpgradeCopy copy;

  @override
  Widget build(BuildContext context) {
    return AppStateView(
      icon: Icons.check_circle_rounded,
      title: copy.completedTitle,
      message: copy.completedMessage,
      loading: true,
    );
  }
}

class _UpgradeContent extends StatelessWidget {
  const _UpgradeContent({
    super.key,
    required this.copy,
    required this.state,
    required this.actionInFlight,
    required this.onExport,
    required this.onRetry,
    required this.onReset,
  });

  final _UpgradeCopy copy;
  final RewriteUpgradePageState state;
  final bool actionInFlight;
  final VoidCallback onExport;
  final VoidCallback onRetry;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final typography = Theme.of(context).textTheme;
    final busy = state.isBusy || actionInFlight;
    return Semantics(
      namesRoute: true,
      label: copy.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: AppRadii.medium,
              ),
              child: Icon(
                Icons.upgrade_rounded,
                size: 34,
                color: colors.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(copy.title, style: typography.headlineMedium),
          const SizedBox(height: AppSpacing.sm),
          Text(
            copy.introduction,
            style: typography.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _StepsCard(
            copy: copy,
            phase: state.phase,
            failureStep: state.failureStep,
          ),
          const SizedBox(height: AppSpacing.md),
          _PreservedDataNotice(copy: copy),
          const SizedBox(height: AppSpacing.md),
          if (state.phase == RewriteUpgradeUiPhase.failed)
            _ErrorNotice(copy: copy, message: state.errorMessage),
          if (state.phase == RewriteUpgradeUiPhase.exportingBackup ||
              state.phase == RewriteUpgradeUiPhase.resetting) ...[
            _ProgressNotice(copy: copy, phase: state.phase),
            const SizedBox(height: AppSpacing.md),
          ],
          if (state.phase == RewriteUpgradeUiPhase.backupReady) ...[
            _BackupReadyNotice(copy: copy, path: state.backupPath),
            const SizedBox(height: AppSpacing.md),
          ],
          _ActionArea(
            copy: copy,
            state: state,
            busy: busy,
            onExport: onExport,
            onRetry: onRetry,
            onReset: onReset,
          ),
        ],
      ),
    );
  }
}

class _StepsCard extends StatelessWidget {
  const _StepsCard({
    required this.copy,
    required this.phase,
    required this.failureStep,
  });

  final _UpgradeCopy copy;
  final RewriteUpgradeUiPhase phase;
  final RewriteUpgradeUiFailureStep? failureStep;

  int get _activeStep => switch (phase) {
    RewriteUpgradeUiPhase.backupRequired ||
    RewriteUpgradeUiPhase.exportingBackup => 0,
    RewriteUpgradeUiPhase.failed => switch (failureStep) {
      RewriteUpgradeUiFailureStep.reset => 1,
      _ => 0,
    },
    RewriteUpgradeUiPhase.backupReady || RewriteUpgradeUiPhase.resetting => 1,
    RewriteUpgradeUiPhase.completed => 2,
    RewriteUpgradeUiPhase.checking => -1,
  };

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          children: [
            _UpgradeStep(
              index: 0,
              activeStep: _activeStep,
              title: copy.backupStepTitle,
              message: copy.backupStepMessage,
            ),
            const SizedBox(height: AppSpacing.sm),
            _UpgradeStep(
              index: 1,
              activeStep: _activeStep,
              title: copy.resetStepTitle,
              message: copy.resetStepMessage,
            ),
            const SizedBox(height: AppSpacing.sm),
            _UpgradeStep(
              index: 2,
              activeStep: _activeStep,
              title: copy.importStepTitle,
              message: copy.importStepMessage,
            ),
          ],
        ),
      ),
    );
  }
}

class _UpgradeStep extends StatelessWidget {
  const _UpgradeStep({
    required this.index,
    required this.activeStep,
    required this.title,
    required this.message,
  });

  final int index;
  final int activeStep;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final completed = index < activeStep;
    final active = index == activeStep;
    final foreground = completed || active
        ? colors.onPrimaryContainer
        : colors.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: completed ? '$title, completed' : title,
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: completed || active
                  ? colors.primaryContainer
                  : colors.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: completed
                ? Icon(Icons.check_rounded, size: 20, color: foreground)
                : Text(
                    '${index + 1}',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: foreground),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PreservedDataNotice extends StatelessWidget {
  const _PreservedDataNotice({required this.copy, this.compact = false});

  final _UpgradeCopy copy;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: copy.preservedData,
      child: Container(
        padding: EdgeInsets.all(compact ? AppSpacing.sm : AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.tertiaryContainer.withValues(alpha: 0.55),
          borderRadius: AppRadii.medium,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.folder_copy_rounded, color: colors.onTertiaryContainer),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                copy.preservedData,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onTertiaryContainer,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.copy, this.message});

  final _UpgradeCopy copy;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('rewrite-upgrade-error'),
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: AppRadii.medium,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: colors.onErrorContainer),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  copy.errorTitle,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.onErrorContainer,
                  ),
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  message?.trim().isNotEmpty == true
                      ? message!.trim()
                      : copy.errorFallback,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressNotice extends StatelessWidget {
  const _ProgressNotice({required this.copy, required this.phase});

  final _UpgradeCopy copy;
  final RewriteUpgradeUiPhase phase;

  @override
  Widget build(BuildContext context) {
    final exporting = phase == RewriteUpgradeUiPhase.exportingBackup;
    final text = exporting ? copy.exporting : copy.resetting;
    return Semantics(
      liveRegion: true,
      label: text,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          const LinearProgressIndicator(),
        ],
      ),
    );
  }
}

class _BackupReadyNotice extends StatelessWidget {
  const _BackupReadyNotice({required this.copy, this.path});

  final _UpgradeCopy copy;
  final String? path;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('rewrite-upgrade-backup-ready'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: AppRadii.medium,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_rounded, color: colors.onPrimaryContainer),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  copy.backupReady,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.onPrimaryContainer,
                  ),
                ),
                if (path?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: AppSpacing.xxs),
                  SelectionArea(
                    child: Text(
                      path!.trim(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionArea extends StatelessWidget {
  const _ActionArea({
    required this.copy,
    required this.state,
    required this.busy,
    required this.onExport,
    required this.onRetry,
    required this.onReset,
  });

  final _UpgradeCopy copy;
  final RewriteUpgradePageState state;
  final bool busy;
  final VoidCallback onExport;
  final VoidCallback onRetry;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    if (state.phase == RewriteUpgradeUiPhase.exportingBackup ||
        state.phase == RewriteUpgradeUiPhase.resetting) {
      return const SizedBox.shrink();
    }
    if (state.phase == RewriteUpgradeUiPhase.failed) {
      return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: FilledButton.icon(
          key: const ValueKey('rewrite-upgrade-retry'),
          onPressed: busy ? null : onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(copy.retry),
        ),
      );
    }
    if (state.phase == RewriteUpgradeUiPhase.backupReady) {
      return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: FilledButton.icon(
          key: const ValueKey('rewrite-upgrade-reset'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: busy ? null : onReset,
          icon: const Icon(Icons.restart_alt_rounded),
          label: Text(copy.resetAndContinue),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          copy.externalBackupWarning,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FilledButton.icon(
            key: const ValueKey('rewrite-upgrade-export'),
            onPressed: busy ? null : onExport,
            icon: const Icon(Icons.save_alt_rounded),
            label: Text(copy.exportBackup),
          ),
        ),
      ],
    );
  }
}

class _UpgradeCopy {
  const _UpgradeCopy._({required this.isChinese, required this.isTraditional});

  factory _UpgradeCopy.of(BuildContext context) {
    final locale = Localizations.localeOf(context);
    return _UpgradeCopy._(
      isChinese: locale.languageCode == 'zh',
      isTraditional:
          locale.languageCode == 'zh' &&
          (locale.scriptCode == 'Hant' ||
              locale.countryCode == 'TW' ||
              locale.countryCode == 'HK' ||
              locale.countryCode == 'MO'),
    );
  }

  final bool isChinese;
  final bool isTraditional;

  String _text(String simplified, String traditional, String english) {
    if (!isChinese) return english;
    return isTraditional ? traditional : simplified;
  }

  String get checkingTitle =>
      _text('正在检查数据版本', '正在檢查資料版本', 'Checking data version');
  String get checkingMessage => _text(
    '这不会修改任何本地文件。',
    '這不會修改任何本機檔案。',
    'No local files are changed during this check.',
  );
  String get title => _text('需要完成数据升级', '需要完成資料升級', 'Data upgrade required');
  String get introduction => _text(
    '新版使用重新设计的数据结构。为避免旧数据在转换时损坏，必须先导出并验证完整备份，再重置旧版应用数据。',
    '新版使用重新設計的資料結構。為避免舊資料在轉換時損壞，必須先匯出並驗證完整備份，再重設舊版應用程式資料。',
    'This version uses a redesigned data format. Export and verify a complete backup before resetting legacy app data.',
  );
  String get backupStepTitle =>
      _text('导出完整备份', '匯出完整備份', 'Export a complete backup');
  String get backupStepMessage => _text(
    '选择应用数据目录以外的位置，备份通过 V2 完整性校验后才能继续。',
    '選擇應用程式資料目錄以外的位置，備份通過 V2 完整性驗證後才能繼續。',
    'Choose a location outside the app data directory. The backup must pass V2 integrity checks.',
  );
  String get resetStepTitle =>
      _text('重置旧版应用数据', '重設舊版應用程式資料', 'Reset legacy app data');
  String get resetStepMessage => _text(
    '二次确认后仅重置数据库、设置和索引。',
    '二次確認後僅重設資料庫、設定和索引。',
    'After confirmation, only databases, settings, and indexes are reset.',
  );
  String get importStepTitle =>
      _text('手动导入备份', '手動匯入備份', 'Import the backup manually');
  String get importStepMessage => _text(
    '进入新版后，在设置中选择刚才导出的备份恢复数据。',
    '進入新版後，在設定中選擇剛才匯出的備份還原資料。',
    'After entering the new version, restore data by selecting the exported backup in Settings.',
  );
  String get preservedData => _text(
    '本地漫画图片、已压缩漫画、默认本地漫画目录和已关联的外部目录都会保留，不会被重置删除。',
    '本機漫畫圖片、已壓縮漫畫、預設本機漫畫目錄和已連結的外部目錄都會保留，不會被重設刪除。',
    'Downloaded images, compressed comics, the default local library, and linked external folders are preserved.',
  );
  String get externalBackupWarning => _text(
    '不要把备份保存在应用数据目录内；重置前会再次验证备份位置和内容。',
    '不要把備份儲存在應用程式資料目錄內；重設前會再次驗證備份位置和內容。',
    'Do not save the backup inside the app data directory. Its location and contents are verified again before reset.',
  );
  String get exportBackup =>
      _text('导出并验证备份', '匯出並驗證備份', 'Export and verify backup');
  String get exporting => _text(
    '正在创建并校验完整备份，请勿关闭应用',
    '正在建立並驗證完整備份，請勿關閉應用程式',
    'Creating and verifying the complete backup. Keep the app open.',
  );
  String get backupReady =>
      _text('完整备份已验证', '完整備份已驗證', 'Complete backup verified');
  String get resetAndContinue => _text('重置并继续', '重設並繼續', 'Reset and continue');
  String get resetting => _text(
    '正在安全重置旧版应用数据，请勿关闭应用',
    '正在安全重設舊版應用程式資料，請勿關閉應用程式',
    'Safely resetting legacy app data. Keep the app open.',
  );
  String get confirmTitle =>
      _text('确认重置旧版数据', '確認重設舊版資料', 'Confirm legacy data reset');
  String get confirmMessage => _text(
    '重置后旧版数据库、设置和索引将无法直接恢复，必须使用刚才导出的完整备份。',
    '重設後舊版資料庫、設定和索引將無法直接還原，必須使用剛才匯出的完整備份。',
    'Legacy databases, settings, and indexes cannot be restored directly after reset. Use the complete backup you just exported.',
  );
  String get confirmAcknowledgement => _text(
    '我已确认完整备份保存在应用数据目录以外',
    '我已確認完整備份儲存在應用程式資料目錄以外',
    'I confirmed the complete backup is outside the app data directory',
  );
  String get confirmReset => _text('确认重置', '確認重設', 'Confirm reset');
  String get cancel => _text('取消', '取消', 'Cancel');
  String get completedTitle =>
      _text('数据升级已完成', '資料升級已完成', 'Data upgrade complete');
  String get completedMessage => _text(
    '正在进入新版。之后可在设置中手动导入完整备份。',
    '正在進入新版。之後可在設定中手動匯入完整備份。',
    'Opening the new version. You can then import the complete backup manually in Settings.',
  );
  String get errorTitle =>
      _text('操作未完成', '操作未完成', 'The operation did not complete');
  String get errorFallback => _text(
    '请确认备份位置可写且空间充足，然后重试。',
    '請確認備份位置可寫入且空間充足，然後重試。',
    'Check that the backup location is writable and has enough free space, then retry.',
  );
  String get retry => _text('重试', '重試', 'Retry');
}
