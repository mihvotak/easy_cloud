import 'dart:async';

import 'package:flutter/material.dart';

import '../../auth/presentation/auth_controller.dart';
import '../../download/presentation/download_controller.dart';
import '../../editor/application/editor_save_repository.dart';
import '../../editor/presentation/editor_page.dart';
import '../../offline/application/offline_file_index.dart';
import '../../offline/application/offline_target_queue_controller.dart';
import '../../offline/presentation/offline_availability_controller.dart';
import '../../offline/presentation/offline_files_page.dart';
import '../../open/application/open_file_controller.dart';
import '../../open/domain/open_file_failure.dart';
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
    required this.openFileController,
    this.editorSaveService,
    required this.offlineFileIndex,
    required this.authController,
    this.offlineTargetIndex,
    this.offlineTargetQueueController,
    this.path = '/',
    this.title,
    super.key,
  });

  final BrowserRepository repository;
  final SearchRepository searchRepository;
  final DownloadController downloadController;
  final OpenFileController openFileController;
  final EditorSaveService? editorSaveService;
  final OfflineFileIndex offlineFileIndex;
  final AuthController authController;
  final OfflineTargetIndex? offlineTargetIndex;
  final OfflineTargetQueueController? offlineTargetQueueController;
  final String path;
  final String? title;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

final class _BrowserPageState extends State<BrowserPage> {
  late final BrowserController _controller;
  late final ScrollController _scrollController;
  OfflineAvailabilityController? _availabilityController;
  String? _availabilityEmail;
  Set<String> _availabilityPaths = <String>{};
  final _offlineOperations = <String>{};

