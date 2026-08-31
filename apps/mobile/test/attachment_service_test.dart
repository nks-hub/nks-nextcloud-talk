import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/attachment_repository.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

part 'attachment_service_lifecycle_test.part.dart';
part 'attachment_service_scheduler_test.part.dart';
part 'attachment_service_recovery_test.part.dart';
part 'attachment_service_test_support.part.dart';
part 'attachment_service_account_suspend_test.part.dart';

void main() {
  _registerAttachmentServiceLifecycleTests();
  _registerAttachmentServiceSchedulerTests();
  _registerAttachmentServiceRecoveryTests();
  _registerAttachmentServiceAccountSuspendTests();
}
