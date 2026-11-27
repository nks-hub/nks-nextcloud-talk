import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'gif_favorites_store.dart';
import 'giphy.dart';

export 'gif_favorites_store.dart';

final gifFavoritesStoreProvider = Provider<GifFavoritesStore>(
  (ref) => GifFavoritesStore(),
);

final class GifFavoritesView {
  const GifFavoritesView._(this.entries, this.loading, this.toggle);

  final List<GiphyEntry> entries;
  final bool loading;
  final Future<void> Function(GiphyEntry) toggle;

  bool contains(GiphyEntry entry) =>
      entries.any((other) => sameFavoriteGif(other, entry));
}

final class GifFavoritesScope extends StatefulWidget {
  const GifFavoritesScope({
    required this.accountId,
    required this.store,
    required this.builder,
    super.key,
  });

  final AccountId accountId;
  final GifFavoritesStore store;
  final Widget Function(BuildContext, GifFavoritesView) builder;

  @override
  State<GifFavoritesScope> createState() => _GifFavoritesScopeState();
}

class _GifFavoritesScopeState extends State<GifFavoritesScope> {
  late Future<List<GiphyEntry>> _entries;

  @override
  void initState() {
    super.initState();
    _entries = widget.store.read(widget.accountId);
    widget.store.addListener(_refresh);
  }

  @override
  void didUpdateWidget(GifFavoritesScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store == widget.store &&
        oldWidget.accountId == widget.accountId) {
      return;
    }
    oldWidget.store.removeListener(_refresh);
    widget.store.addListener(_refresh);
    _entries = widget.store.read(widget.accountId);
  }

  void _refresh() => setState(() {
    _entries = widget.store.read(widget.accountId);
  });

  @override
  void dispose() {
    widget.store.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.accountId;
    final store = widget.store;
    return FutureBuilder<List<GiphyEntry>>(
      key: ValueKey((account, store)),
      future: _entries,
      builder: (context, snapshot) {
        final entries = snapshot.data ?? const <GiphyEntry>[];
        return widget.builder(
          context,
          GifFavoritesView._(
            entries,
            snapshot.connectionState != ConnectionState.done &&
                !snapshot.hasData,
            (entry) async {
              if (!mounted ||
                  account != widget.accountId ||
                  store != widget.store) {
                return;
              }
              try {
                await store.setFavorite(
                  account,
                  entry,
                  saved: !entries.any((other) => sameFavoriteGif(other, entry)),
                );
              } on Object {
                if (!context.mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(
                    content: Text(
                      AppLocalizations.of(context).giphyFavoritesError,
                    ),
                  ),
                );
              }
            },
          ),
        );
      },
    );
  }
}

final class GifFavoriteButton extends StatelessWidget {
  const GifFavoriteButton({
    required this.entry,
    required this.favorites,
    super.key,
  });

  final GiphyEntry entry;
  final GifFavoritesView favorites;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final saved = favorites.contains(entry);
    return IconButton(
      key: ValueKey('gif-favorite-${entry.resourceUrl}'),
      tooltip: saved ? strings.giphyRemoveFavorite : strings.giphySaveFavorite,
      isSelected: saved,
      onPressed: favorites.loading ? null : () => favorites.toggle(entry),
      icon: const Icon(Icons.star_border_rounded),
      selectedIcon: const Icon(Icons.star_rounded),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: .64),
        foregroundColor: Colors.white,
        minimumSize: const Size.square(34),
        tapTargetSize: MaterialTapTargetSize.padded,
        padding: const EdgeInsets.all(6),
        iconSize: 18,
      ),
    );
  }
}
