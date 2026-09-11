import 'dart:async';

import 'package:flutter/material.dart';

import '../application/auth_repository.dart';
import '../../browser/application/browser_repository.dart';
import '../../browser/presentation/browser_page.dart';
import '../../download/application/download_repository.dart';
import '../../download/presentation/download_controller.dart';
import '../../offline/application/offline_file_index.dart';
import '../../offline/application/offline_target_queue_controller.dart';
import '../../open/application/file_opener.dart';
import '../../open/application/open_file_controller.dart';
import '../../search/application/search_repository.dart';
import 'auth_controller.dart';
import 'login_page.dart';

final class AuthGate extends StatefulWidget {
  const AuthGate({
    required this.repository,
    required this.browserRepository,
    required this.searchRepository,
    required this.downloadRepository,
    required this.offlineFileIndex,
    required this.offlineTargetIndex,
    required this.offlineTargetQueueStore,
    required this.fileOpener,
    this.fileExporter,
    super.key,
  });

  final AuthRepository repository;
  final BrowserRepository browserRepository;
  final SearchRepository searchRepository;
  final DownloadRepository downloadRepository;
  final OfflineFileIndex offlineFileIndex;
  final OfflineTargetIndex offlineTargetIndex;
  final OfflineTargetQueueStore offlineTargetQueueStore;
  final FileOpener fileOpener;
  final FileExporter? fileExporter;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

final class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  late final AuthController _controller;
  late final DownloadController _downloadController;
  late final OpenFileController _openFileController;
  late final OfflineTargetQueueController _offlineTargetQueueController;
  String? _downloadAccount;
  Future<void> _queueLifecycle = Future<void>.value();
  Future<void>? _shutdownFuture;
  bool _shuttingDown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _downloadController = DownloadController(widget.downloadRepository);
    final opener = widget.fileOpener;
    _openFileController = OpenFileController(
      widget.downloadRepository,
      opener,
      widget.fileExporter ??
          (opener is FileExporter ? opener as FileExporter : null),
    );
    _offlineTargetQueueController = OfflineTargetQueueController(
      targetIndex: widget.offlineTargetIndex,
      browserRepository: widget.browserRepository,
      downloadRepository: widget.downloadRepository,
      queueStore: widget.offlineTargetQueueStore,
      accountEpochProvider: AuthRepositoryAccountEpochProvider(
        widget.repository,
      ),
    );
    _controller = AuthController(widget.repository);
    _controller.addListener(_onAuthChanged);
    unawaited(_initializeAuth());
  }

  void _onAuthChanged() {
    final account = _currentAccount;
    if (_downloadAccount != account) {
      _downloadController.reset();
      _openFileController.reset();
      _downloadAccount = account;
    }
    _scheduleQueueSync();
  }

  Future<void> _initializeAuth() async {
    try {
      await _controller.initialize();
    } catch (_) {
      // AuthController normally converts failures to state. Keep the widget
      // lifecycle boundary safe if an injected controller implementation
      // escapes an unexpected error.
    }
    _scheduleQueueSync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_resume());
    }
  }

  String? get _currentAccount =>
      widget.repository.currentSession?.email.trim().toLowerCase();

  void _scheduleQueueSync({bool retry = false}) {
    if (_shuttingDown) return;
    final requestedAccount = _currentAccount;
    final operation = _queueLifecycle.then<void>((_) async {
      if (_shuttingDown || requestedAccount != _currentAccount) return;

      final queue = _offlineTargetQueueController;
      if (requestedAccount == null) {
        if (queue.email != null) await queue.detach();
        return;
      }

      if (queue.email != requestedAccount ||
          queue.accountEpoch != widget.repository.sessionEpoch) {
        await queue.attach(requestedAccount);
      }
      if (!_shuttingDown &&
          requestedAccount == _currentAccount &&
          queue.email == requestedAccount) {
        _startCacheReconciliation(requestedAccount);
      }
      if (retry &&
          !_shuttingDown &&
          requestedAccount == _currentAccount &&
          queue.email == requestedAccount) {
        await queue.retry();
      }
    });
    // Keep the serialized tail resolved so a failed attach cannot poison all
    // later account/resume events. The operation itself is deliberately not
    // exposed from this UI callback.
    _queueLifecycle = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
  }

  void _startCacheReconciliation(String account) {
    // Reconciliation is repository-owned work. Do not make queue attachment
    // or browsing wait for a disk/SQLite failure; the next resume or account
    // sync starts a fresh, idempotent pass.
    unawaited(_reconcileAccount(account));
  }

  Future<void> _reconcileAccount(String account) async {
    try {
      await widget.downloadRepository.reconcileAccountCache(
        expectedEmail: account,
      );
    } catch (_) {
      // Lifecycle callbacks must not surface cleanup failures as unhandled
      // futures. The repository leaves failed candidates untouched for the
      // next resume.
    }
  }

  Future<void> _resume() async {
    if (_shuttingDown) return;
    try {
      await _controller.refreshIfNeeded();
    } catch (_) {
      // AuthController maps expected failures to state. A lifecycle callback
      // must not become an unhandled future for an injected implementation.
    }
    _scheduleQueueSync(retry: true);
  }

  @override
  void dispose() {
    _shuttingDown = true;
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onAuthChanged);
    _openFileController.dispose();
    _downloadController.dispose();
    final shutdown = _shutdownFuture ??= _shutdown();
    unawaited(shutdown.catchError((_) {}));
    super.dispose();
  }

  Future<void> _shutdown() async {
    // The queue owns the only asynchronous target workers. It must settle
    // before any of the shared repository/index objects can be closed.
    try {
      await _offlineTargetQueueController.close();
    } catch (_) {
      // Queue close is best-effort at the widget boundary; its close method
      // still waits all owned runtimes before completing.
    }
    try {
      await _queueLifecycle;
    } catch (_) {
      // The lifecycle tail is already made error-resilient in
      // [_scheduleQueueSync].
    }

    _offlineTargetQueueController.dispose();
    try {
      await widget.downloadRepository.close();
    } catch (_) {
      // Continue closing the remaining independently owned resources.
    }
    try {
      widget.browserRepository.close();
    } catch (_) {
      // Continue closing the SQLite and auth resources.
    }
    try {
      await widget.offlineFileIndex.close();
    } catch (_) {
      // AuthController still needs to release its own auth API below.
    }
    _controller.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => switch (_controller.status) {
      AuthStatus.loading => const _StartupPage(),
      AuthStatus.signedOut => LoginPage(controller: _controller),
      AuthStatus.signedIn => BrowserPage(
        repository: widget.browserRepository,
        searchRepository: widget.searchRepository,
        downloadController: _downloadController,
        openFileController: _openFileController,
        offlineFileIndex: widget.offlineFileIndex,
        offlineTargetIndex: widget.offlineTargetIndex,
        offlineTargetQueueController: _offlineTargetQueueController,
        authController: _controller,
      ),
    },
  );
}

/// Production adapter that keeps the queue's account and session epoch tied
/// to the same AuthRepository used by every cloud/download operation.
final class AuthRepositoryAccountEpochProvider implements AccountEpochProvider {
  const AuthRepositoryAccountEpochProvider(this._repository);

  final AuthRepository _repository;

  @override
  String? get currentEmail => _repository.currentSession?.email;

  @override
  int get epoch => _repository.sessionEpoch;
}

final class _StartupPage extends StatelessWidget {
  const _StartupPage();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CloudMark(size: 72),
          SizedBox(height: 28),
          SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ],
      ),
    ),
  );
}

final class CloudMark extends StatelessWidget {
  const CloudMark({this.size = 64, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      boxShadow: [
        BoxShadow(color: Color(0x443278f6), blurRadius: 28, spreadRadius: 2),
      ],
    ),
    child: Image.asset(
      'assets/cloud_logo.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
    ),
  );
}
