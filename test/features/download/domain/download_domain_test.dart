import 'package:easy_cloud/features/download/domain/download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('progress carries cumulative bytes, total, and resume state', () {
    const progress = DownloadProgress(bytes: 12, total: 20, resumed: true);

    expect(progress.bytes, 12);
    expect(progress.total, 20);
    expect(progress.resumed, isTrue);
  });

  test('cancellation is idempotent and typed', () async {
    final token = DownloadCancellationToken();

    token.cancel();
    token.cancel();

    expect(token.isCancelled, isTrue);
    expect(token.throwIfCancelled, throwsA(isA<DownloadCancelled>()));
    await token.close();
  });
}
