import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/browser/presentation/cloud_node_widgets.dart';
import 'package:easy_cloud/features/offline/domain/offline_target.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders each offline availability state with its tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              _tile('/online.txt', OfflineAvailability.onlineOnly),
              _tile('/direct.txt', OfflineAvailability.directReady),
              _tile('/inherited.txt', OfflineAvailability.inheritedReady),
            ],
          ),
        ),
      ),
    );

    expect(find.byTooltip('Только онлайн'), findsOneWidget);
    expect(find.byTooltip('Доступен офлайн'), findsOneWidget);
    expect(find.byTooltip('Доступен офлайн через папку'), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
    expect(
      find.bySemanticsLabel('Офлайн-доступ: Только онлайн'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Офлайн-доступ: Доступен офлайн'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Офлайн-доступ: Доступен офлайн через папку'),
      findsOneWidget,
    );
  });

  testWidgets('renders determinate, indeterminate, or no transfer progress', (
    tester,
  ) async {
    Future<void> pumpTile({double? progress, bool indeterminate = false}) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CloudNodeTile(
              node: const CloudNode(
                path: '/report.pdf',
                name: 'report.pdf',
                type: CloudNodeType.file,
              ),
              onTap: () {},
              onInfo: () {},
              progress: progress,
              progressIndeterminate: indeterminate,
            ),
          ),
        ),
      );
    }

    await pumpTile(progress: .25);
    var indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, .25);
    expect(tester.getSize(find.byType(LinearProgressIndicator)).height, 2);
    final cardHeightWithProgress = tester.getSize(find.byType(Card)).height;

    await pumpTile(indeterminate: true);
    indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, isNull);

    await pumpTile();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.getSize(find.byType(Card)).height, cardHeightWithProgress);
  });

  testWidgets('animates active recursive readiness until it becomes ready', (
    tester,
  ) async {
    const node = CloudNode(
      path: '/Documents',
      name: 'Documents',
      type: CloudNodeType.folder,
    );
    const activeReadiness = [
      OfflineReadiness.queued,
      OfflineReadiness.downloading,
      OfflineReadiness.verifying,
    ];

    for (final readiness in activeReadiness) {
      await _pumpTile(
        tester,
        node: node,
        availability: OfflineAvailability.onlineOnly,
        policy: OfflinePolicy.direct,
        readiness: readiness,
        settle: false,
      );

      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.value, isNull);
      expect(find.byTooltip('Офлайн-доступ: загрузка…'), findsOneWidget);
      expect(find.bySemanticsLabel('Офлайн-доступ: загрузка…'), findsOneWidget);

      // An indeterminate indicator must keep advancing while the target is
      // active, rather than being a static replacement for the marker.
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    }

    await _pumpTile(
      tester,
      node: node,
      availability: OfflineAvailability.onlineOnly,
      policy: OfflinePolicy.direct,
      readiness: OfflineReadiness.ready,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byTooltip('Доступен офлайн'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Офлайн-доступ: Доступен офлайн'),
      findsOneWidget,
    );
  });

  testWidgets('builds the exact file menu for each availability state', (
    tester,
  ) async {
    const node = CloudNode(
      path: '/report.pdf',
      name: 'report.pdf',
      type: CloudNodeType.file,
    );

    await _pumpTile(
      tester,
      node: node,
      availability: OfflineAvailability.onlineOnly,
      onWorkOffline: () {},
    );
    await _openMenu(tester, node);
    expect(find.text('Инфо'), findsOneWidget);
    expect(find.text('Работать оффлайн'), findsOneWidget);
    expect(find.text('Только онлайн'), findsNothing);
    expect(find.text('Сохранить как'), findsOneWidget);
    expect(_menuItem(tester, 'Инфо').enabled, isTrue);
    expect(_menuItem(tester, 'Работать оффлайн').enabled, isTrue);
    expect(_menuItem(tester, 'Сохранить как').enabled, isFalse);
    await _dismissMenu(tester);

    await _pumpTile(
      tester,
      node: node,
      availability: OfflineAvailability.directReady,
      onOnlyOnline: () {},
    );
    await _openMenu(tester, node);
    expect(find.text('Инфо'), findsOneWidget);
    expect(find.text('Работать оффлайн'), findsNothing);
    expect(find.text('Только онлайн'), findsOneWidget);
    expect(find.text('Сохранить как'), findsOneWidget);
    expect(_menuItem(tester, 'Только онлайн').enabled, isTrue);
    expect(_menuItem(tester, 'Сохранить как').enabled, isFalse);
    await _dismissMenu(tester);

    await _pumpTile(
      tester,
      node: node,
      availability: OfflineAvailability.inheritedReady,
      onOnlyOnline: () {},
    );
    await _openMenu(tester, node);
    expect(find.text('Инфо'), findsOneWidget);
    expect(find.text('Работать оффлайн'), findsNothing);
    expect(find.text('Только онлайн'), findsOneWidget);
    expect(find.text('Сохранить как'), findsOneWidget);
    expect(_menuItem(tester, 'Только онлайн').enabled, isFalse);
    expect(_menuItem(tester, 'Сохранить как').enabled, isFalse);
    await _dismissMenu(tester);
  });

  testWidgets('disables unavailable actions and omits save as for folders', (
    tester,
  ) async {
    const node = CloudNode(
      path: '/Documents',
      name: 'Documents',
      type: CloudNodeType.folder,
    );

    await _pumpTile(
      tester,
      node: node,
      availability: OfflineAvailability.onlineOnly,
    );
    await _openMenu(tester, node);
    expect(find.text('Инфо'), findsOneWidget);
    expect(find.text('Работать оффлайн'), findsOneWidget);
    expect(find.text('Только онлайн'), findsNothing);
    expect(find.text('Сохранить как'), findsNothing);
    expect(_menuItem(tester, 'Инфо').enabled, isTrue);
    expect(_menuItem(tester, 'Работать оффлайн').enabled, isFalse);
    await _dismissMenu(tester);

    await _pumpTile(
      tester,
      node: node,
      availability: OfflineAvailability.inheritedReady,
    );
    await _openMenu(tester, node);
    expect(find.text('Только онлайн'), findsOneWidget);
    expect(_menuItem(tester, 'Только онлайн').enabled, isFalse);
    expect(find.text('Сохранить как'), findsNothing);
    await _dismissMenu(tester);
  });

  testWidgets('menu tap invokes only the action and keeps the row inactive', (
    tester,
  ) async {
    var rowTaps = 0;
    var infoCalls = 0;
    const node = CloudNode(
      path: '/report.pdf',
      name: 'report.pdf',
      type: CloudNodeType.file,
    );
    await _pumpTile(
      tester,
      node: node,
      availability: OfflineAvailability.onlineOnly,
      onInfo: () => infoCalls++,
      onWorkOffline: () {},
      onSaveAs: () {},
      onTap: () => rowTaps++,
    );

    final menuButton = find.byTooltip('Действия для report.pdf');
    expect(tester.getSize(menuButton), const Size(48, 48));
    await tester.tap(menuButton);
    await tester.pumpAndSettle();
    expect(rowTaps, 0);
    await tester.tap(find.text('Инфо'));
    await tester.pumpAndSettle();

    expect(infoCalls, 1);
    expect(rowTaps, 0);
  });

  testWidgets('keeps policy actions separate from transfer readiness', (
    tester,
  ) async {
    const node = CloudNode(
      path: '/report.pdf',
      name: 'report.pdf',
      type: CloudNodeType.file,
    );

    await _pumpTile(
      tester,
      node: node,
      availability: OfflineAvailability.onlineOnly,
      policy: OfflinePolicy.direct,
      readiness: OfflineReadiness.downloading,
      onOnlyOnline: () {},
      settle: false,
    );
    expect(find.byTooltip('Офлайн-доступ: загрузка…'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Офлайн-доступ: Офлайн-доступ: загрузка…'),
      findsNothing,
    );
    expect(find.bySemanticsLabel('Офлайн-доступ: загрузка…'), findsOneWidget);

    await _openMenu(tester, node, settle: false);
    expect(_menuItem(tester, 'Только онлайн').enabled, isTrue);
    await _dismissMenu(tester, settle: false);

    await _pumpTile(
      tester,
      node: node,
      availability: OfflineAvailability.onlineOnly,
      policy: OfflinePolicy.inherited,
      readiness: OfflineReadiness.error,
      onOnlyOnline: () {},
    );
    expect(find.byTooltip('Офлайн-доступ: ошибка'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.check_box_outline_blank_rounded), findsOneWidget);
    await _openMenu(tester, node);
    expect(_menuItem(tester, 'Только онлайн').enabled, isFalse);
  });

  testWidgets('adds external open only for supported text files', (
    tester,
  ) async {
    var externalCalls = 0;
    const textNode = CloudNode(
      path: '/notes/README.MD',
      name: 'README.MD',
      type: CloudNodeType.file,
    );
    await _pumpTile(
      tester,
      node: textNode,
      availability: OfflineAvailability.onlineOnly,
      onOpenExternally: () => externalCalls++,
    );
    await _openMenu(tester, textNode);
    expect(find.text('Открыть вовне'), findsOneWidget);
    await tester.tap(find.text('Открыть вовне'));
    await tester.pumpAndSettle();
    expect(externalCalls, 1);

    const unsupported = CloudNode(
      path: '/notes/README.pdf',
      name: 'README.pdf',
      type: CloudNodeType.file,
    );
    await _pumpTile(
      tester,
      node: unsupported,
      availability: OfflineAvailability.onlineOnly,
      onOpenExternally: () => externalCalls++,
    );
    await _openMenu(tester, unsupported);
    expect(find.text('Открыть вовне'), findsNothing);
  });

  testWidgets(
    'allows direct folder removal but keeps inherited removal disabled',
    (tester) async {
      const node = CloudNode(
        path: '/Documents',
        name: 'Documents',
        type: CloudNodeType.folder,
      );

      await _pumpTile(
        tester,
        node: node,
        availability: OfflineAvailability.onlineOnly,
        policy: OfflinePolicy.direct,
        readiness: OfflineReadiness.queued,
        onOnlyOnline: () {},
        settle: false,
      );
      await _openMenu(tester, node, settle: false);
      expect(find.text('Только онлайн'), findsOneWidget);
      expect(_menuItem(tester, 'Только онлайн').enabled, isTrue);
      await _dismissMenu(tester, settle: false);

      await _pumpTile(
        tester,
        node: node,
        availability: OfflineAvailability.onlineOnly,
        policy: OfflinePolicy.inherited,
        readiness: OfflineReadiness.ready,
        onOnlyOnline: () {},
      );
      await _openMenu(tester, node);
      expect(_menuItem(tester, 'Только онлайн').enabled, isFalse);
    },
  );

  test(
    'requires confirmation at inclusive thresholds and for unknown trees',
    () {
      final below = estimateOfflineFolder(
        const CloudNode(
          path: '/small',
          name: 'small',
          type: CloudNodeType.folder,
          fileCount: offlineTargetFileConfirmationThreshold - 1,
          folderCount: 0,
          size: offlineTargetByteConfirmationThreshold - 1,
        ),
      );
      expect(below.requiresConfirmation, isFalse);
      expect(below.hasUnknown, isFalse);

      final exactFiles = estimateOfflineFolder(
        const CloudNode(
          path: '/files',
          name: 'files',
          type: CloudNodeType.folder,
          fileCount: offlineTargetFileConfirmationThreshold,
          folderCount: 0,
          size: 1,
        ),
      );
      expect(exactFiles.requiresConfirmation, isTrue);

      final exactBytes = estimateOfflineFolder(
        const CloudNode(
          path: '/bytes',
          name: 'bytes',
          type: CloudNodeType.folder,
          fileCount: 1,
          folderCount: 0,
          size: offlineTargetByteConfirmationThreshold,
        ),
      );
      expect(exactBytes.requiresConfirmation, isTrue);

      final unknown = estimateOfflineFolder(
        const CloudNode(
          path: '/nested',
          name: 'nested',
          type: CloudNodeType.folder,
          fileCount: 1,
          folderCount: 1,
          size: 1,
        ),
      );
      expect(unknown.hasUnknown, isTrue);
      expect(unknown.filesAreLowerBound, isTrue);
      expect(unknown.bytes, isNull);
      expect(unknown.dialogLines, contains('Файлов: не менее 1'));
      expect(unknown.dialogLines, contains('Размер неизвестен'));
    },
  );
}

