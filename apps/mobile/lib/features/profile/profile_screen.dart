import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../network/nextcloud_api.dart';
import 'profile_models.dart';

final class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({required this.accountId, super.key});

  final String accountId;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

final class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _messageController = TextEditingController();
  final _iconController = TextEditingController();
  OwnProfileSnapshot? _snapshot;
  OwnProfileError? _error;
  var _loading = true;
  var _submitting = false;
  var _expiry = StatusExpiry.never;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _generation++;
    _messageController.dispose();
    _iconController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await ref
          .read(profileServiceProvider)
          .load(widget.accountId);
      if (!mounted || generation != _generation) {
        return;
      }
      _messageController.text = snapshot.status?.message ?? '';
      _iconController.text = snapshot.status?.icon ?? '';
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } on OwnProfileException catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _error = error.code;
        _loading = false;
      });
    }
  }

  Future<void> _setStatusType(OwnUserStatusType status) async {
    await _submit(
      () => ref
          .read(profileServiceProvider)
          .setStatusType(accountId: widget.accountId, status: status),
    );
  }

  Future<void> _saveMessage() async {
    await _submit(
      () => ref
          .read(profileServiceProvider)
          .setCustomMessage(
            accountId: widget.accountId,
            message: _messageController.text,
            statusIcon: _iconController.text,
            expiry: _expiry,
          ),
      synchronizeFields: true,
    );
  }

  Future<void> _clearMessage() async {
    await _submit(
      () => ref.read(profileServiceProvider).clearMessage(widget.accountId),
      synchronizeFields: true,
    );
  }

  Future<void> _submit(
    Future<OwnUserStatusResponse> Function() action, {
    bool synchronizeFields = false,
  }) async {
    if (_submitting || _snapshot == null) {
      return;
    }
    setState(() => _submitting = true);
    try {
      final status = await action();
      if (!mounted) {
        return;
      }
      if (synchronizeFields) {
        _messageController.text = status.message ?? '';
        _iconController.text = status.icon ?? '';
      }
      setState(() {
        _snapshot = _snapshot!.withStatus(status);
        _submitting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).profileStatusSaved),
        ),
      );
    } on OwnProfileException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorMessage(context, error.code))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(strings.profileTitle)),
      body: SafeArea(
        child: switch ((_loading, _snapshot, _error)) {
          (true, _, _) => const Center(child: CircularProgressIndicator()),
          (false, final snapshot?, _) => _ProfileContent(
            snapshot: snapshot,
            messageController: _messageController,
            iconController: _iconController,
            expiry: _expiry,
            onExpiryChanged: (value) =>
                setState(() => _expiry = value ?? StatusExpiry.never),
            submitting: _submitting,
            onStatusType: _setStatusType,
            onSaveMessage: _saveMessage,
            onClearMessage: _clearMessage,
          ),
          _ => _ProfileFailure(
            message: _errorMessage(context, _error),
            onRetry: _load,
          ),
        },
      ),
    );
  }
}

final class _ProfileContent extends StatelessWidget {
  const _ProfileContent({
    required this.snapshot,
    required this.messageController,
    required this.iconController,
    required this.expiry,
    required this.onExpiryChanged,
    required this.submitting,
    required this.onStatusType,
    required this.onSaveMessage,
    required this.onClearMessage,
  });

