import 'package:flutter/material.dart';

enum EmojiCategory {
  smileys,
  people,
  animals,
  food,
  activities,
  travel,
  objects,
  symbols,
}

final class EmojiChoice {
  const EmojiChoice({
    required this.glyph,
    required this.name,
    required this.keywords,
    required this.category,
  });

  final String glyph;
  final String name;
  final List<String> keywords;
  final EmojiCategory category;

  String get keyName => name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
}

final class EmojiCatalog {
  EmojiCatalog(Iterable<EmojiChoice> choices)
    : choices = List<EmojiChoice>.unmodifiable(choices);

  factory EmojiCatalog.standard() => EmojiCatalog(_standardEmoji);

  final List<EmojiChoice> choices;

  List<EmojiCategory> get categories => List<EmojiCategory>.unmodifiable({
    for (final choice in choices) choice.category,
  });

  List<EmojiChoice> inCategory(EmojiCategory category) =>
      List.unmodifiable(choices.where((choice) => choice.category == category));

  List<EmojiChoice> search(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return List<EmojiChoice>.unmodifiable(choices);
    }
    return List<EmojiChoice>.unmodifiable(
      choices.where(
        (choice) =>
            choice.glyph == normalized ||
            choice.name.toLowerCase().contains(normalized) ||
            choice.keywords.any(
              (keyword) => keyword.toLowerCase().contains(normalized),
            ),
      ),
    );
  }
}

final class EmojiPickerLabels {
  const EmojiPickerLabels({
    required this.searchHint,
    required this.noResults,
    required this.categoryLabels,
  });

  final String searchHint;
  final String noResults;
  final Map<EmojiCategory, String> categoryLabels;
}

final class EmojiPicker extends StatefulWidget {
  const EmojiPicker({
    required this.labels,
    required this.onSelected,
    this.catalog,
    super.key,
  });

  final EmojiPickerLabels labels;
  final ValueChanged<EmojiChoice> onSelected;
  final EmojiCatalog? catalog;

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();
}

final class _EmojiPickerState extends State<EmojiPicker> {
  late final TextEditingController _searchController;
  late EmojiCategory? _category;

