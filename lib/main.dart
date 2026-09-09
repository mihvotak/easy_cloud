import 'package:flutter/material.dart';

import 'app/easy_cloud_app.dart';
import 'features/auth/application/auth_repository.dart';
import 'features/auth/data/cloud_auth_api.dart';
import 'features/auth/data/session_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    EasyCloudApp(
      authRepository: AuthRepository(
        api: CloudAuthApi(),
        store: SecureSessionStore(),
      ),
    ),
  );
}
