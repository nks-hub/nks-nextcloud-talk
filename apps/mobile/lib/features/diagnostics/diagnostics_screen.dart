import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import 'local_diagnostics.dart';

/// Local state of one account, reachable from Settings.
///
/// Every value comes from a durable store this build actually reads, so a
/// support case can be triaged without a debugger attached. Anything that
/// identifies the account or its content is deliberately absent, which makes
/// the whole screen safe to read out or screenshot.
final class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({required this.accountId, super.key});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final diagnostics = ref.watch(localDiagnosticsProvider(accountId));

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.diagnosticsTitle),
        actions: [
          IconButton(
            key: const Key('diagnostics-refresh'),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: strings.diagnosticsRefresh,
            onPressed: () =>
                ref.invalidate(localDiagnosticsProvider(accountId)),
          ),
        ],
      ),
      body: diagnostics.when(
        data: (data) => _DiagnosticsList(data),
        // Reading a handful of local rows resolves immediately. An
        // indeterminate spinner would animate forever and wedge any
        // pumpAndSettle, so the gap stays quiet instead.
        loading: () => const SizedBox(height: 24),
        error: (error, stackTrace) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            key: const Key('diagnostics-load-failed'),
            strings.diagnosticsLoadFailed,
          ),
        ),
      ),
    );
  }
}

final class _DiagnosticsList extends StatelessWidget {
  const _DiagnosticsList(this.data);

  final LocalDiagnostics data;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return ListView(
      key: const Key('diagnostics-list'),
      children: [
        _SectionHeader(strings.diagnosticsAppSection),
        _Entry(
          entryKey: const Key('diagnostics-app-version'),
          label: strings.diagnosticsAppVersion,
          value: appVersionName,
        ),
        _Entry(
          entryKey: const Key('diagnostics-app-build'),
          label: strings.diagnosticsAppBuild,
          value: appBuildNumber,
        ),
        _Entry(
          entryKey: const Key('diagnostics-platform'),
          label: strings.diagnosticsPlatform,
          value: data.operatingSystem,
        ),
        // The app is GPL-3.0 and ships 171 third-party packages, most of them
        // BSD or MIT, whose terms require their notices to travel with the
        // binary. Flutter collects every bundled licence itself, so the only
        // thing missing was a way to reach the page.
        ListTile(
          key: const Key('diagnostics-licenses'),
          title: Text(strings.diagnosticsLicenses),
          subtitle: Text(strings.diagnosticsLicensesSubtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'NKS Talk',
            applicationVersion: '$appVersionName ($appBuildNumber)',
          ),
        ),
        const Divider(height: 1),
        _SectionHeader(strings.diagnosticsDatabaseSection),
        _Entry(
          entryKey: const Key('diagnostics-schema-version'),
          label: strings.diagnosticsSchemaVersion,
          value: '${data.schemaVersion}',
        ),
        _Entry(
          entryKey: const Key('diagnostics-conversation-rows'),
          label: strings.diagnosticsConversationRows,
          value: '${data.conversationCount}',
        ),
        _Entry(
          entryKey: const Key('diagnostics-message-rows'),
          label: strings.diagnosticsMessageRows,
          value: '${data.messageCount}',
        ),
        _Entry(
          entryKey: const Key('diagnostics-thread-rows'),
          label: strings.diagnosticsThreadRows,
          value: '${data.threadCount}',
        ),
        _Entry(
          entryKey: const Key('diagnostics-text-outbox-rows'),
          label: strings.diagnosticsTextOutboxRows,
          value: '${data.textOutbox.total}',
        ),
        _Entry(
          entryKey: const Key('diagnostics-attachment-outbox-rows'),
          label: strings.diagnosticsAttachmentOutboxRows,
          value: '${data.attachmentOutbox.total}',
        ),
        const Divider(height: 1),
        _SectionHeader(strings.diagnosticsOutboxSection),
        _OutboxEntries(
          prefix: 'text',
          title: strings.diagnosticsOutboxTextTitle,
          outbox: data.textOutbox,
        ),
        _OutboxEntries(
          prefix: 'attachment',
          title: strings.diagnosticsOutboxAttachmentsTitle,
          outbox: data.attachmentOutbox,
        ),
        const Divider(height: 1),
        _SectionHeader(strings.diagnosticsSyncSection),
        _Entry(
          entryKey: const Key('diagnostics-sync-last-success'),
          label: strings.diagnosticsSyncLastSuccess,
          value: _instant(strings, data.lastSyncedAt),
        ),
        _Entry(
          entryKey: const Key('diagnostics-sync-last-error'),
          label: strings.diagnosticsSyncLastError,
          value: data.lastSyncError ?? strings.diagnosticsValueNone,
        ),
        const Divider(height: 1),
        _SectionHeader(strings.diagnosticsPushSection),
        ..._pushEntries(strings, data.push),
        const Divider(height: 1),
        _SectionHeader(strings.diagnosticsCapabilitiesSection),
        _Entry(
          entryKey: const Key('diagnostics-talk-feature-count'),
          label: strings.diagnosticsTalkFeatureCount,
          value: '${data.talkFeatureCount}',
        ),
        for (final entry in data.keyTalkFeatures.entries)
          _Entry(
            entryKey: Key('diagnostics-talk-feature-${entry.key}'),
            label: entry.key,
            value: entry.value
                ? strings.diagnosticsValueYes
                : strings.diagnosticsValueNo,
          ),
      ],
    );
  }
}