  EmojiCatalog get _catalog => widget.catalog ?? EmojiCatalog.standard();

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController()..addListener(_onSearchChanged);
    _category = _catalog.categories.firstOrNull;
  }

  @override
  void didUpdateWidget(covariant EmojiPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.catalog != widget.catalog &&
        !_catalog.categories.contains(_category)) {
      _category = _catalog.categories.firstOrNull;
    }
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _onSearchChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim();
    final choices = query.isNotEmpty
        ? _catalog.search(query)
        : _category == null
        ? _catalog.choices
        : _catalog.inCategory(_category!);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            key: const Key('emoji-search'),
            controller: _searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: widget.labels.searchHint,
              prefixIcon: const Icon(Icons.search_rounded),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (query.isEmpty && _catalog.categories.length > 1)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              children: [
                for (final category in _catalog.categories)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: ChoiceChip(
                      key: Key('emoji-category-${category.name}'),
                      label: Text(widget.labels.categoryLabels[category] ?? ''),
                      selected: category == _category,
                      onSelected: (_) => setState(() => _category = category),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: choices.isEmpty
              ? Center(child: Text(widget.labels.noResults))
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 56,
                    mainAxisExtent: 48,
                  ),
                  itemCount: choices.length,
                  itemBuilder: (context, index) {
                    final choice = choices[index];
                    return Center(
                      child: Semantics(
                        key: Key('emoji-choice-${choice.keyName}'),
                        container: true,
                        button: true,
                        label: choice.name,
                        onTap: () => widget.onSelected(choice),
                        child: SizedBox.square(
                          dimension: 48,
                          child: InkWell(
                            excludeFromSemantics: true,
                            borderRadius: BorderRadius.circular(24),
                            onTap: () => widget.onSelected(choice),
                            child: Center(
                              child: ExcludeSemantics(
                                child: Text(
                                  choice.glyph,
                                  style: const TextStyle(fontSize: 26),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

const List<EmojiChoice> _standardEmoji = <EmojiChoice>[
  EmojiChoice(
    glyph: '😀',
    name: 'Grinning face',
    keywords: ['smile', 'happy'],
    category: EmojiCategory.smileys,
  ),
  EmojiChoice(
    glyph: '😂',
    name: 'Face with tears of joy',
    keywords: ['laugh', 'funny'],
    category: EmojiCategory.smileys,
  ),
  EmojiChoice(
    glyph: '🥰',
    name: 'Smiling face with hearts',
    keywords: ['love', 'affection'],
    category: EmojiCategory.smileys,
  ),
  EmojiChoice(
    glyph: '🤔',
    name: 'Thinking face',
    keywords: ['think', 'question'],
    category: EmojiCategory.smileys,
  ),
  EmojiChoice(
    glyph: '😢',
    name: 'Crying face',
    keywords: ['sad', 'tear'],
    category: EmojiCategory.smileys,
  ),
  EmojiChoice(
    glyph: '👋',
    name: 'Waving hand',
    keywords: ['wave', 'hello', 'goodbye'],
    category: EmojiCategory.people,
  ),
  EmojiChoice(
    glyph: '👍',
    name: 'Thumbs up',
    keywords: ['yes', 'approve', 'like'],
    category: EmojiCategory.people,
  ),
  EmojiChoice(
    glyph: '👎',
    name: 'Thumbs down',
    keywords: ['no', 'disapprove'],
    category: EmojiCategory.people,
  ),
  EmojiChoice(
    glyph: '🙏',
    name: 'Folded hands',
    keywords: ['please', 'thanks'],
    category: EmojiCategory.people,
  ),
  EmojiChoice(
    glyph: '💪',
    name: 'Flexed biceps',
    keywords: ['strong', 'strength'],
    category: EmojiCategory.people,
  ),
  EmojiChoice(
    glyph: '🐱',
    name: 'Cat face',
    keywords: ['cat', 'pet', 'animal'],
    category: EmojiCategory.animals,
  ),
  EmojiChoice(
    glyph: '🐶',
    name: 'Dog face',
    keywords: ['dog', 'pet', 'animal'],
    category: EmojiCategory.animals,
  ),
  EmojiChoice(
    glyph: '🦊',
    name: 'Fox',
    keywords: ['fox', 'animal'],
    category: EmojiCategory.animals,
  ),
  EmojiChoice(
    glyph: '🐼',
    name: 'Panda',
    keywords: ['panda', 'animal'],
    category: EmojiCategory.animals,
  ),
  EmojiChoice(
    glyph: '🍎',
    name: 'Red apple',
    keywords: ['apple', 'fruit'],
    category: EmojiCategory.food,
  ),
  EmojiChoice(
    glyph: '🍕',
    name: 'Pizza',
    keywords: ['pizza', 'food'],
    category: EmojiCategory.food,
  ),
  EmojiChoice(
    glyph: '☕',
    name: 'Hot beverage',
    keywords: ['coffee', 'tea', 'drink'],
    category: EmojiCategory.food,
  ),
  EmojiChoice(
    glyph: '🎂',
    name: 'Birthday cake',
    keywords: ['cake', 'birthday'],
    category: EmojiCategory.food,
  ),
  EmojiChoice(
    glyph: '⚽',
    name: 'Soccer ball',
    keywords: ['football', 'sport'],
    category: EmojiCategory.activities,
  ),
  EmojiChoice(
    glyph: '🎮',
    name: 'Video game',
    keywords: ['game', 'controller'],
    category: EmojiCategory.activities,
  ),
  EmojiChoice(
    glyph: '🎨',
    name: 'Artist palette',
    keywords: ['art', 'paint'],
    category: EmojiCategory.activities,
  ),
  EmojiChoice(
    glyph: '🚗',
    name: 'Car',
    keywords: ['car', 'travel'],
    category: EmojiCategory.travel,
  ),
  EmojiChoice(
    glyph: '✈️',
    name: 'Airplane',
    keywords: ['plane', 'flight', 'travel'],
    category: EmojiCategory.travel,
  ),
  EmojiChoice(
    glyph: '🌍',
    name: 'Globe',
    keywords: ['earth', 'world'],
    category: EmojiCategory.travel,
  ),
  EmojiChoice(
    glyph: '💡',
    name: 'Light bulb',
    keywords: ['idea', 'light'],
    category: EmojiCategory.objects,
  ),
  EmojiChoice(
    glyph: '📱',
    name: 'Mobile phone',
    keywords: ['phone', 'device'],
    category: EmojiCategory.objects,
  ),
  EmojiChoice(
    glyph: '🔑',
    name: 'Key',
    keywords: ['key', 'security'],
    category: EmojiCategory.objects,
  ),
  EmojiChoice(
    glyph: '❤️',
    name: 'Red heart',
    keywords: ['heart', 'love'],
    category: EmojiCategory.symbols,
  ),
  EmojiChoice(
    glyph: '✅',
    name: 'Check mark button',
    keywords: ['check', 'done', 'yes'],
    category: EmojiCategory.symbols,
  ),
  EmojiChoice(
    glyph: '❌',
    name: 'Cross mark',
    keywords: ['cross', 'no', 'error'],
    category: EmojiCategory.symbols,
  ),
  EmojiChoice(
    glyph: '⚠️',
    name: 'Warning',
    keywords: ['warning', 'caution'],
    category: EmojiCategory.symbols,
  ),
];
