import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/giphy_reference.dart';

void main() {
  group('Giphy reference preview', () {
    test(
      'normalizes an exact supported reference without exposing the URL',
      () {
        const resource = 'https://giphy.com/gifs/waving-cat-fixture123';

        expect(exactGiphyResource(resource), Uri.parse(resource));
        expect(normalizeGiphyReferencePreview(resource), giphyPreviewLabel);
      },
    );

    test('replaces a supported reference inside ordinary text', () {
      const message =
          'See https://giphy.com/gifs/waving-cat-fixture123 after lunch';

      expect(exactGiphyResource(message), isNull);
      expect(normalizeGiphyReferencePreview(message), 'See GIF after lunch');
    });

    test('preserves a long punctuation suffix in linear normalization', () {
      const resource = 'https://giphy.com/gifs/waving-cat-fixture123';
      final suffix = List<String>.filled(32768, '!').join();

      expect(
        normalizeGiphyReferencePreview('$resource$suffix'),
        '$giphyPreviewLabel$suffix',
      );
    });

    test('rejects unsafe or ambiguous Giphy-like URLs', () {
      for (final value in <String>[
        'http://giphy.com/gifs/waving-cat-fixture123',
        'https://giphy.example.invalid/gifs/waving-cat-fixture123',
        'https://giphy.com/gifs/waving-cat-fixture123?download=1',
        'https://giphy.com/gifs/waving-cat-fixture123#fragment',
      ]) {
        expect(exactGiphyResource(value), isNull, reason: value);
        expect(normalizeGiphyReferencePreview(value), value, reason: value);
      }
    });
  });
}
