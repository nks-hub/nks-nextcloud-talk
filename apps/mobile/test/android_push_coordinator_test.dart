import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/features/push/android_push_coordinator.dart';
import 'package:nextcloudtalk/features/push/android_web_push_bridge.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

part 'android_push_coordinator_actions_test.part.dart';
part 'android_push_coordinator_multi_server_test.part.dart';
part 'android_push_coordinator_registration_test.part.dart';
part 'android_push_coordinator_reconciliation_test.part.dart';
part 'android_push_coordinator_retry_routing_test.part.dart';
part 'android_push_coordinator_test_support.part.dart';
part 'android_push_coordinator_transport_test.part.dart';

void main() {
  _registerAndroidPushRegistrationTests();
  _registerAndroidPushReconciliationTests();
  _registerAndroidPushRetryRoutingTests();
  _registerAndroidPushActionTests();
  _registerAndroidPushMultiServerTests();
  _registerAndroidPushTransportHandoverTests();
}