  @override
  void initState() {
    super.initState();
    _controller = BrowserController(
      repository: widget.repository,
      path: widget.path,
    )..loadInitial();
    _controller.addListener(_onVisibleItemsChanged);
    _scrollController = ScrollController()..addListener(_onScroll);
    widget.authController.addListener(_onAuthChanged);
    widget.downloadController.addListener(_onDownloadChanged);
    widget.openFileController.addListener(_onOpenFileChanged);
    widget.offlineTargetQueueController?.addListener(_onQueueChanged);
    _syncAvailabilityWithSession();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    _syncAvailabilityWithSession();
    if (widget.authController.status == AuthStatus.signedIn) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    });
  }

  void _onVisibleItemsChanged() => _loadAvailabilityForVisibleItems();

  void _onAvailabilityChanged() {
    if (mounted) setState(() {});
  }

  void _onDownloadChanged() {
    if (mounted) setState(() {});
  }

  void _onOpenFileChanged() {
    if (mounted) setState(() {});
  }

  void _onQueueChanged() {
    if (!mounted) return;
    _loadAvailabilityForVisibleItems(force: true);
  }

  void _syncAvailabilityWithSession() {
    final email = widget.authController.session?.email;
    if (email == _availabilityEmail &&
        (_availabilityController != null || email == null)) {
      return;
    }

    _disposeAvailabilityController();
    _availabilityEmail = email;
    _availabilityPaths = <String>{};
    if (email == null) return;

    final controller = OfflineAvailabilityController(
      index: widget.offlineFileIndex,
      email: email,
      targetIndex: widget.offlineTargetIndex,
    );
    _availabilityController = controller;
    controller.addListener(_onAvailabilityChanged);
    _loadAvailabilityForVisibleItems();
  }

  void _loadAvailabilityForVisibleItems({bool force = false}) {
    final availabilityController = _availabilityController;
    if (availabilityController == null) return;

    final includeFolders =
        widget.offlineTargetQueueController != null ||
        widget.offlineTargetIndex != null;
    final paths = widget.authController.session == null
        ? <String>{}
        : _controller.items
              .where((node) => includeFolders || !node.isFolder)
              .map((node) => node.path)
              .toSet();
    if (!force && _samePaths(_availabilityPaths, paths)) return;
    _availabilityPaths = paths;
    if (paths.isEmpty) return;
    unawaited(availabilityController.load(paths));
  }

  void _disposeAvailabilityController() {
    final controller = _availabilityController;
    if (controller == null) return;
    controller.removeListener(_onAvailabilityChanged);
    controller.dispose();
    _availabilityController = null;
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 480) _controller.loadMore();
  }

  @override
  void dispose() {
    widget.authController.removeListener(_onAuthChanged);
    widget.downloadController.removeListener(_onDownloadChanged);
    widget.openFileController.removeListener(_onOpenFileChanged);
    widget.offlineTargetQueueController?.removeListener(_onQueueChanged);
    _controller.removeListener(_onVisibleItemsChanged);
    _scrollController.dispose();
    _disposeAvailabilityController();
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
      body: Column(
        children: [
          Expanded(child: _buildBody(context)),
          if (_controller.connectionFailure != null)
            _buildConnectionPanel(context),
        ],
      ),
    ),
  );

  Widget _buildConnectionPanel(BuildContext context) => SafeArea(
    top: false,
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Нет соединения',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: _retryBrowserAndQueue,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, kMinInteractiveDimension),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('Повторить'),
            ),
          ],
        ),
      ),
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
        onAction: _retryBrowserAndQueue,
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
          final downloadState = widget.downloadController.stateFor(node.path);
          final downloadActive = _isDownloadActive(downloadState);
          final openProgress = widget.openFileController.progressFor(node.path);
          final hasOpenProgress = openProgress != null;
          return CloudNodeTile(
            node: node,
            onTap: () => node.isFolder ? _openFolder(node) : _openFile(node),
            onInfo: () => _showMetadata(context, node),
            onWorkOffline: node.isFolder
                ? widget.offlineTargetQueueController == null ||
                          !_folderAvailabilityKnown(node) ||
                          _offlineOperations.contains(node.path)
                      ? null
                      : _offlinePolicyFor(node) == OfflinePolicy.onlineOnly
                      ? () => _workOffline(node)
                      : null
                : () => widget.downloadController.start(node),
            onOnlyOnline: node.isFolder
                ? widget.offlineTargetQueueController == null ||
                          !_folderAvailabilityKnown(node) ||
                          _offlineOperations.contains(node.path)
                      ? null
                      : _isDirectTarget(node)
                      ? () => _makeOnlyOnline(node)
                      : null
                : _offlineOperations.contains(node.path)
                ? null
                : () => _makeOnlyOnline(node),
            onSaveAs: node.isFolder ? null : () => _saveAs(node),
            onOpenExternally: node.isFolder || !isEditableTextFile(node.name)
                ? null
                : () => _openExternally(node),
            offlinePolicy: _offlinePolicyFor(node),
            offlineReadiness: _offlineReadinessFor(node),
            progress: hasOpenProgress
                ? openProgress.fraction
                : downloadActive
                ? downloadState?.fraction
                : null,
            progressIndeterminate: hasOpenProgress
                ? openProgress.fraction == null
                : downloadActive && downloadState?.fraction == null,
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
              onPressed: () => _retryBrowserAndQueue(loadMore: true),
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
          openFileController: widget.openFileController,
          editorSaveService: widget.editorSaveService,
          offlineFileIndex: widget.offlineFileIndex,
          offlineTargetIndex: widget.offlineTargetIndex,
          offlineTargetQueueController: widget.offlineTargetQueueController,
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
          openFileController: widget.openFileController,
          editorSaveService: widget.editorSaveService,
          offlineFileIndex: widget.offlineFileIndex,
          offlineTargetIndex: widget.offlineTargetIndex,
          offlineTargetQueueController: widget.offlineTargetQueueController,
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

  void _openFile(CloudNode node) {
    if (isEditableTextFile(node.name) && widget.editorSaveService != null) {
      unawaited(_openInEditor(node));
      return;
    }
    _openExternally(node);
  }

  void _openExternally(CloudNode node) {
    unawaited(
      widget.openFileController
          .open(node)
          .then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {
              // Keep the UI boundary safe even if an injected implementation
              // violates the controller's typed-failure contract.
              _showOpenFailure();
            },
          ),
    );
  }

  Future<void> _openInEditor(CloudNode node) async {
    final account = widget.authController.session?.email.trim().toLowerCase();
    try {
      final prepared = await widget.openFileController.prepareForEditor(node);
      if (!mounted || prepared == null) return;
      final currentAccount = widget.authController.session?.email
          .trim()
          .toLowerCase();
      if (widget.authController.status != AuthStatus.signedIn ||
          account == null ||
          currentAccount != account) {
        return;
      }
      await Navigator.of(context).push<EditorSaveResult>(
        MaterialPageRoute<EditorSaveResult>(
          builder: (context) => EditorPage(
            preparedFile: prepared,
            editorSaveService: widget.editorSaveService!,
            authController: widget.authController,
            onSaved: _refreshAfterEditorSave,
          ),
        ),
      );
    } on EditorPreparationFailure catch (failure) {
      if (!failure.isQuiet) _showEditorPreparationFailure(failure);
    } catch (_) {
      _showEditorPreparationFailure(
        const EditorPreparationFailure(
          EditorPreparationFailureType.service,
          'Не удалось подготовить файл для встроенного редактора.',
        ),
      );
    }
  }

  Future<void> _refreshAfterEditorSave(EditorSaveResult _) async {
    if (!mounted) return;
    await _controller.refresh();
    if (mounted) await _reloadAvailability();
  }

  void _showEditorPreparationFailure(EditorPreparationFailure failure) {
    if (!mounted) return;
    final message = switch (failure.type) {
      EditorPreparationFailureType.oversize =>
        'Текстовый файл превышает лимит 10 МиБ.',
      EditorPreparationFailureType.malformedUtf8 =>
        'Файл содержит некорректный UTF-8.',
      EditorPreparationFailureType.integrity =>
        'Проверка содержимого файла не пройдена.',
      EditorPreparationFailureType.invalidResponse =>
        'Mail.ru вернул неполные метаданные файла.',
      EditorPreparationFailureType.notFound => 'Удалённый файл недоступен.',
      EditorPreparationFailureType.disk => 'Не удалось прочитать файл.',
      EditorPreparationFailureType.service =>
        'Не удалось подготовить файл для встроенного редактора.',
      EditorPreparationFailureType.cancelled => '',
    };
    if (message.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showOpenFailure() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text(OpenFileFailure.safeMessage)),
      );
  }

  void _saveAs(CloudNode node) {
    unawaited(
      widget.openFileController
          .saveAs(node)
          .then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {
              // The controller suppresses stale attempts and picker
              // cancellation. Only a current preparation/export failure
              // reaches this generic presentation boundary.
              _showSaveAsFailure();
            },
          ),
    );
  }

  void _showSaveAsFailure() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text(OpenFileFailure.safeSaveAsMessage)),
      );
  }

  void _makeOnlyOnline(CloudNode node) {
    unawaited(node.isFolder ? _removeTarget(node) : _removeOffline(node));
  }

  void _workOffline(CloudNode folder) {
    unawaited(_enqueueOffline(folder));
  }

  Future<void> _enqueueOffline(CloudNode folder) async {
    if (!_offlineOperations.add(folder.path)) return;
    if (mounted) setState(() {});
    try {
      final estimate = estimateOfflineFolder(folder);
      if (estimate.requiresConfirmation) {
        if (!mounted) return;
        final confirmed = await showOfflineFolderConfirmation(
          context,
          folder,
          estimate,
        );
        if (confirmed != true) return;
      }
      final queue = widget.offlineTargetQueueController;
      if (queue == null) throw StateError('Offline queue is unavailable.');
      await queue.enqueue(folder, estimate.queueEstimate);
      await _reloadAvailability();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось сделать папку офлайн-доступной.'),
        ),
      );
    } finally {
      _offlineOperations.remove(folder.path);
      if (mounted) setState(() {});
    }
  }

  Future<void> _removeTarget(CloudNode folder) async {
    if (!_offlineOperations.add(folder.path)) return;
    if (mounted) setState(() {});
    try {
      final queue = widget.offlineTargetQueueController;
      if (queue == null) throw StateError('Offline queue is unavailable.');
      await queue.remove(folder.path);
      await _reloadAvailability();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отключить офлайн-доступ.')),
      );
    } finally {
      _offlineOperations.remove(folder.path);
      if (mounted) setState(() {});
    }
  }

  Future<void> _removeOffline(CloudNode node) async {
    try {
      await widget.downloadController.removeOffline(node);
      await _reloadAvailability();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отключить офлайн-доступ.')),
      );
    }
  }

  Future<void> _reloadAvailability() async {
    final controller = _availabilityController;
    if (controller == null) return;
    await controller.load(_availabilityPaths);
  }

  Future<void> _retryBrowserAndQueue({bool loadMore = false}) async {
    try {
      if (loadMore) {
        await _controller.loadMore();
      } else {
        await _controller.retryConnection();
      }
    } finally {
      final queue = widget.offlineTargetQueueController;
      final account = widget.authController.session?.email.trim().toLowerCase();
      if (queue != null && account != null) {
        try {
          if (queue.email != account) {
            await queue.attach(account);
          } else {
            await queue.retry();
          }
        } catch (_) {
          // Browser retry remains useful even when the queue cannot retry yet.
        }
      }
    }
  }

  OfflinePolicy _offlinePolicyFor(CloudNode node) {
    final state = _availabilityController?.stateFor(node.path);
    if (!node.isFolder &&
        (state == null ||
            state.source == OfflineAvailabilitySource.onlineOnly) &&
        _directDownloadReady(node)) {
      return OfflinePolicy.direct;
    }
    return switch (state?.source) {
      OfflineAvailabilitySource.direct ||
      OfflineAvailabilitySource.directTarget => OfflinePolicy.direct,
      OfflineAvailabilitySource.inherited => OfflinePolicy.inherited,
      OfflineAvailabilitySource.onlineOnly || null => OfflinePolicy.onlineOnly,
    };
  }

  OfflineReadiness _offlineReadinessFor(CloudNode node) {
    final state = _availabilityController?.stateFor(node.path);
    if (!node.isFolder && _directDownloadReady(node)) {
      return OfflineReadiness.ready;
    }
    if (state != null) return state.readiness;
    return OfflineReadiness.idle;
  }

  bool _directDownloadReady(CloudNode node) =>
      widget.downloadController.stateFor(node.path)?.status ==
      DownloadItemStatus.ready;

  bool _isDirectTarget(CloudNode node) =>
      _availabilityController?.stateFor(node.path)?.source ==
      OfflineAvailabilitySource.directTarget;

  bool _folderAvailabilityKnown(CloudNode node) {
    final controller = _availabilityController;
    return node.isFolder &&
        controller != null &&
        !controller.isLoading &&
        controller.stateFor(node.path) != null;
  }
}

bool _isDownloadActive(DownloadItemState? state) {
  final status = state?.status;
  return status == DownloadItemStatus.resolving ||
      status == DownloadItemStatus.receiving ||
      status == DownloadItemStatus.verifying;
}

bool _samePaths(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

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
