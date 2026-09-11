import 'package:flutter/material.dart';

import 'app/easy_cloud_app.dart';
import 'cloud_mail/api/cloud_mail_api.dart';
import 'cloud_mail/transport/authenticated_cloud_transport.dart';
import 'cloud_mail/transport/cloud_download_transport.dart';
import 'features/auth/application/auth_repository.dart';
import 'features/auth/data/cloud_auth_api.dart';
import 'features/auth/data/session_store.dart';
import 'features/browser/data/cloud_browser_repository.dart';
import 'features/browser/data/cached_browser_repository.dart';
import 'features/download/data/cloud_download_repository.dart';
import 'features/offline/data/sqlite_offline_file_index.dart';
import 'features/open/data/method_channel_file_opener.dart';
import 'features/search/data/cloud_search_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final authRepository = AuthRepository(
    api: CloudAuthApi(),
    store: SecureSessionStore(),
  );
  final transport = AuthenticatedCloudTransport(authRepository: authRepository);
  final cloudApi = CloudMailApi(transport);
  final offlineFileIndex = SqliteOfflineFileIndex();
  final fileGateway = MethodChannelFileOpener();
  runApp(
    EasyCloudApp(
      authRepository: authRepository,
      browserRepository: CachedBrowserRepository(
        remote: CloudBrowserRepository(cloudApi),
        cache: offlineFileIndex,
        authRepository: authRepository,
      ),
      searchRepository: CloudSearchRepository(cloudApi),
      downloadRepository: CloudDownloadRepository(
        api: cloudApi,
        transport: CloudDownloadTransport(authRepository: authRepository),
        authRepository: authRepository,
        offlineFileIndex: offlineFileIndex,
      ),
      offlineFileIndex: offlineFileIndex,
      offlineTargetIndex: offlineFileIndex,
      offlineTargetQueueStore: offlineFileIndex,
      fileOpener: fileGateway,
      fileExporter: fileGateway,
    ),
  );
}