List<Widget> _pushEntries(AppLocalizations strings, PushDiagnostics push) {
  switch (push.gap) {
    case PushDiagnosticsGap.platformUnsupported:
      return [
        _Entry(
          entryKey: const Key('diagnostics-push-unavailable'),
          label: strings.diagnosticsPushPhase,
          value: strings.diagnosticsPushPlatformUnsupported,
        ),
      ];
    case PushDiagnosticsGap.readFailed:
      return [
        _Entry(
          entryKey: const Key('diagnostics-push-unavailable'),
          label: strings.diagnosticsPushPhase,
          value: strings.diagnosticsPushReadFailed(
            push.failureCode ?? strings.diagnosticsValueNone,
          ),
        ),
      ];
    case null:
      return [
        _Entry(
          entryKey: const Key('diagnostics-push-phase'),
          label: strings.diagnosticsPushPhase,
          value: push.phase?.name ?? strings.diagnosticsValueNone,
        ),
        _Entry(
          entryKey: const Key('diagnostics-push-generation'),
          label: strings.diagnosticsPushGeneration,
          value: push.generation == null
              ? strings.diagnosticsValueNone
              : '${push.generation}',
        ),
        _Entry(
          entryKey: const Key('diagnostics-push-next-generation'),
          label: strings.diagnosticsPushNextGeneration,
          value: '${push.nextGeneration}',
        ),
        _Entry(
          entryKey: const Key('diagnostics-push-pending-events'),
          label: strings.diagnosticsPushPendingEvents,
          value: '${push.pendingEventCount}',
        ),
      ];
  }
}

final class _OutboxEntries extends StatelessWidget {
  const _OutboxEntries({
    required this.prefix,
    required this.title,
    required this.outbox,
  });

  final String prefix;
  final String title;
  final OutboxDiagnostics outbox;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final errorClass = outbox.lastErrorClass;
    final errorAt = outbox.lastErrorAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SubHeader(title),
        _Entry(
          entryKey: Key('diagnostics-$prefix-outbox-pending'),
          label: strings.diagnosticsOutboxPending,
          value: '${outbox.pending}',
        ),
        _Entry(
          entryKey: Key('diagnostics-$prefix-outbox-failed'),
          label: strings.diagnosticsOutboxFailed,
          value: '${outbox.failed}',
        ),
        _Entry(
          entryKey: Key('diagnostics-$prefix-outbox-last-error'),
          label: strings.diagnosticsOutboxLastError,
          value: errorClass == null
              ? strings.diagnosticsValueNone
              : '$errorClass · ${_instant(strings, errorAt)}',
        ),
      ],
    );
  }
}

/// Timestamps stay in UTC ISO-8601 so a value read out over a support call
/// means the same thing on both ends.
String _instant(AppLocalizations strings, DateTime? value) {
  return value == null
      ? strings.diagnosticsValueNever
      : value.toUtc().toIso8601String();
}

final class _Entry extends StatelessWidget {
  const _Entry({
    required this.entryKey,
    required this.label,
    required this.value,
  });

  final Key entryKey;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: entryKey,
      dense: true,
      title: Text(label),
      subtitle: Text(value),
    );
  }
}

final class _SubHeader extends StatelessWidget {
  const _SubHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

final class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
