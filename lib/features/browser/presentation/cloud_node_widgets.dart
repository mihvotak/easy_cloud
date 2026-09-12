import 'package:flutter/material.dart';

import '../../download/presentation/download_controller.dart';
import '../../editor/domain/editor_file.dart';
import '../../offline/domain/offline_target.dart';
import '../../offline/domain/offline_target_queue.dart';
import '../domain/cloud_node.dart';

/// The policy represented by the context menu.  It is deliberately separate
/// from the transfer readiness shown by the marker: a target that is still
/// being scanned can already be removed, while it must not be presented as a
/// ready offline file.
enum OfflinePolicy { onlineOnly, direct, inherited }

/// Legacy presentation values kept for the existing file tile callers. New
/// callers should pass [offlinePolicy] and [offlineReadiness] separately.
enum OfflineAvailability {
  onlineOnly('Только онлайн'),
  directReady('Доступен офлайн'),
  inheritedReady('Доступен офлайн через папку'),
  pending('Офлайн-доступ: загрузка…'),
  error('Офлайн-доступ: ошибка');

  const OfflineAvailability(this.label);

  final String label;
}

const offlineTargetFileConfirmationThreshold = 500;
const offlineTargetByteConfirmationThreshold = 524288000;

/// Conservative estimate used by the folder confirmation dialog.
///
/// Mail.ru's `count` on a folder listing describes the immediate children. It
/// is an exact recursive file count only when the response also proves that
/// the folder has no child folders. Otherwise the known count is displayed as
/// a lower bound and the estimate remains unknown.
final class OfflineFolderEstimate {
  const OfflineFolderEstimate({
    required this.files,
    required this.bytes,
    required this.filesAreLowerBound,
    required this.bytesAreUnknown,
  });

  final int? files;
  final int? bytes;
  final bool filesAreLowerBound;
  final bool bytesAreUnknown;

  bool get hasUnknown =>
      files == null || filesAreLowerBound || bytes == null || bytesAreUnknown;

  bool get requiresConfirmation =>
      hasUnknown ||
      (files != null && files! >= offlineTargetFileConfirmationThreshold) ||
      (bytes != null && bytes! >= offlineTargetByteConfirmationThreshold);

  OfflineTargetEstimate get queueEstimate =>
      OfflineTargetEstimate(files: files, bytes: bytes, hasUnknown: hasUnknown);

  List<String> get dialogLines => [
    if (files == null)
      'Количество файлов неизвестно'
    else if (filesAreLowerBound)
      'Файлов: не менее $files'
    else
      'Файлов: $files',
    if (bytes == null || bytesAreUnknown)
      'Размер неизвестен'
    else
      'Размер: ${_formatBytes(bytes!)}',
  ];
}

OfflineFolderEstimate estimateOfflineFolder(CloudNode folder) {
  if (!folder.isFolder) {
    throw ArgumentError.value(folder.type, 'folder.type');
  }

  final childFolders = folder.folderCount;
  final hasProvenNoNestedFolders = childFolders == 0;
  final rawFiles = folder.fileCount;
  final files = rawFiles != null && rawFiles >= 0 ? rawFiles : null;
  final filesAreLowerBound = !hasProvenNoNestedFolders;

  // A folder size is treated as an exact aggregate only together with the
  // same no-nested-folders proof. A nested or incomplete response must be
  // confirmed even when it happens to contain a size field.
  final rawBytes = folder.size;
  final bytes = hasProvenNoNestedFolders && rawBytes != null && rawBytes >= 0
      ? rawBytes
      : null;

  return OfflineFolderEstimate(
    files: files,
    bytes: bytes,
    filesAreLowerBound: filesAreLowerBound,
    bytesAreUnknown: bytes == null,
  );
}

Future<bool?> showOfflineFolderConfirmation(
  BuildContext context,
  CloudNode folder,
  OfflineFolderEstimate estimate,
) => showDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Работать оффлайн?'),
    content: SingleChildScrollView(
      child: ListBody(
        children: [
          Text('Будет подготовлено всё содержимое папки «${folder.name}».'),
          const SizedBox(height: 12),
          for (final line in estimate.dialogLines) Text(line),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Продолжить'),
      ),
    ],
  ),
);

