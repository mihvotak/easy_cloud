import 'package:flutter/material.dart';

import '../application/offline_file_index.dart';

final class OfflineFilesPage extends StatefulWidget {
  const OfflineFilesPage({required this.index, required this.email, super.key});

  final OfflineFileIndex index;
  final String email;

  @override
  State<OfflineFilesPage> createState() => _OfflineFilesPageState();
}

final class _OfflineFilesPageState extends State<OfflineFilesPage> {
  List<OfflineFileRecord> _records = const [];
  bool _isInitialLoading = true;
  bool _hasError = false;
  var _requestToken = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant OfflineFilesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index || oldWidget.email != widget.email) {
      _load();
    }
  }

  Future<void> _load({bool isRefresh = false}) async {
    final requestToken = ++_requestToken;
    if (!mounted) return;

    setState(() {
      _isInitialLoading = !isRefresh;
      _hasError = false;
    });

    final index = widget.index;
    final email = widget.email;
    try {
      final records = await index.list(email);
      if (!mounted || requestToken != _requestToken) return;
      setState(() {
        _records = List<OfflineFileRecord>.unmodifiable(records);
        _isInitialLoading = false;
      });
    } catch (_) {
      if (!mounted || requestToken != _requestToken) return;
      setState(() {
        _isInitialLoading = false;
        _hasError = true;
      });
    }
  }

  Future<void> _refresh() => _load(isRefresh: true);

  @override
  void dispose() {
    _requestToken++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Офлайн-файлы')),
    body: _buildBody(context),
  );

  Widget _buildBody(BuildContext context) {
    if (_isInitialLoading) {
      return Center(
        child: Semantics(
          label: 'Загрузка офлайн-файлов',
          child: const CircularProgressIndicator(),
        ),
      );
    }
    if (_hasError) {
      return _buildRefreshableMessage(
        context,
        icon: Icons.error_outline_rounded,
        title: 'Не удалось загрузить офлайн-файлы',
        message: 'Список офлайн-файлов временно недоступен.',
        actionLabel: 'Повторить',
        onAction: _load,
      );
    }
    if (_records.isEmpty) {
      return _buildRefreshableMessage(
        context,
        icon: Icons.folder_open_rounded,
        title: 'Нет офлайн-файлов',
        message: 'Здесь появятся файлы, скачанные для офлайн-доступа.',
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        key: const Key('offline-files-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        itemCount: _records.length,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, index) => _OfflineFileTile(
          key: ValueKey<String>('offline-file:${_records[index].path}'),
          record: _records[index],
        ),
      ),
    );
  }

  Widget _buildRefreshableMessage(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) => RefreshIndicator(
    onRefresh: _refresh,
    child: LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: _OfflineFilesMessage(
                icon: icon,
                title: title,
                message: message,
                actionLabel: actionLabel,
                onAction: onAction,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

final class _OfflineFileTile extends StatelessWidget {
  const _OfflineFileTile({required this.record, super.key});

  final OfflineFileRecord record;

  @override
  Widget build(BuildContext context) {
    final size = _formatBytes(record.size);
    final cachedAt = _formatDate(record.cachedAt);
    return Semantics(
      container: true,
      label:
          '${record.name}. Путь: ${record.path}. Размер: $size. Кэширован: $cachedAt.',
      child: Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 8,
          ),
          leading: Icon(
            Icons.insert_drive_file_rounded,
            size: 34,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(
            record.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text('Размер: $size'),
                Text('Кэширован: $cachedAt'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _OfflineFilesMessage extends StatelessWidget {
  const _OfflineFilesMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 64,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: .7),
        ),
        const SizedBox(height: 18),
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 20),
          FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ],
    ),
  );
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
