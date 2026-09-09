import 'package:flutter/material.dart';

import '../application/auth_repository.dart';
import '../../browser/application/browser_repository.dart';
import '../../browser/presentation/browser_page.dart';
import 'auth_controller.dart';
import 'login_page.dart';

final class AuthGate extends StatefulWidget {
  const AuthGate({
    required this.repository,
    required this.browserRepository,
    super.key,
  });

  final AuthRepository repository;
  final BrowserRepository browserRepository;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

final class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  late final AuthController _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AuthController(widget.repository)..initialize();
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
    _controller.dispose();
    widget.browserRepository.close();
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
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * .3),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xff56d6c9), Color(0xff3278f6)],
      ),
      boxShadow: const [
        BoxShadow(color: Color(0x443278f6), blurRadius: 28, spreadRadius: 2),
      ],
    ),
    child: Icon(Icons.cloud_rounded, size: size * .58, color: Colors.white),
  );
}
