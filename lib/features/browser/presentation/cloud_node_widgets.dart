import 'package:flutter/material.dart';

import '../../download/presentation/download_controller.dart';
import '../domain/cloud_node.dart';

final class CloudNodeTile extends StatelessWidget {
  const CloudNodeTile({
    required this.node,
    required this.onTap,
    required this.onInfo,
    super.key,
  });

  final CloudNode node;
  final VoidCallback onTap;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      leading: Icon(
        node.isFolder ? Icons.folder_rounded : _fileIcon(node.name),
        size: 34,
        color: node.isFolder
            ? const Color(0xff56d6c9)
            : Theme.of(context).colorScheme.primary,
      ),
      title: Text(node.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(_nodeSubtitle(node)),
      trailing: IconButton(
        tooltip: 'Сведения',
        onPressed: onInfo,
        icon: const Icon(Icons.info_outline_rounded),
      ),
      onTap: onTap,
    ),
  );
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
    'csv' => Icons.description_rounded,
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