enum _CloudNodeAction { info, openExternally, workOffline, onlyOnline, saveAs }

final class CloudNodeTile extends StatelessWidget {
  const CloudNodeTile({
    required this.node,
    required this.onTap,
    required this.onInfo,
    this.offlinePolicy = OfflinePolicy.onlineOnly,
    this.offlineReadiness = OfflineReadiness.idle,
    this.offlineAvailability = OfflineAvailability.onlineOnly,
    this.onWorkOffline,
    this.onOnlyOnline,
    this.onSaveAs,
    this.onOpenExternally,
    this.progress,
    this.progressIndeterminate = false,
    super.key,
  });

  final CloudNode node;
  final VoidCallback onTap;
  final VoidCallback onInfo;
  final OfflinePolicy offlinePolicy;
  final OfflineReadiness offlineReadiness;
  final OfflineAvailability offlineAvailability;
  final VoidCallback? onWorkOffline;
  final VoidCallback? onOnlyOnline;
  final VoidCallback? onSaveAs;
  final VoidCallback? onOpenExternally;
  final double? progress;
  final bool progressIndeterminate;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasProgress = progressIndeterminate || progress != null;
    final presentation = _presentationState();
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: hasProgress ? Clip.antiAlias : Clip.none,
      child: Stack(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 4,
            ),
            leading: _buildLeading(context, presentation),
            title: Text(
              node.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(_nodeSubtitle(node)),
            trailing: SizedBox(
              width: kMinInteractiveDimension,
              height: kMinInteractiveDimension,
              child: PopupMenuButton<_CloudNodeAction>(
                tooltip: 'Действия для ${node.name}',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: _onActionSelected,
                itemBuilder: (context) => _buildMenuItems(presentation),
              ),
            ),
            onTap: onTap,
          ),
          if (hasProgress)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _TransferProgress(
                value: progressIndeterminate ? null : _clampProgress(progress),
              ),
            ),
        ],
      ),
    );
  }

  _OfflinePresentationState _presentationState() {
    final legacy = offlineAvailability;
    // The old property is intentionally recognized only when it carries a
    // non-default ready state. This preserves existing direct-file callers
    // while making the new policy/readiness pair authoritative for queue UI.
    if (legacy != OfflineAvailability.onlineOnly) {
      return switch (legacy) {
        OfflineAvailability.directReady => const _OfflinePresentationState(
          policy: OfflinePolicy.direct,
          readiness: OfflineReadiness.ready,
        ),
        OfflineAvailability.inheritedReady => const _OfflinePresentationState(
          policy: OfflinePolicy.inherited,
          readiness: OfflineReadiness.ready,
        ),
        OfflineAvailability.pending => const _OfflinePresentationState(
          policy: OfflinePolicy.direct,
          readiness: OfflineReadiness.downloading,
        ),
        OfflineAvailability.error => const _OfflinePresentationState(
          policy: OfflinePolicy.direct,
          readiness: OfflineReadiness.error,
        ),
        OfflineAvailability.onlineOnly => throw StateError(
          'The online-only legacy state is handled above.',
        ),
      };
    }
    return _OfflinePresentationState(
      policy: offlinePolicy,
      readiness: offlineReadiness,
    );
  }

  void _onActionSelected(_CloudNodeAction action) {
    switch (action) {
      case _CloudNodeAction.info:
        onInfo();
      case _CloudNodeAction.openExternally:
        onOpenExternally?.call();
      case _CloudNodeAction.workOffline:
        onWorkOffline?.call();
      case _CloudNodeAction.onlyOnline:
        onOnlyOnline?.call();
      case _CloudNodeAction.saveAs:
        onSaveAs?.call();
    }
  }

  List<PopupMenuEntry<_CloudNodeAction>> _buildMenuItems(
    _OfflinePresentationState presentation,
  ) {
    final items = <PopupMenuEntry<_CloudNodeAction>>[
      _menuItem(
        _CloudNodeAction.info,
        icon: Icons.info_outline_rounded,
        label: 'Инфо',
      ),
    ];

    if (node.isFolder) {
      final action = switch (presentation.policy) {
        OfflinePolicy.onlineOnly => _CloudNodeAction.workOffline,
        OfflinePolicy.direct ||
        OfflinePolicy.inherited => _CloudNodeAction.onlyOnline,
      };
      final label = switch (action) {
        _CloudNodeAction.workOffline => 'Работать оффлайн',
        _CloudNodeAction.onlyOnline => 'Только онлайн',
        _ => throw StateError('Unsupported folder action: $action'),
      };
      final callback = switch (action) {
        _CloudNodeAction.workOffline => onWorkOffline,
        _CloudNodeAction.onlyOnline => onOnlyOnline,
        _ => null,
      };
      items.add(
        _menuItem(
          action,
          icon: action == _CloudNodeAction.workOffline
              ? Icons.download_rounded
              : Icons.cloud_off_rounded,
          label: label,
          enabled:
              presentation.policy != OfflinePolicy.inherited &&
              callback != null,
        ),
      );
      return items;
    }

    if (isEditableTextFile(node.name)) {
      items.add(
        _menuItem(
          _CloudNodeAction.openExternally,
          icon: Icons.open_in_new_rounded,
          label: 'Открыть вовне',
          enabled: onOpenExternally != null,
        ),
      );
    }

    switch (presentation.policy) {
      case OfflinePolicy.onlineOnly:
        items.add(
          _menuItem(
            _CloudNodeAction.workOffline,
            icon: Icons.download_rounded,
            label: 'Работать оффлайн',
            enabled: onWorkOffline != null,
          ),
        );
      case OfflinePolicy.direct:
        items.add(
          _menuItem(
            _CloudNodeAction.onlyOnline,
            icon: Icons.cloud_off_rounded,
            label: 'Только онлайн',
            enabled: onOnlyOnline != null,
          ),
        );
      case OfflinePolicy.inherited:
        items.add(
          _menuItem(
            _CloudNodeAction.onlyOnline,
            icon: Icons.cloud_off_rounded,
            label: 'Только онлайн',
            enabled: false,
          ),
        );
    }
    items.add(
      _menuItem(
        _CloudNodeAction.saveAs,
        icon: Icons.save_rounded,
        label: 'Сохранить как',
        enabled: onSaveAs != null,
      ),
    );
    return items;
  }

  PopupMenuItem<_CloudNodeAction> _menuItem(
    _CloudNodeAction action, {
    required IconData icon,
    required String label,
    bool enabled = true,
  }) => PopupMenuItem<_CloudNodeAction>(
    value: action,
    enabled: enabled,
    child: Row(
      children: [
        Icon(icon),
        const SizedBox(width: 12),
        Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
      ],
    ),
  );

  Widget _buildLeading(
    BuildContext context,
    _OfflinePresentationState presentation,
  ) => SizedBox(
    width: 34,
    height: 34,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Align(
          alignment: Alignment.center,
          child: Icon(
            node.isFolder ? Icons.folder_rounded : _fileIcon(node.name),
            size: 34,
            color: node.isFolder
                ? const Color(0xff56d6c9)
                : Theme.of(context).colorScheme.primary,
          ),
        ),
        Positioned(
          right: -2,
          bottom: -2,
          child: _OfflineAvailabilityMarker(presentation),
        ),
      ],
    ),
  );
}

