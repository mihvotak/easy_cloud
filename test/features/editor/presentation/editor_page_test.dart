import 'dart:io';

import 'package:easy_cloud/cloud_mail/probe/cloud_hash.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/editor/application/editor_save_repository.dart';
import 'package:easy_cloud/features/editor/presentation/editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('loads text, marks it dirty, and guards unsaved back', (
    tester,
  ) async {
    final service = _FakeEditorSaveService();
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    expect(find.text('note.txt'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'changed\r\ntext');
    await tester.pump();
    expect(find.text('●'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNotNull);

    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(find.text('Не сохранять'), findsOneWidget);
    expect(find.text('Остаться'), findsOneWidget);
    await tester.tap(find.text('Остаться'));
    await tester.pumpAndSettle();
    expect(find.text('note.txt'), findsOneWidget);
  });

  testWidgets('saves unchanged content and updates the baseline', (
    tester,
  ) async {
    final service = _FakeEditorSaveService();
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'changed');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);
    await tester.tap(_saveButtonFinder);
    await tester.pumpAndSettle();

    expect(service.choices, [EditorSaveChoice.unchanged]);
    expect(_saveButton(tester).onPressed, isNull);
    expect(find.text('●'), findsNothing);
  });

  testWidgets('offers overwrite, copy, and cancel for typed conflicts', (
    tester,
  ) async {
    final service = _FakeEditorSaveService(conflictFirst: true);
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'changed');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);
    await tester.tap(_saveButtonFinder);
    await tester.pumpAndSettle();

    expect(find.text('Поверх'), findsOneWidget);
    expect(find.text('Копия'), findsOneWidget);
    expect(find.text('Отмена'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(service.choices, [EditorSaveChoice.unchanged]);
    expect(find.text('●'), findsOneWidget);

    await tester.tap(_saveButtonFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Поверх'));
    await tester.pumpAndSettle();
    expect(service.choices, [
      EditorSaveChoice.unchanged,
      EditorSaveChoice.unchanged,
      EditorSaveChoice.overwrite,
    ]);
    expect(find.text('●'), findsNothing);
  });

  testWidgets('copy changes the title to the returned adjacent path', (
    tester,
  ) async {
    final service = _FakeEditorSaveService(conflictFirst: true);
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'changed');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);
    await tester.tap(_saveButtonFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Копия'));
    await tester.pumpAndSettle();

    expect(service.choices, [
      EditorSaveChoice.unchanged,
      EditorSaveChoice.copy,
    ]);
    expect(find.text('note (1).txt'), findsOneWidget);
    expect(find.text('●'), findsNothing);
  });

  testWidgets('keeps dirty state when remote outcome is unknown', (
    tester,
  ) async {
    final service = _FakeEditorSaveService(remoteUnknown: true);
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'changed');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);
    await tester.tap(_saveButtonFinder);
    await tester.pumpAndSettle();

    expect(find.text('●'), findsOneWidget);
    expect(
      find.textContaining('Результат сохранения не удалось подтвердить'),
      findsOneWidget,
    );
  });
}

final Finder _saveButtonFinder = find.byIcon(Icons.save_rounded);

IconButton _saveButton(WidgetTester tester) => tester.widget<IconButton>(
  find.ancestor(of: _saveButtonFinder, matching: find.byType(IconButton)),
);

Widget _app(EditorSaveService service) =>
    MaterialApp(home: _EditorHost(service));

final class _EditorHost extends StatefulWidget {
  const _EditorHost(this.service);

  final EditorSaveService service;

  @override
  State<_EditorHost> createState() => _EditorHostState();
}

final class _EditorHostState extends State<_EditorHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => EditorPage(
            preparedFile: _prepared('/docs/note.txt', 'original'),
            editorSaveService: widget.service,
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

PreparedEditorFile _prepared(String path, String text) {
  final bytes = encodeEditorUtf8(text, hasUtf8Bom: false);
  final node = CloudNode(
    path: path,
    name: path.substring(path.lastIndexOf('/') + 1),
    type: CloudNodeType.file,
    hash: calculateCloudHash(bytes),
    size: bytes.length,
  );
  return PreparedEditorFile(
    file: File('/verified/object'),
    remoteNode: node,
    text: text,
    hasUtf8Bom: false,
    baseline: EditorSaveBaseline(
      path: path,
      hash: node.hash!,
      size: bytes.length,
    ),
    bytes: bytes,
  );
}

final class _FakeEditorSaveService implements EditorSaveService {
  _FakeEditorSaveService({
    this.conflictFirst = false,
    this.remoteUnknown = false,
  });

  final bool conflictFirst;
  final bool remoteUnknown;
  final choices = <EditorSaveChoice>[];

  @override
  Future<EditorConflictCheckResult> checkConflict(
    EditorSaveBaseline baseline, {
    EditorSaveCancellation? cancellation,
  }) async => EditorConflictCheckResult.unchanged(
    EditorRemoteMetadata(
      path: baseline.path,
      type: EditorRemoteNodeType.file,
      hash: baseline.hash,
      size: baseline.size,
    ),
  );

  @override
  Future<EditorSaveResult> save(
    EditorSaveBaseline baseline,
    List<int> bytes, {
    EditorSaveChoice choice = EditorSaveChoice.unchanged,
    EditorSaveCancellation? cancellation,
    void Function(EditorSaveProgress progress)? onProgress,
  }) async {
    choices.add(choice);
    onProgress?.call(
      const EditorSaveProgress(
        phase: EditorSavePhase.uploading,
        bytes: 1,
        total: 1,
      ),
    );
    if (conflictFirst && choice == EditorSaveChoice.unchanged) {
      throw const EditorSaveFailure(EditorSaveFailureType.conflict, 'conflict');
    }
    if (remoteUnknown) {
      throw const EditorSaveFailure(
        EditorSaveFailureType.remoteOutcomeUnknown,
        'unknown',
        mayHaveSaved: true,
      );
    }
    final path = choice == EditorSaveChoice.copy
        ? '/docs/note (1).txt'
        : baseline.path;
    final hash = calculateCloudHash(bytes);
    return EditorSaveResult(
      remoteNode: EditorRemoteMetadata(
        path: path,
        type: EditorRemoteNodeType.file,
        hash: hash,
        size: bytes.length,
        name: path.substring(path.lastIndexOf('/') + 1),
      ),
      choice: choice,
      ownershipPolicy: EditorOwnershipPolicy.onlineOnly,
    );
  }

  @override
  Future<EditorSaveResult> saveRequest(
    EditorSaveRequest request, {
    EditorSaveCancellation? cancellation,
    void Function(EditorSaveProgress progress)? onProgress,
  }) => save(
    request.baseline,
    request.bytes,
    choice: request.choice,
    cancellation: cancellation,
    onProgress: onProgress,
  );

  @override
  Future<void> close() async {}
}
