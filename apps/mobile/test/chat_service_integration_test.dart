import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

part 'chat_service_integration_support.dart';
part 'chat_service_integration_sync_cases.dart';
part 'chat_service_integration_poll_cases.dart';
part 'chat_service_integration_lifecycle_send_cases.dart';
part 'chat_service_integration_connectivity_cases.dart';
part 'chat_service_integration_offline_outbox_cases.dart';
part 'chat_service_integration_outbox_cases.dart';

void main() {
  final suite = _ChatServiceIntegrationSuite();

  setUp(suite.prepare);
  tearDown(suite.dispose);

  suite.registerSyncCases();
  suite.registerPollCases();
  suite.registerLifecycleSendCases();
  suite.registerConnectivityCases();
  suite.registerOfflineOutboxCases();
  suite.registerOutboxCases();
}
