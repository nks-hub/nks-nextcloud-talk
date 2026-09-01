import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');
  final subdirectory = ServerBase.parse('https://cloud.example.invalid/nc');
  const id = '0123456789abcdef0123456789abcdef';

  bool safe(ServerBase base, String? raw) => isSafeReferenceThumbnail(
    server: base,
    thumbnail: raw == null ? null : Uri.parse(raw),
  );

  group('isSafeReferenceThumbnail', () {
    test('accepts the proxy address Nextcloud generates', () {
      expect(
        safe(
          server,
          'https://cloud.example.invalid/index.php/core/references/preview/$id',
        ),
        isTrue,
      );
      expect(
        safe(
          server,
          'https://cloud.example.invalid/core/references/preview/$id',
        ),
        isTrue,
      );
      expect(
        safe(
          subdirectory,
          'https://cloud.example.invalid/nc/index.php/core/references/preview/$id',
        ),
        isTrue,
      );
    });

    test('refuses anything that would reach the linked site', () {
      // The whole point: a third-party image address never gets fetched.
      expect(
        safe(
          server,
          'https://tracker.example.invalid/index.php/core/references/preview/$id',
        ),
        isFalse,
      );
      expect(
        safe(
          server,
          'http://cloud.example.invalid/index.php/core/references/preview/$id',
        ),
        isFalse,
      );
      expect(
        safe(
          server,
          'https://user:pass@cloud.example.invalid/core/references/preview/$id',
        ),
        isFalse,
      );
    });

    test('refuses any other endpoint on the same server', () {
      expect(
        safe(
          server,
          'https://cloud.example.invalid/remote.php/dav/files/alice/a.png',
        ),
        isFalse,
      );
      expect(
        safe(server, 'https://cloud.example.invalid/core/references/preview'),
        isFalse,
      );
      expect(
        safe(
          server,
          'https://cloud.example.invalid/core/references/preview/$id/extra',
        ),
        isFalse,
      );
      expect(
        safe(
          server,
          'https://cloud.example.invalid/core/references/preview/not-an-md5',
        ),
        isFalse,
      );
      expect(
        safe(
          server,
          'https://cloud.example.invalid/core/references/preview/$id?x=1',
        ),
        isFalse,
      );
      expect(
        safe(
          server,
          'https://cloud.example.invalid/core/references/preview/$id#a',
        ),
        isFalse,
      );
    });

    test('does not let a subdirectory install be escaped', () {
      expect(
        safe(
          subdirectory,
          'https://cloud.example.invalid/core/references/preview/$id',
        ),
        isFalse,
      );
    });

    test('a missing thumbnail is simply not safe', () {
      expect(safe(server, null), isFalse);
    });
  });
}
