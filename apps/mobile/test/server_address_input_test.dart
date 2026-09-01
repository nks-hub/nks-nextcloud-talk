import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/onboarding/server_address_input.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  String base(String raw) =>
      ServerBase.parse(normalizeServerAddressInput(raw)).value;

  group('normalizeServerAddressInput', () {
    test('keeps a plain host untouched', () {
      expect(base('cloud.example.invalid'), 'https://cloud.example.invalid');
      expect(
        base('https://cloud.example.invalid'),
        'https://cloud.example.invalid',
      );
    });

    test('accepts the surrounding noise a paste carries', () {
      expect(
        base('  https://cloud.example.invalid/  '),
        'https://cloud.example.invalid',
      );
      expect(
        base('<https://cloud.example.invalid>'),
        'https://cloud.example.invalid',
      );
      expect(
        base('https://cloud.example.invalid,'),
        'https://cloud.example.invalid',
      );
    });

    test('drops the query and fragment a browser URL carries', () {
      expect(
        base('https://cloud.example.invalid/?dir=/'),
        'https://cloud.example.invalid',
      );
      expect(
        base('https://cloud.example.invalid#/apps'),
        'https://cloud.example.invalid',
      );
    });

    test('reduces a pasted in-app address to the server base', () {
      expect(
        base('https://cloud.example.invalid/index.php/apps/spreed/'),
        'https://cloud.example.invalid',
      );
      expect(
        base('https://cloud.example.invalid/index.php/login'),
        'https://cloud.example.invalid',
      );
      expect(
        base('https://cloud.example.invalid/settings/user'),
        'https://cloud.example.invalid',
      );
      expect(
        base('https://cloud.example.invalid/apps/files?dir=/Photos'),
        'https://cloud.example.invalid',
      );
      expect(
        base('https://cloud.example.invalid/login/flow'),
        'https://cloud.example.invalid',
      );
    });

    test('keeps the subdirectory a Nextcloud install lives in', () {
      expect(
        base('https://cloud.example.invalid/nextcloud'),
        'https://cloud.example.invalid/nextcloud',
      );
      expect(
        base('https://cloud.example.invalid/nextcloud/index.php/apps/spreed'),
        'https://cloud.example.invalid/nextcloud',
      );
      expect(
        base('https://cloud.example.invalid/nextcloud/settings/user'),
        'https://cloud.example.invalid/nextcloud',
      );
    });

    test('leaves an unknown path alone instead of guessing', () {
      expect(
        base('https://cloud.example.invalid/team/cloud'),
        'https://cloud.example.invalid/team/cloud',
      );
    });

    test('survives a paste on top of the prefilled scheme', () {
      expect(
        base('https://https://cloud.example.invalid'),
        'https://cloud.example.invalid',
      );
      expect(
        base('https://https://cloud.example.invalid/index.php/apps/spreed'),
        'https://cloud.example.invalid',
      );
      // A pasted insecure address keeps its scheme and is still refused; the
      // prefilled `https://` must not quietly upgrade what the user pasted.
      expect(
        normalizeServerAddressInput('https://http://cloud.example.invalid'),
        'http://cloud.example.invalid',
      );
      expect(
        () => base('https://http://cloud.example.invalid'),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('never invents an address for empty input', () {
      expect(normalizeServerAddressInput('   '), '');
      expect(normalizeServerAddressInput('https://'), 'https://');
    });
  });
}