final class _OfflineAvailabilityMarker extends StatelessWidget {
  const _OfflineAvailabilityMarker(this.presentation);

  final _OfflinePresentationState presentation;

  @override
  Widget build(BuildContext context) {
    final markerLabel = _markerLabel(presentation);
    final semanticsLabel = markerLabel.startsWith('Офлайн-доступ:')
        ? markerLabel
        : 'Офлайн-доступ: $markerLabel';
    return Semantics(
      container: true,
      label: semanticsLabel,
      child: Tooltip(
        message: markerLabel,
        excludeFromSemantics: true,
        child: ExcludeSemantics(child: _buildVisual(context)),
      ),
    );
  }

  Widget _buildVisual(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (_isActiveOfflineReadiness(presentation.readiness)) {
      return SizedBox(
        width: 17,
        height: 17,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: colorScheme.primary,
        ),
      );
    }
    if (presentation.readiness == OfflineReadiness.ready) {
      return switch (presentation.policy) {
        OfflinePolicy.onlineOnly => _outlineIcon(context),
        OfflinePolicy.direct => Icon(
          Icons.check_circle_rounded,
          size: 17,
          color: colorScheme.primary,
        ),
        OfflinePolicy.inherited => SizedBox(
          width: 18,
          height: 18,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 17,
                color: colorScheme.tertiary,
              ),
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.lock_rounded,
                    size: 9,
                    color: colorScheme.tertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      };
    }

