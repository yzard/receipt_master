import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const credentialStore = FlutterSecureStorage(
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
    synchronizable: false,
  ),
);
