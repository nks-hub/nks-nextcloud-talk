import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../l10n/generated/app_localizations.dart';
import '../chat/composer/emoji_picker.dart';
import '../chat/composer/emoji_picker_labels.dart';
import '../chat/composer/emoji_usage_store.dart';

/// What the quick-emoji sheet returns: a [glyph], or null for "follow the
/// theme". Dismissing the sheet returns no result at all.
typedef OwnTalkEmojiChoice = ({String? glyph});

/// Shows the emoji picker for a shared setting, with the [current] value on top
/// and an action that clears it.
Future<OwnTalkEmojiChoice?> showOwnTalkEmojiSheet({
  required BuildContext context,
  required AccountId accountId,
  required EmojiUsageStore usageStore,
  required String? current,
}) {
  return showModalBottomSheet<OwnTalkEmojiChoice>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final strings = AppLocalizations.of(sheetContext);
      final height = MediaQuery.sizeOf(sheetContext).height;
      return Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SizedBox(
            key: const Key('owntalk-emoji-sheet'),
            // A phone held sideways has no room to spare.
            height: height * (height < 480 ? 0.96 : 0.78),
            child: Column(
              children: [
                _CurrentEmojiHeader(
                  current: current,
                  currentLabel: strings.ownTalkEmojiCurrent,
                  emptyLabel: strings.ownTalkSharedThemeDefault,
                  resetLabel: strings.ownTalkEmojiReset,
                  onReset: () => Navigator.of(
                    sheetContext,
                  ).pop<OwnTalkEmojiChoice>((glyph: null)),
                ),
                const Divider(height: 1),
                Expanded(
                  child: EmojiPicker(
                    accountId: accountId,
                    usageStore: usageStore,
                    labels: emojiPickerLabelsFor(strings),
                    selectedGlyph: current,
                    onClose: () => Navigator.of(sheetContext).pop(),
                    onSelected: (choice) => Navigator.of(
                      sheetContext,
                    ).pop<OwnTalkEmojiChoice>((glyph: choice.glyph)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

final class _CurrentEmojiHeader extends StatelessWidget {
  const _CurrentEmojiHeader({
    required this.current,
    required this.currentLabel,
    required this.emptyLabel,
    required this.resetLabel,
    required this.onReset,
  });

  final String? current;
  final String currentLabel;
  final String emptyLabel;
  final String resetLabel;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final glyph = current;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Container(
              key: const Key('owntalk-emoji-current'),
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: glyph == null
                  ? Icon(
                      Icons.emoji_emotions_outlined,
                      color: scheme.onPrimaryContainer,
                    )
                  : Text(glyph, style: const TextStyle(fontSize: 28)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              container: true,
              label: '$currentLabel: ${glyph ?? emptyLabel}',
              child: ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentLabel,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      glyph ?? emptyLabel,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (glyph != null)
            TextButton.icon(
              key: const Key('owntalk-emoji-reset'),
              onPressed: onReset,
              icon: const Icon(Icons.restart_alt_rounded),
              label: Text(resetLabel),
            ),
        ],
      ),
    );
  }
}
