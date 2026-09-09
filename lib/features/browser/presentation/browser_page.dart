import 'package:flutter/material.dart';

import '../../auth/presentation/auth_controller.dart';
import '../../download/presentation/download_controller.dart';
import '../../offline/application/offline_file_index.dart';
import '../../offline/presentation/offline_files_page.dart';
import '../../search/application/search_repository.dart';
import '../../search/presentation/search_page.dart';
import '../application/browser_repository.dart';
import '../domain/cloud_node.dart';
import '../domain/cloud_sort.dart';
import 'browser_controller.dart';
import 'cloud_node_widgets.dart';

final class BrowserPage extends StatefulWidget {
  const BrowserPage({
    required this.repository,
    required this.searchRepository,
    required this.downloadController,
    required this.offlineFileIndex,
    required this.authController,
    this.path = '/',
    this.title,
    super.key,
  });

  final BrowserRepository repository;
  final SearchRepository searchRepository;
  final DownloadController downloadController;
  final OfflineFileIndex offlineFileIndex;
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
          IconButton(
            tooltip: 'Офлайн-файлы',
            onPressed: _openOfflineFiles,
            icon: const Icon(Icons.offline_pin_rounded),
          ),
          IconButton(
            tooltip: 'Поиск',
            onPressed: _openSearch,
            icon: const Icon(Icons.search_rounded),
          ),
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
          return CloudNodeTile(
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
          searchRepository: widget.searchRepository,
          downloadController: widget.downloadController,
          offlineFileIndex: widget.offlineFileIndex,
          authController: widget.authController,
          path: folder.path,
          title: folder.name,
        ),
      ),
    );
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SearchPage(
          repository: widget.searchRepository,
          browserRepository: widget.repository,
          downloadController: widget.downloadController,
          offlineFileIndex: widget.offlineFileIndex,
          authController: widget.authController,
          path: widget.path,
        ),
      ),
    );
  }

  void _openOfflineFiles() {
    final email = widget.authController.session?.email;
    if (email == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            OfflineFilesPage(index: widget.offlineFileIndex, email: email),
      ),
    );
  }

  Future<void> _showMetadata(BuildContext context, CloudNode node) =>
      showCloudNodeMetadata(
        context,
        node,
        downloadController: widget.downloadController,
      );
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
