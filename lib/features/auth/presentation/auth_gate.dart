import 'package:flutter/material.dart';

import '../application/auth_repository.dart';
import '../../browser/application/browser_repository.dart';
import '../../browser/presentation/browser_page.dart';
import '../../download/application/download_repository.dart';
import '../../download/presentation/download_controller.dart';
import '../../search/application/search_repository.dart';
import 'auth_controller.dart';
import 'login_page.dart';

final class AuthGate extends StatefulWidget {
  const AuthGate({
    required this.repository,
    required this.browserRepository,
    required this.searchRepository,
    required this.downloadRepository,
    super.key,
  });

  final AuthRepository repository;
  final BrowserRepository browserRepository;
  final SearchRepository searchRepository;
  final DownloadRepository downloadRepository;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

final class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  late final AuthController _controller;
  late final DownloadController _downloadController;
  String? _downloadAccount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _downloadController = DownloadController(widget.downloadRepository);
    _controller = AuthController(widget.repository)..initialize();
    _controller.addListener(_onAuthChanged);
  }

  void _onAuthChanged() {
    final account = _controller.session?.email.trim().toLowerCase();
    if (_downloadAccount != account) {
      _downloadController.reset();
      _downloadAccount = account;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller.refreshIfNeeded();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onAuthChanged);
    _downloadController.dispose();
    widget.browserRepository.close();
    _controller.dispose();
    super.dispose();
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
        authController: _controller,
      ),
    },
  );
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
