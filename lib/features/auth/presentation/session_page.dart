import 'package:flutter/material.dart';

import 'auth_controller.dart';
import 'auth_gate.dart';

final class SessionPage extends StatelessWidget {
  const SessionPage({required this.controller, super.key});

  final AuthController controller;

  @override
  Widget build(BuildContext context) {
    final session = controller.session!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Easy Cloud'),
        actions: [
          IconButton(
            tooltip: 'Обновить сессию',
            onPressed: controller.isSubmitting ? null : controller.refresh,
            icon: const Icon(Icons.sync_rounded),
          ),
          PopupMenuButton<void>(
            tooltip: 'Аккаунт',
            itemBuilder: (context) => [
              PopupMenuItem<void>(
                onTap: controller.logout,
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
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Row(
                  children: [
                    const CloudMark(size: 54),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Облако подключено',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            session.email,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.verified_rounded,
                      color: Color(0xff56d6c9),
                    ),
                  ],
                ),
              ),
              if (controller.errorMessage case final error?) ...[
                const SizedBox(height: 16),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const Spacer(),
              Icon(
                Icons.folder_open_rounded,
                size: 74,
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: .7),
              ),
              const SizedBox(height: 18),
              Text(
                'Файлы появятся здесь',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Подключение готово. Навигация по облаку будет добавлена на следующем этапе.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const Spacer(flex: 2),
              if (controller.isSubmitting)
                const LinearProgressIndicator(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
