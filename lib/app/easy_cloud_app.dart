import 'package:flutter/material.dart';

import '../features/auth/application/auth_repository.dart';
import '../features/auth/presentation/auth_gate.dart';
import '../features/browser/application/browser_repository.dart';
import '../features/download/application/download_repository.dart';
import '../features/offline/application/offline_file_index.dart';
import '../features/search/application/search_repository.dart';

final class EasyCloudApp extends StatelessWidget {
  const EasyCloudApp({
    required this.authRepository,
    required this.browserRepository,
    required this.searchRepository,
    required this.downloadRepository,
    required this.offlineFileIndex,
    super.key,
  });

  final AuthRepository authRepository;
  final BrowserRepository browserRepository;
  final SearchRepository searchRepository;
  final DownloadRepository downloadRepository;
  final OfflineFileIndex offlineFileIndex;

  @override
  Widget build(BuildContext context) {
    const background = Color(0xff0a0e14);
    const surface = Color(0xff111821);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff56d6c9),
      brightness: Brightness.dark,
      surface: surface,
    );

    return MaterialApp(
      title: 'Easy Cloud',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: background,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xff141c26),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xff263241)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 18,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          surfaceTintColor: Colors.transparent,
        ),
        useMaterial3: true,
      ),
      home: AuthGate(
        repository: authRepository,
        browserRepository: browserRepository,
        searchRepository: searchRepository,
        downloadRepository: downloadRepository,
        offlineFileIndex: offlineFileIndex,
      ),
    );
  }
}