CloudNodeTile _tile(String path, OfflineAvailability availability) =>
    CloudNodeTile(
      node: CloudNode(
        path: path,
        name: path.substring(path.lastIndexOf('/') + 1),
        type: CloudNodeType.file,
      ),
      onTap: () {},
      onInfo: () {},
      offlineAvailability: availability,
    );

Future<void> _pumpTile(
  WidgetTester tester, {
  required CloudNode node,
  required OfflineAvailability availability,
  OfflinePolicy? policy,
  OfflineReadiness? readiness,
  VoidCallback? onInfo,
  VoidCallback? onWorkOffline,
  VoidCallback? onOnlyOnline,
  VoidCallback? onSaveAs,
  VoidCallback? onOpenExternally,
  VoidCallback? onTap,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CloudNodeTile(
          node: node,
          onTap: onTap ?? () {},
          onInfo: onInfo ?? () {},
          onWorkOffline: onWorkOffline,
          onOnlyOnline: onOnlyOnline,
          onSaveAs: onSaveAs,
          onOpenExternally: onOpenExternally,
          offlineAvailability: availability,
          offlinePolicy: policy ?? OfflinePolicy.onlineOnly,
          offlineReadiness: readiness ?? OfflineReadiness.idle,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _openMenu(
  WidgetTester tester,
  CloudNode node, {
  bool settle = true,
}) async {
  await tester.tap(find.byTooltip('Действия для ${node.name}'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

PopupMenuItem<dynamic> _menuItem(WidgetTester tester, String label) =>
    tester.widget<PopupMenuItem<dynamic>>(
      find
          .ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate(
              (widget) => widget is PopupMenuItem<dynamic>,
            ),
          )
          .first,
    );

Future<void> _dismissMenu(WidgetTester tester, {bool settle = true}) async {
  await tester.tapAt(const Offset(1, 1));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
}
