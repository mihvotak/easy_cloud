import 'package:flutter/material.dart';

import 'app/easy_cloud_app.dart';
import 'cloud_mail/api/cloud_mail_api.dart';
import 'cloud_mail/transport/authenticated_cloud_transport.dart';
import 'features/auth/application/auth_repository.dart';
import 'features/auth/data/cloud_auth_api.dart';
import 'features/auth/data/session_store.dart';
import 'features/browser/data/cloud_browser_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final authRepository = AuthRepository(
    api: CloudAuthApi(),
    store: SecureSessionStore(),
  );
  final transport = AuthenticatedCloudTransport(authRepository: authRepository);
  runApp(
    EasyCloudApp(
      authRepository: authRepository,
      browserRepository: CloudBrowserRepository(CloudMailApi(transport)),
    ),
  );
}
