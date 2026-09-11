import 'package:flutter/services.dart';

import '../application/file_opener.dart';
import '../domain/open_file_failure.dart';

/// Shared platform gateway for opening and exporting verified CAS objects.
/// Keeping both operations on one channel avoids creating duplicate native
/// channel instances in the production composition.
final class MethodChannelFileOpener implements FileOpener, FileExporter {
  const MethodChannelFileOpener({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'easy_cloud/file_opener';
  static const methodName = 'openFile';
  static const saveFileAsMethodName = 'saveFileAs';

  final MethodChannel _channel;

  @override
  Future<void> openFile(String absolutePath, String displayName) async {
    try {
      await _channel.invokeMethod<void>(methodName, <String, Object?>{
        'path': absolutePath,
        'displayName': displayName,
      });
    } on PlatformException catch (error) {
      throw OpenFileFailure(_typeForCode(error.code));
    } on MissingPluginException {
      throw const OpenFileFailure(OpenFileFailureType.platform);
    }
  }

  @override
  Future<bool> saveFileAs(String absolutePath, String displayName) async {
    try {
      final value = await _channel.invokeMethod<Object?>(
        saveFileAsMethodName,
        <String, Object?>{'path': absolutePath, 'displayName': displayName},
      );
      if (value is bool) return value;
      throw const OpenFileFailure(OpenFileFailureType.saveAs);
    } on PlatformException catch (error) {
      throw OpenFileFailure(_typeForCode(error.code, exporting: true));
    } on MissingPluginException {
      throw const OpenFileFailure(OpenFileFailureType.saveAs);
    }
  }

  static OpenFileFailureType _typeForCode(
    String code, {
    bool exporting = false,
  }) => switch (code.trim().toUpperCase()) {
    'NO_HANDLER' => OpenFileFailureType.noHandler,
    'BUSY' => OpenFileFailureType.busy,
    'INVALID_ARGUMENT' ||
    'INVALID_PATH' ||
    'INVALID_DISPLAY_NAME' => OpenFileFailureType.invalidRequest,
    'EXPORT_FAILED' || 'ACTIVITY_DESTROYED' => OpenFileFailureType.saveAs,
    _ => exporting ? OpenFileFailureType.saveAs : OpenFileFailureType.platform,
  };
}
