import 'package:easy_cloud/features/open/data/method_channel_file_opener.dart';
import 'package:easy_cloud/features/open/domain/open_file_failure.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(MethodChannelFileOpener.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sends only the CAS path and original display name', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return null;
        });

    await MethodChannelFileOpener(channel: channel).openFile(
      '/data/user/0/app/files/cloud_cache/account/objects/AA/BB/AABB',
      'photo.jpg',
    );

    expect(received?.method, MethodChannelFileOpener.methodName);
    expect(received?.arguments, {
      'path': '/data/user/0/app/files/cloud_cache/account/objects/AA/BB/AABB',
      'displayName': 'photo.jpg',
    });
  });

  test('maps platform failures to a safe typed failure', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'NO_HANDLER',
            message: 'private local path must not escape',
          );
        });

    await expectLater(
      MethodChannelFileOpener(channel: channel).openFile('/private', 'x.txt'),
      throwsA(
        isA<OpenFileFailure>()
            .having(
              (failure) => failure.type,
              'type',
              OpenFileFailureType.noHandler,
            )
            .having(
              (failure) => failure.message,
              'message',
              OpenFileFailure.safeMessage,
            ),
      ),
    );
  });

  test('sends save-as arguments and returns a selected result', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return true;
        });

    final selected = await MethodChannelFileOpener(channel: channel).saveFileAs(
      '/data/user/0/app/files/cloud_cache/account/objects/AA/BB/AABB',
      'photo.jpg',
    );

    expect(selected, isTrue);
    expect(received?.method, MethodChannelFileOpener.saveFileAsMethodName);
    expect(received?.arguments, {
      'path': '/data/user/0/app/files/cloud_cache/account/objects/AA/BB/AABB',
      'displayName': 'photo.jpg',
    });
  });

  test('maps picker cancellation to false without an error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => false);

    await expectLater(
      MethodChannelFileOpener(channel: channel).saveFileAs('/private', 'x.txt'),
      completion(isFalse),
    );
  });

  test('maps export errors to a safe typed failure', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'EXPORT_FAILED',
            message: '/private/path must not escape',
          );
        });

    await expectLater(
      MethodChannelFileOpener(channel: channel).saveFileAs('/private', 'x.txt'),
      throwsA(
        isA<OpenFileFailure>()
            .having(
              (failure) => failure.type,
              'type',
              OpenFileFailureType.saveAs,
            )
            .having(
              (failure) => failure.message,
              'message',
              OpenFileFailure.safeSaveAsMessage,
            )
            .having(
              (failure) => failure.toString(),
              'safe string',
              isNot(contains('/private/path')),
            ),
      ),
    );
  });
}
