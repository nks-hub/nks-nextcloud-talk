part of 'attachment_service_test.dart';

void _registerAttachmentServiceReconciliationTests() {
  test(
    'batch confirmation releases at most four sources concurrently',
    () async {
      const jobCount = 6;
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final jobIds = <AttachmentJobId>[];
      final confirmations = <AttachmentMessageConfirmation>[];
      for (var index = 0; index < jobCount; index++) {
        final jobId = await fixture.seedAwaitingConfirmation(seed: index);
        jobIds.add(jobId);
        final stored = await fixture.repository.getStoredJob(
          accountId: 'account-a',
          jobId: jobId.value,
        );
        confirmations.add(
          fixture.confirmation(
            jobId,
            messageId: 300 + index,
            referenceId: stored!.referenceId,
          ),
        );
      }
      final gates = <Completer<void>>[];
      var inFlight = 0;
      var peakInFlight = 0;
      final service = fixture.service(
        _unexpectedClient(),
        releaseSource: (_) async {
          final gate = Completer<void>();
          gates.add(gate);
          inFlight++;
          peakInFlight = max(peakInFlight, inFlight);
          await gate.future;
          inFlight--;
        },
        watchConfirmationCandidates: () => const Stream.empty(),
      );

      Future<void> releaseAll() async {
        while (gates.length < jobCount) {
          for (final gate in gates) {
            if (!gate.isCompleted) {
              gate.complete();
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        for (final gate in gates) {
          if (!gate.isCompleted) {
            gate.complete();
          }
        }
      }

      Future<void>? pendingReconciliation;
      var closed = false;
      addTearDown(() async {
        if (pendingReconciliation != null) {
          await releaseAll();
          await pendingReconciliation;
        } else {
          for (final gate in gates) {
            if (!gate.isCompleted) {
              gate.complete();
            }
          }
        }
        if (!closed) {
          await service.close();
        }
      });
      await service.ready;

      final reconciliation = service.reconcileConfirmations(
        accountId: AccountId.parse('account-a'),
        confirmations: confirmations,
      );
      pendingReconciliation = reconciliation;
      for (var turn = 0; turn < 50 && gates.length < 4; turn++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(gates, hasLength(4));
      expect(peakInFlight, 4);

      gates.first.complete();
      for (var turn = 0; turn < 50 && gates.length < 5; turn++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(gates, hasLength(5));
      expect(peakInFlight, 4);

      await releaseAll();
      await reconciliation;
      await service.close();
      closed = true;
      expect(gates, hasLength(jobCount));
      for (final jobId in jobIds) {
        final stored = await fixture.repository.getStoredJob(
          accountId: 'account-a',
          jobId: jobId.value,
        );
        expect(stored?.sourceReleased, isTrue);
      }
    },
  );
}
