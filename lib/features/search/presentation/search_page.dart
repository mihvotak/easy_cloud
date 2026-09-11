import 'dart:async';

import 'package:flutter/material.dart' hide SearchController;

import '../../auth/presentation/auth_controller.dart';
import '../../browser/application/browser_repository.dart';
import '../../browser/domain/cloud_node.dart';
import '../../browser/presentation/browser_page.dart';
import '../../browser/presentation/cloud_node_widgets.dart';
import '../../download/presentation/download_controller.dart';
import '../../editor/application/editor_save_repository.dart';
import '../../editor/presentation/editor_page.dart';
import '../../offline/application/offline_file_index.dart';
import '../../offline/application/offline_target_queue_controller.dart';
import '../../offline/presentation/offline_availability_controller.dart';
import '../../open/application/open_file_controller.dart';
import '../../open/domain/open_file_failure.dart';
import '../application/search_repository.dart';
import 'search_controller.dart';

final class SearchPage extends StatefulWidget {
  const SearchPage({
    required this.repository,
    required this.browserRepository,
    required this.authController,
    required this.downloadController,
    required this.openFileController,
    this.editorSaveService,
    required this.offlineFileIndex,
    this.offlineTargetIndex,
    this.offlineTargetQueueController,
    this.path = '/',
    super.key,
  });

  final SearchRepository repository;
  final BrowserRepository browserRepository;
  final AuthController authController;
  final DownloadController downloadController;
  final OpenFileController openFileController;
  final EditorSaveService? editorSaveService;
  final OfflineFileIndex offlineFileIndex;
  final OfflineTargetIndex? offlineTargetIndex;
  final OfflineTargetQueueController? offlineTargetQueueController;
  final String path;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

final class _SearchPageState extends State<SearchPage> {
  late final SearchController _controller;
  late final TextEditingController _textController;
  OfflineAvailabilityController? _availabilityController;
  String? _availabilityEmail;
  Set<String> _availabilityPaths = <String>{};
  final _offlineOperations = <String>{};

  @override
  void initState() {
    super.initState();
    _controller = SearchController(
      repository: widget.repository,
      path: widget.path,
    );
    _controller.addListener(_onVisibleResultsChanged);
    _textController = TextEditingController();
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

  void _onVisibleResultsChanged() => _loadAvailabilityForVisibleResults();

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
    _loadAvailabilityForVisibleResults(force: true);
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
    _loadAvailabilityForVisibleResults();
  }

  void _loadAvailabilityForVisibleResults({bool force = false}) {
    final availabilityController = _availabilityController;
    if (availabilityController == null) return;

    final includeFolders =
        widget.offlineTargetQueueController != null ||
        widget.offlineTargetIndex != null;
    final paths = widget.authController.session == null
        ? <String>{}
        : _controller.results
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

  @override
  void dispose() {
    widget.authController.removeListener(_onAuthChanged);
    widget.downloadController.removeListener(_onDownloadChanged);
    widget.openFileController.removeListener(_onOpenFileChanged);
    widget.offlineTargetQueueController?.removeListener(_onQueueChanged);
    _controller.removeListener(_onVisibleResultsChanged);
    _textController.dispose();
    _disposeAvailabilityController();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Поиск')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                controller: _textController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (value) {
                  if (value.isEmpty) {
                    _controller.clear();
                  } else {
                    setState(() {});
                  }
                },
                onSubmitted: _controller.search,
                decoration: InputDecoration(
                  hintText: 'Имя файла или папки',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_textController.text.isNotEmpty)
                        IconButton(
                          tooltip: 'Очистить',
                          onPressed: _clear,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      IconButton(
                        tooltip: 'Найти',
                        onPressed: () =>
                            _controller.search(_textController.text),
                        icon: const Icon(Icons.arrow_forward_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    ),
  );

  Widget _buildBody(BuildContext context) {
    if (_controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_controller.error case final failure?) {
      return _SearchMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Поиск не выполнен',
        message: failure.message,
        actionLabel: 'Повторить',
        onAction: () => _controller.search(_controller.query),
      );
    }
    if (!_controller.hasSearched) {
      return const _SearchMessage(
        icon: Icons.manage_search_rounded,
        title: 'Поиск в облаке',
        message: 'Введите не менее 2 символов и нажмите кнопку поиска.',
      );
    }
    if (_controller.isQueryTooShort) {
      return const _SearchMessage(
        icon: Icons.short_text_rounded,
        title: 'Слишком короткий запрос',
        message: 'Введите не менее 2 символов.',
      );
    }
    if (_controller.results.isEmpty) {
      return const _SearchMessage(
        icon: Icons.search_off_rounded,
        title: 'Ничего не найдено',
        message: 'Попробуйте изменить запрос.',
      );
    }
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 28),
      itemCount: _controller.results.length,
      itemBuilder: (context, index) {
        final node = _controller.results[index];
        final downloadState = widget.downloadController.stateFor(node.path);
        final downloadActive = _isDownloadActive(downloadState);
        final openProgress = widget.openFileController.progressFor(node.path);
        final hasOpenProgress = openProgress != null;
        return CloudNodeTile(
          node: node,
          onTap: () => node.isFolder ? _openFolder(node) : _openFile(node),
          onInfo: () => node.isFolder
              ? showCloudNodeMetadata(context, node)
              : _showFile(node),
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
    );
  }

  void _clear() {
    _textController.clear();
    _controller.clear();
  }

  void _openFolder(CloudNode folder) =>
      _openBrowser(path: folder.path, title: folder.name);

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
    final currentQuery = _controller.query;
    if (currentQuery.isNotEmpty) await _controller.search(currentQuery);
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

  Future<void> _showFile(CloudNode file) => showCloudNodeMetadata(
    context,
    file,
    downloadController: widget.downloadController,
    actionLabel: 'Открыть папку',
    onAction: () {
      Navigator.of(context).pop();
      final parentPath = _parentPath(file.path);
      _openBrowser(path: parentPath, title: _pathName(parentPath));
    },
  );

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

  void _openBrowser({required String path, required String title}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => BrowserPage(
          repository: widget.browserRepository,
          searchRepository: widget.repository,
          downloadController: widget.downloadController,
          openFileController: widget.openFileController,
          editorSaveService: widget.editorSaveService,
          offlineFileIndex: widget.offlineFileIndex,
          offlineTargetIndex: widget.offlineTargetIndex,
          offlineTargetQueueController: widget.offlineTargetQueueController,
          authController: widget.authController,
          path: path,
          title: title,
        ),
      ),
    );
  }

  Future<void> _reloadAvailability() async {
    final controller = _availabilityController;
    if (controller == null) return;
    await controller.load(_availabilityPaths);
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

final class _SearchMessage extends StatelessWidget {
  const _SearchMessage({
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
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
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
    ),
  );
}

String _parentPath(String path) {
  final normalized = path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  final separator = normalized.lastIndexOf('/');
  return separator <= 0 ? '/' : normalized.substring(0, separator);
}

String _pathName(String path) {
  if (path == '/') return 'Облако';
  return path.substring(path.lastIndexOf('/') + 1);
}