    return _outlineIcon(
      context,
      color: presentation.readiness == OfflineReadiness.error
          ? colorScheme.error
          : colorScheme.onSurfaceVariant.withValues(alpha: .75),
    );
  }

  Widget _outlineIcon(BuildContext context, {Color? color}) => Icon(
    Icons.check_box_outline_blank_rounded,
    size: 15,
    color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
  );
}

final class _OfflinePresentationState {
  const _OfflinePresentationState({
    required this.policy,
    required this.readiness,
  });

  final OfflinePolicy policy;
  final OfflineReadiness readiness;
}

bool _isActiveOfflineReadiness(OfflineReadiness readiness) =>
    switch (readiness) {
      OfflineReadiness.queued ||
      OfflineReadiness.downloading ||
      OfflineReadiness.verifying => true,
      OfflineReadiness.idle ||
      OfflineReadiness.ready ||
      OfflineReadiness.error => false,
    };

String _markerLabel(_OfflinePresentationState presentation) {
  if (presentation.readiness == OfflineReadiness.error) {
    return 'Офлайн-доступ: ошибка';
  }
  if (presentation.readiness != OfflineReadiness.idle &&
      presentation.readiness != OfflineReadiness.ready) {
    return 'Офлайн-доступ: загрузка…';
  }
  if (presentation.policy == OfflinePolicy.onlineOnly) return 'Только онлайн';
  if (presentation.readiness == OfflineReadiness.ready) {
    return switch (presentation.policy) {
      OfflinePolicy.onlineOnly => 'Только онлайн',
      OfflinePolicy.direct => 'Доступен офлайн',
      OfflinePolicy.inherited => 'Доступен офлайн через папку',
    };
  }
  return 'Офлайн-доступ: загрузка…';
}

final class _TransferProgress extends StatelessWidget {
  const _TransferProgress({required this.value});

  final double? value;

  @override
  Widget build(BuildContext context) {
    final label = value == null
        ? 'Загрузка файла'
        : 'Прогресс загрузки: ${(value! * 100).round()} процентов';
    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(
        child: SizedBox(
          height: 2,
          child: LinearProgressIndicator(value: value, minHeight: 2),
        ),
      ),
    );
  }
}

double? _clampProgress(double? value) {
  if (value == null) return null;
  return value.clamp(0.0, 1.0).toDouble();
}

Future<void> showCloudNodeMetadata(
  BuildContext context,
  CloudNode node, {
  DownloadController? downloadController,
  String? actionLabel,
  VoidCallback? onAction,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => _MetadataSheet(
    node: node,
    downloadController: downloadController,
    actionLabel: actionLabel,
    onAction: onAction,
  ),
);

final class _MetadataSheet extends StatelessWidget {
  const _MetadataSheet({
    required this.node,
    required this.downloadController,
    required this.actionLabel,
    required this.onAction,
  });

  final CloudNode node;
  final DownloadController? downloadController;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final controller = downloadController;
    return controller == null
        ? _buildContent(context)
        : ListenableBuilder(
            listenable: controller,
            builder: (context, _) => _buildContent(context),
          );
  }

  Widget _buildContent(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(node.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          _MetadataRows(node: node),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonal(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ),
          ],
          if (!node.isFolder && downloadController != null) ...[
            const SizedBox(height: 12),
            _DownloadActions(node: node, controller: downloadController!),
          ],
        ],
      ),
    ),
  );
}

final class _MetadataRows extends StatelessWidget {
  const _MetadataRows({required this.node});

