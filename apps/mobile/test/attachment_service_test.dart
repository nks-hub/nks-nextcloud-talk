import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/features/chat/attachment_runtime_owner.dart';
import 'package:nextcloudtalk/app_providers.dart'
    show
        accountRemovalServiceProvider,
        appDatabaseProvider,
        appPasswordRevocationQueueProvider,
        attachmentRepositoryProvider,
        attachmentServiceProvider,
        credentialVaultProvider,
        drainForBackground,
        nextcloudApiProvider;
import 'package:nextcloudtalk/core/background_drain.dart'
    show runBackgroundDrainIsolate;
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/core/attachment_upload_telemetry.dart';
import 'package:nextcloudtalk/data/attachment_repository.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
import 'package:nextcloudtalk/features/chat/chat_service.dart';
import 'package:nextcloudtalk/features/settings/app_password_revocation_queue.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart' show HttpNextcloudApi;
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

part 'attachment_service_lifecycle_test.part.dart';
part 'attachment_service_scheduler_test.part.dart';
part 'attachment_service_parallel_test.part.dart';
part 'attachment_service_reconciliation_test.part.dart';
part 'attachment_service_recovery_test.part.dart';
part 'attachment_service_retry_resume_test.part.dart';
part 'attachment_service_ownership_test.part.dart';
part 'attachment_service_test_support.part.dart';
part 'attachment_service_account_suspend_test.part.dart';
part 'attachment_service_deferred_confirmation_test.part.dart';

void main() {
  _registerAttachmentServiceLifecycleTests();
  _registerAttachmentServiceSchedulerTests();
  _registerAttachmentServiceParallelTests();
  _registerAttachmentServiceReconciliationTests();
  _registerAttachmentServiceRecoveryTests();
  _registerAttachmentServiceRetryResumeTests();
  _registerAttachmentOwnershipTests();
  _registerAttachmentServiceAccountSuspendTests();
  _registerDeferredConfirmationTests();
}