  final OwnProfileSnapshot snapshot;
  final TextEditingController messageController;
  final TextEditingController iconController;
  final StatusExpiry expiry;
  final ValueChanged<StatusExpiry?> onExpiryChanged;
  final bool submitting;
  final ValueChanged<OwnUserStatusType> onStatusType;
  final VoidCallback onSaveMessage;
  final VoidCallback onClearMessage;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final profile = snapshot.profile;
    return ListView(
      key: const Key('profile-content'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 28,
                  child: Text(_initials(profile.displayName)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.displayName,
                        key: const Key('profile-display-name'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      _ProfileValue(
                        label: strings.profileUserIdLabel,
                        value: profile.userId,
                      ),
                      if (profile.email != null)
                        _ProfileValue(
                          label: strings.profileEmailLabel,
                          value: profile.email!,
                        ),
                      _ProfileValue(
                        label: strings.profileServerLabel,
                        value: snapshot.serverUrl,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          strings.profileStatusSection,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        if (!snapshot.statusCapability.enabled || snapshot.status == null)
          Text(
            strings.profileStatusUnavailable,
            key: const Key('profile-status-unavailable'),
          )
        else ...[
          Wrap(
            key: const Key('profile-status-types'),
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final status in _visibleStatuses(snapshot.statusCapability))
                ChoiceChip(
                  key: Key('profile-status-${status.name}'),
                  label: Text(_statusLabel(strings, status)),
                  selected: snapshot.status!.status == status,
                  onSelected: submitting ? null : (_) => onStatusType(status),
                ),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('profile-status-icon'),
            controller: iconController,
            enabled: !submitting,
            maxLength: 16,
            decoration: InputDecoration(
              labelText: strings.profileStatusIconLabel,
              helperText: strings.profileStatusIconHelp,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('profile-status-message'),
            controller: messageController,
            enabled: !submitting,
            maxLength: 80,
            decoration: InputDecoration(
              labelText: strings.profileStatusMessageLabel,
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<StatusExpiry>(
            key: const Key('profile-status-expiry'),
            initialValue: expiry,
            decoration: InputDecoration(
              labelText: strings.profileStatusExpiryLabel,
            ),
            onChanged: submitting ? null : onExpiryChanged,
            items: [
              for (final value in StatusExpiry.values)
                DropdownMenuItem<StatusExpiry>(
                  value: value,
                  child: Text(_expiryLabel(strings, value)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('profile-status-save'),
                onPressed: submitting ? null : onSaveMessage,
                icon: const Icon(Icons.save_outlined),
                label: Text(strings.profileStatusSave),
              ),
              OutlinedButton.icon(
                key: const Key('profile-status-clear'),
                onPressed: submitting ? null : onClearMessage,
                icon: const Icon(Icons.clear_rounded),
                label: Text(strings.profileStatusClear),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

final class _ProfileValue extends StatelessWidget {
  const _ProfileValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text('$label: $value'),
    );
  }
}

final class _ProfileFailure extends StatelessWidget {
  const _ProfileFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_off_outlined, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('profile-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(strings.retry),
            ),
          ],
        ),
      ),
    );
  }
}

List<OwnUserStatusType> _visibleStatuses(ProfileStatusCapability capability) {
  return [
    OwnUserStatusType.online,
    OwnUserStatusType.away,
    if (capability.supportsBusy) OwnUserStatusType.busy,
    OwnUserStatusType.dnd,
    OwnUserStatusType.invisible,
  ];
}

String _statusLabel(AppLocalizations strings, OwnUserStatusType status) {
  return switch (status) {
    OwnUserStatusType.online => strings.profileStatusOnline,
    OwnUserStatusType.away => strings.profileStatusAway,
    OwnUserStatusType.busy => strings.profileStatusBusy,
    OwnUserStatusType.dnd => strings.profileStatusDoNotDisturb,
    OwnUserStatusType.invisible => strings.profileStatusInvisible,
    OwnUserStatusType.offline => strings.profileStatusOffline,
  };
}

String _errorMessage(BuildContext context, OwnProfileError? error) {
  final strings = AppLocalizations.of(context);
  return switch (error) {
    OwnProfileError.accountMissing => strings.profileErrorAccountMissing,
    OwnProfileError.credentialMissing ||
    OwnProfileError.reauthenticationRequired => strings.profileErrorReauth,
    OwnProfileError.unsupported => strings.profileStatusUnavailable,
    OwnProfileError.forbidden => strings.profileErrorForbidden,
    OwnProfileError.rateLimited => strings.profileErrorRateLimited,
    OwnProfileError.serviceUnavailable => strings.profileErrorUnavailable,
    OwnProfileError.network => strings.profileErrorNetwork,
    OwnProfileError.invalidInput => strings.profileErrorInvalidInput,
    OwnProfileError.invalidResponse ||
    null => strings.profileErrorInvalidResponse,
  };
}

String _initials(String displayName) {
  final words = displayName
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .take(2);
  final initials = words.map((word) => String.fromCharCode(word.runes.first));
  final value = initials.join().toUpperCase();
  return value.isEmpty ? '?' : value;
}

String _expiryLabel(AppLocalizations strings, StatusExpiry expiry) =>
    switch (expiry) {
      StatusExpiry.never => strings.profileStatusExpiryNever,
      StatusExpiry.halfHour => strings.profileStatusExpiryHalfHour,
      StatusExpiry.hour => strings.profileStatusExpiryHour,
      StatusExpiry.fourHours => strings.profileStatusExpiryFourHours,
      StatusExpiry.today => strings.profileStatusExpiryToday,
      StatusExpiry.week => strings.profileStatusExpiryWeek,
    };
