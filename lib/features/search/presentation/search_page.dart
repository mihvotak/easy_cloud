import 'package:flutter/material.dart' hide SearchController;

import '../../auth/presentation/auth_controller.dart';
import '../../browser/application/browser_repository.dart';
import '../../browser/domain/cloud_node.dart';
import '../../browser/presentation/browser_page.dart';
import '../../browser/presentation/cloud_node_widgets.dart';
import '../../download/presentation/download_controller.dart';
import '../application/search_repository.dart';
import 'search_controller.dart';

final class SearchPage extends StatefulWidget {
  const SearchPage({
    required this.repository,
    required this.browserRepository,
    required this.authController,
    required this.downloadController,
    this.path = '/',
    super.key,
  });

  final SearchRepository repository;
  final BrowserRepository browserRepository;
  final AuthController authController;
  final DownloadController downloadController;
  final String path;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

final class _SearchPageState extends State<SearchPage> {
  late final SearchController _controller;
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _controller = SearchController(
      repository: widget.repository,
      path: widget.path,
    );
    _textController = TextEditingController();
  }

  @override
  void dispose() {
    _textController.dispose();
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
        return CloudNodeTile(
          node: node,
          onTap: () => node.isFolder ? _openFolder(node) : _showFile(node),
          onInfo: () => node.isFolder
              ? showCloudNodeMetadata(context, node)
              : _showFile(node),
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

  void _openBrowser({required String path, required String title}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => BrowserPage(
          repository: widget.browserRepository,
          searchRepository: widget.repository,
          downloadController: widget.downloadController,
          authController: widget.authController,
          path: path,
          title: title,
        ),
      ),
    );
  }
}

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
