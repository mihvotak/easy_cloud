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

  testWidgets('keeps save disabled until the exact encoding settles', (
    tester,
  ) async {
    final service = _FakeEditorSaveService();
    await tester.pumpWidget(
      _app(service, debounce: const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'changed');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNull);
    expect(find.text('●'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    expect(_saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('guards back immediately while exact encoding is pending', (
    tester,
  ) async {
    final service = _FakeEditorSaveService();
    await tester.pumpWidget(
      _app(service, debounce: const Duration(seconds: 1)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'changed');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNull);

    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(find.text('Не сохранять'), findsOneWidget);
    expect(find.text('Остаться'), findsOneWidget);
  });

  testWidgets('clears dirty state when text is reverted after settling', (
    tester,
  ) async {
    final service = _FakeEditorSaveService();
    await tester.pumpWidget(
      _app(service, debounce: const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'changed');
    await tester.pump();
    expect(find.text('●'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'original');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNull);

    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('●'), findsNothing);
    expect(_saveButton(tester).onPressed, isNull);
  });

  testWidgets('uses one final debounced value after rapid edits', (
    tester,
  ) async {
    final service = _FakeEditorSaveService();
    var encodeCount = 0;
    await tester.pumpWidget(
      _app(
        service,
        debounce: const Duration(seconds: 1),
        exactEncoder: (text, {required hasUtf8Bom}) {
          encodeCount++;
          return encodeEditorUtf8(text, hasUtf8Bom: hasUtf8Bom);
        },
      ),
    );
    await tester.pumpAndSettle();

    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    controller.text = 'first';
    await tester.pump(const Duration(milliseconds: 10));
    controller.text = 'second';
    await tester.pump(const Duration(milliseconds: 10));
    expect(_saveButton(tester).onPressed, isNull);

    await tester.pump(const Duration(seconds: 1));
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(encodeCount, 1);
    await tester.tap(_saveButtonFinder);
    await tester.pumpAndSettle();

    expect(service.savedBytes, hasLength(1));
    expect(
      service.savedBytes.single,
      encodeEditorUtf8('second', hasUtf8Bom: false),
    );
    expect(encodeCount, 2);
  });

  testWidgets('updates exact oversize state including the original BOM', (
    tester,
  ) async {
    final service = _FakeEditorSaveService();
    var sawBom = false;
    await tester.pumpWidget(
      _app(
        service,
        debounce: const Duration(milliseconds: 100),
        hasUtf8Bom: true,
        exactEncoder: (text, {required hasUtf8Bom}) {
          sawBom = hasUtf8Bom;
          if (text == 'oversize') {
            return List<int>.filled(editorMaxBytes + 1, 0x61, growable: false);
          }
          return encodeEditorUtf8(text, hasUtf8Bom: hasUtf8Bom);
        },
      ),
    );
    await tester.pumpAndSettle();

    tester.widget<TextField>(find.byType(TextField)).controller!.text =
        'oversize';
    await tester.pump();
    expect(find.textContaining('Размер текста:'), findsNothing);
    expect(_saveButton(tester).onPressed, isNull);

    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Размер текста: 10485761 байт'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);
    expect(sawBom, isTrue);
  });

  testWidgets('large listener work waits for the debounce', (tester) async {
    final service = _FakeEditorSaveService();
    var encodeCount = 0;
    await tester.pumpWidget(
      _app(
        service,
        debounce: const Duration(seconds: 1),
        exactEncoder: (text, {required hasUtf8Bom}) {
          encodeCount++;
          return encodeEditorUtf8(text, hasUtf8Bom: hasUtf8Bom);
        },
      ),
    );
    await tester.pumpAndSettle();

    final largeText = String.fromCharCodes(
      List<int>.filled(64 * 1024, 0x61, growable: false),
    );
    tester.widget<TextField>(find.byType(TextField)).controller!.text =
        largeText;
    await tester.pump();

    expect(find.textContaining('Размер текста:'), findsNothing);
    expect(_saveButton(tester).onPressed, isNull);
    expect(encodeCount, 0);

    await tester.pump(const Duration(seconds: 1));
    expect(encodeCount, 1);
  });

  testWidgets('dispose cancels pending exact encoding', (tester) async {
    final service = _FakeEditorSaveService();
    await tester.pumpWidget(
      _app(service, debounce: const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'changed');
    await tester.pump();
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Не сохранять'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(EditorPage), findsNothing);
  });

  testWidgets('direct save encodes current text before uploading', (
    tester,
  ) async {
    final service = _FakeEditorSaveService();
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'first');
    await tester.pump();
    final save = _saveButton(tester).onPressed;
    expect(save, isNotNull);

    tester.widget<TextField>(find.byType(TextField)).controller!.text =
        'second';
    save!();
    await tester.pumpAndSettle();

    expect(
      service.savedBytes.single,
      encodeEditorUtf8('second', hasUtf8Bom: false),
    );
  });

  testWidgets('conflict retry uploads the frozen attempt bytes', (
    tester,
  ) async {
    final service = _FakeEditorSaveService(conflictFirst: true);
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'changed');
    await tester.pump();
    await tester.tap(_saveButtonFinder);
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    await tester.tap(find.text('Поверх'));
    await tester.pumpAndSettle();

    expect(service.savedBytes, hasLength(2));
    expect(
      service.savedBytes[0],
      encodeEditorUtf8('changed', hasUtf8Bom: false),
    );
    expect(service.savedBytes[1], service.savedBytes[0]);
  });

  testWidgets('conflict retry re-encodes if text changed during the dialog', (
    tester,
  ) async {
    final service = _FakeEditorSaveService(conflictFirst: true);
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'changed');
    await tester.pump();
    await tester.tap(_saveButtonFinder);
    await tester.pumpAndSettle();

    tester.widget<TextField>(find.byType(TextField)).controller!.text =
        'edited during dialog';
    await tester.tap(find.text('Поверх'));
    await tester.pumpAndSettle();

    expect(
      service.savedBytes[1],
      encodeEditorUtf8('edited during dialog', hasUtf8Bom: false),
    );
  });
}

final Finder _saveButtonFinder = find.byIcon(Icons.save_rounded);

IconButton _saveButton(WidgetTester tester) => tester.widget<IconButton>(
  find.ancestor(of: _saveButtonFinder, matching: find.byType(IconButton)),
);

Widget _app(
  EditorSaveService service, {
  Duration debounce = Duration.zero,
  bool hasUtf8Bom = false,
  EditorExactEncoder? exactEncoder,
}) =>
    MaterialApp(home: _EditorHost(service, debounce, hasUtf8Bom, exactEncoder));

final class _EditorHost extends StatefulWidget {
  const _EditorHost(
    this.service,
    this.debounce,
    this.hasUtf8Bom,
    this.exactEncoder,
  );

  final EditorSaveService service;
  final Duration debounce;
  final bool hasUtf8Bom;
  final EditorExactEncoder? exactEncoder;

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
            preparedFile: _prepared(
              '/docs/note.txt',
              'original',
              hasUtf8Bom: widget.hasUtf8Bom,
            ),
            editorSaveService: widget.service,
            exactEncodingDebounce: widget.debounce,
            exactEncoder: widget.exactEncoder,
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

PreparedEditorFile _prepared(
  String path,
  String text, {
  bool hasUtf8Bom = false,
}) {
  final bytes = encodeEditorUtf8(text, hasUtf8Bom: hasUtf8Bom);
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
    hasUtf8Bom: hasUtf8Bom,
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
  final savedBytes = <List<int>>[];

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
    savedBytes.add(List<int>.from(bytes));
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
