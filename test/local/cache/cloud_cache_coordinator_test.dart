import 'package:easy_cloud/features/download/domain/download_cancellation.dart';
import 'package:easy_cloud/features/download/domain/download_failure.dart';
import 'package:easy_cloud/local/cache/cloud_cache_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serializes the same account/hash key in FIFO order', () async {
    final coordinator = CloudCacheCoordinator();
    final firstToken = DownloadCancellationToken();
    final secondToken = DownloadCancellationToken();
    addTearDown(() async {
      await firstToken.close();
      await secondToken.close();
      await coordinator.close();
    });

    final releaseFirst = await coordinator.acquire('account:HASH', firstToken);
    var secondStarted = false;
    final secondRelease = coordinator.acquire('account:HASH', secondToken).then(
      (release) {
        secondStarted = true;
        return release;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(secondStarted, isFalse);

    releaseFirst();
    final releaseSecond = await secondRelease;
    expect(secondStarted, isTrue);
    releaseSecond();
  });

  test(
    'a cancelled waiter cannot let a later writer bypass the owner',
    () async {
      final coordinator = CloudCacheCoordinator();
      final firstToken = DownloadCancellationToken();
      final cancelledToken = DownloadCancellationToken();
      final thirdToken = DownloadCancellationToken();
      addTearDown(() async {
        await firstToken.close();
        await cancelledToken.close();
        await thirdToken.close();
        await coordinator.close();
      });

      final releaseFirst = await coordinator.acquire(
        'account:HASH',
        firstToken,
      );
      final cancelled = coordinator.acquire('account:HASH', cancelledToken);
      cancelledToken.cancel();
      await expectLater(cancelled, throwsA(isA<DownloadCancelled>()));

      var thirdStarted = false;
      final third = coordinator.acquire('account:HASH', thirdToken).then((
        release,
      ) {
        thirdStarted = true;
        return release;
      });
      await Future<void>.delayed(Duration.zero);
      expect(thirdStarted, isFalse);

      releaseFirst();
      final releaseThird = await third;
      expect(thirdStarted, isTrue);
      releaseThird();
    },
  );
}
