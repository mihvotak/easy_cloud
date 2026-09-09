import 'package:flutter/material.dart';

import '../../auth/presentation/auth_controller.dart';
import '../application/browser_repository.dart';
import '../domain/cloud_node.dart';
import '../domain/cloud_sort.dart';
import 'browser_controller.dart';

final class BrowserPage extends StatefulWidget {
  const BrowserPage({
    required this.repository,
    required this.authController,
    this.path = '/',
    this.title,
    super.key,
  });

  final BrowserRepository repository;
  final AuthController authController;
  final String path;
  final String? title;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

final class _BrowserPageState extends State<BrowserPage> {
  late final BrowserController _controller;
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _controller = BrowserController(
      repository: widget.repository,
      path: widget.path,
    )..loadInitial();
    _scrollController = ScrollController()..addListener(_onScroll);
    widget.authController.addListener(_onAuthChanged);
  }

  void _onAuthChanged() {
    if (widget.authController.status == AuthStatus.signedIn || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    });
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 480) _controller.loadMore();
  }

  @override
  void dispose() {
    widget.authController.removeListener(_onAuthChanged);
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? _controller.folder?.name ?? 'Easy Cloud'),
        actions: [
          PopupMenuButton<CloudSort>(
            tooltip: 'Сортировка',
            initialValue: _controller.sort,
            onSelected: _controller.changeSort,
            icon: const Icon(Icons.sort_rounded),
            itemBuilder: (context) => [
              for (final option in cloudSortOptions)
                PopupMenuItem(value: option, child: Text(option.label)),
            ],
          ),
          PopupMenuButton<void>(
            tooltip: 'Аккаунт',
            itemBuilder: (context) => [
              PopupMenuItem<void>(
                onTap: widget.authController.logout,
                child: const Row(
                  children: [
                    Icon(Icons.logout_rounded),
                    SizedBox(width: 12),
                    Text('Выйти'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(context),
    ),
  );

  Widget _buildBody(BuildContext context) {
    if (_controller.isInitialLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_controller.initialFailure case final failure?) {
      return _MessageState(
        icon: Icons.cloud_off_rounded,
        title: 'Не удалось открыть папку',
        message: failure.message,
        actionLabel: 'Повторить',
        onAction: _controller.loadInitial,
      );
    }
    if (_controller.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _controller.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [SizedBox(height: 160), _EmptyFolder()],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _controller.refresh,
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        itemCount: _controller.items.length + 1,
        itemBuilder: (context, index) {
          if (index == _controller.items.length) return _buildFooter(context);
          final node = _controller.items[index];
          return _CloudNodeTile(
            node: node,
            onTap: () => node.isFolder
                ? _openFolder(node)
                : _showMetadata(context, node),
            onInfo: () => _showMetadata(context, node),
          );
        },
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    if (_controller.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_controller.loadMoreFailure case final failure?) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            Text(failure.message, textAlign: TextAlign.center),
            TextButton(
              onPressed: _controller.loadMore,
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }
    return const SizedBox(height: 8);
  }

  void _openFolder(CloudNode folder) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => BrowserPage(
          repository: widget.repository,
          authController: widget.authController,
          path: folder.path,
          title: folder.name,
        ),
      ),
    );
  }

  Future<void> _showMetadata(BuildContext context, CloudNode node) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => _MetadataSheet(node: node),
      );
}

final class _CloudNodeTile extends StatelessWidget {
  const _CloudNodeTile({
    required this.node,
    required this.onTap,
    required this.onInfo,
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

final class _MetadataSheet extends StatelessWidget {
  const _MetadataSheet({required this.node});

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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(node.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
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
        ),
      ),
    );
  }
}

final class _EmptyFolder extends StatelessWidget {
  const _EmptyFolder();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Icon(
        Icons.folder_open_rounded,
        size: 70,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: .65),
      ),
      const SizedBox(height: 16),
      Text('Папка пуста', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 6),
      Text(
        'Потяните вниз, чтобы обновить',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );
}

final class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 62, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 18),
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton.tonal(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    ),
  );
}

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
