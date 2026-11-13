import '../../../l10n/generated/app_localizations.dart';
import 'emoji_picker.dart';

/// Builds the [EmojiPickerLabels] of the emoji picker from the app strings.
EmojiPickerLabels emojiPickerLabelsFor(AppLocalizations strings) {
  return EmojiPickerLabels(
    title: strings.emojiPickerTitle,
    closeTooltip: strings.emojiPickerCloseTooltip,
    manageFavorites: strings.emojiManageFavorites,
    finishManagingFavorites: strings.emojiFinishManagingFavorites,
    favoriteModeHint: strings.emojiFavoriteModeHint,
    addFavoriteLabel: strings.emojiAddFavoriteLabel,
    removeFavoriteLabel: strings.emojiRemoveFavoriteLabel,
    searchHint: strings.emojiSearchHint,
    noResults: strings.emojiNoResults,
    noRecents: strings.emojiNoRecents,
    noFavorites: strings.emojiNoFavorites,
    categoryLabels: <EmojiCategory, String>{
      EmojiCategory.favorites: strings.emojiCategoryFavorites,
      EmojiCategory.recent: strings.emojiCategoryRecent,
      EmojiCategory.smileys: strings.emojiCategorySmileys,
      EmojiCategory.people: strings.emojiCategoryPeople,
      EmojiCategory.animals: strings.emojiCategoryAnimals,
      EmojiCategory.food: strings.emojiCategoryFood,
      EmojiCategory.activities: strings.emojiCategoryActivities,
      EmojiCategory.travel: strings.emojiCategoryTravel,
      EmojiCategory.objects: strings.emojiCategoryObjects,
      EmojiCategory.symbols: strings.emojiCategorySymbols,
      EmojiCategory.flags: strings.emojiCategoryFlags,
    },
  );
}