  final CloudNode node;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('Путь', node.path),
      ('Тип', node.isFolder ? 'Папка' : 'Файл'),
      if (node.size case final value?) ('Размер', _formatBytes(value)),
      if (node.modifiedAt case final value?) ('Изменён', _formatDate(value)),
      if (node.fileCount case final value?) ('Файлов', '$value'),
      if (node.folderCount case final value?) ('Папок', '$value'),
      if (node.revision case final value?) ('Ревизия', value),
      if (node.globalRevision case final value?) ('Общая ревизия', value),
      if (node.hash case final value?) ('Хеш', value),
      if (node.virusScan case final value?) ('Проверка', value),
    ];
    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 116,
                  child: Text(
                    row.$1,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(child: SelectableText(row.$2)),
              ],
            ),
          ),
      ],
    );
  }
}

final class _DownloadActions extends StatelessWidget {
  const _DownloadActions({required this.node, required this.controller});

  final CloudNode node;
  final DownloadController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.stateFor(node.path);
    final active =
        state?.status == DownloadItemStatus.resolving ||
        state?.status == DownloadItemStatus.receiving ||
        state?.status == DownloadItemStatus.verifying;
    final failed =
        state?.status == DownloadItemStatus.failed ||
        state?.status == DownloadItemStatus.cancelled;
    final ready = state?.status == DownloadItemStatus.ready;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state != null) ...[
          Text(_downloadStatusText(state)),
          if (active) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: state.fraction),
          ],
          if (state.message case final message?) ...[
            const SizedBox(height: 6),
            Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
        ],
        if (active)
          OutlinedButton.icon(
            onPressed: () => controller.cancel(node.path),
            icon: const Icon(Icons.close_rounded),
            label: const Text('Отменить'),
          )
        else if (failed)
          FilledButton.icon(
            onPressed: () => controller.retry(node),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Повторить'),
          )
        else if (!ready)
          FilledButton.icon(
            onPressed: () => controller.start(node),
            icon: const Icon(Icons.download_rounded),
            label: const Text('Скачать для офлайн-доступа'),
          ),
      ],
    );
  }
}

String _downloadStatusText(DownloadItemState state) => switch (state.status) {
  DownloadItemStatus.resolving => 'Подготовка загрузки…',
  DownloadItemStatus.receiving =>
    state.total == null
        ? 'Скачано ${_formatBytes(state.bytes)}'
        : '${_formatBytes(state.bytes)} из ${_formatBytes(state.total!)}',
  DownloadItemStatus.verifying => 'Проверка файла…',
  DownloadItemStatus.ready =>
    state.cacheHit ? 'Файл уже доступен офлайн' : 'Файл доступен офлайн',
  DownloadItemStatus.failed => 'Ошибка загрузки',
  DownloadItemStatus.cancelled => 'Загрузка отменена',
};

IconData _fileIcon(String name) {
  final extension = name.split('.').last.toLowerCase();
  return switch (extension) {
    'jpg' ||
    'jpeg' ||
    'png' ||
    'gif' ||
    'webp' ||
    'heic' => Icons.image_rounded,
    'txt' ||
    'md' ||
    'json' ||
    'xml' ||
    'yaml' ||
    'yml' ||
    'csv' ||
    'log' ||
    'ini' ||
    'conf' => Icons.description_rounded,
    _ => Icons.insert_drive_file_rounded,
  };
}

String _nodeSubtitle(CloudNode node) {
  if (node.isFolder) {
    final parts = <String>[
      if (node.folderCount case final count?) '$count папок',
      if (node.fileCount case final count?) '$count файлов',
    ];
    return parts.isEmpty ? 'Папка' : parts.join(' · ');
  }
  return [
    if (node.size case final size?) _formatBytes(size),
    if (node.modifiedAt case final date?) _formatDate(date),
  ].join(' · ');
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  const units = ['КБ', 'МБ', 'ГБ', 'ТБ'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value < 10 ? value.toStringAsFixed(1) : value.toStringAsFixed(0)} ${units[unit]}';
}

String _formatDate(DateTime value) {
  final date = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(date.day)}.${two(date.month)}.${date.year} ${two(date.hour)}:${two(date.minute)}';
}
