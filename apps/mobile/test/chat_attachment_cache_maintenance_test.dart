import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_opener.dart';

void main() {
  test('cache maintenance runs on startup and app resume', () async {
    final resumes = StreamController<void>.broadcast(sync: true);
    final maintenance = _RecordingMaintenance();
    final container = ProviderContainer(
      overrides: [
        appLifecycleResumeEventsProvider.overrideWithValue(resumes.stream),
        chatAttachmentCacheMaintenanceFactoryProvider.overrideWithValue(
          () => maintenance,
        ),
      ],
    );
    var containerDisposed = false;
    addTearDown(() async {
      if (!containerDisposed) {
        container.dispose();
      }
      await resumes.close();
    });

    container.read(chatAttachmentCacheMaintenanceProvider);
    await Future<void>.delayed(Duration.zero);
    expect(maintenance.runs, 1);

    resumes.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(maintenance.runs, 2);

    container.dispose();
    containerDisposed = true;
    expect(maintenance.disposed, isTrue);
  });
}

final class _RecordingMaintenance implements ChatAttachmentCacheMaintenance {
  var runs = 0;
  var disposed = false;

  @override
  Future<void> run() async {
    runs++;
  }

  @override
  void dispose() {
    disposed = true;
  }
}
