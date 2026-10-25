import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';

// RFC 9525: only subjectAltName identifies a TLS server. A matching CN must
// not override a mismatched SAN, even when the user trusts the fingerprint.
bool certificateMatchesHost(List<int> der, String host) {
  try {
    final certificate =
        ASN1Parser(Uint8List.fromList(der)).nextObject() as ASN1Sequence;
    final tbs = certificate.elements.first as ASN1Sequence;
    final extensions = tbs.elements.where((element) => element.tag == 0xa3);
    if (extensions.length != 1) return false;
    final sequence =
        ASN1Parser(extensions.single.valueBytes()).nextObject() as ASN1Sequence;
    final names = <ASN1Object>[];
    var found = false;
    for (final item in sequence.elements) {
      final extension = item as ASN1Sequence;
      final oid = extension.elements.first as ASN1ObjectIdentifier;
      if (oid.identifier != '2.5.29.17') continue;
      if (found) return false;
      found = true;
      final encoded = extension.elements.last as ASN1OctetString;
      names.addAll(
        (ASN1Parser(encoded.valueBytes()).nextObject() as ASN1Sequence)
            .elements,
      );
    }
    final address = InternetAddress.tryParse(host);
    for (final name in names) {
      if (address != null && name.tag == 0x87) {
        final bytes = name.valueBytes();
        final expected = address.rawAddress;
        if (bytes.length == expected.length &&
            Iterable<int>.generate(
              bytes.length,
            ).every((index) => bytes[index] == expected[index])) {
          return true;
        }
      } else if (address == null && name.tag == 0x82) {
        final dns = ascii.decode(name.valueBytes()).toLowerCase();
        final requested = host.toLowerCase();
        if (dns == requested) return true;
        if (dns.startsWith('*.')) {
          final labels = requested.split('.');
          final suffix = dns.substring(2);
          if (!suffix.contains('*') &&
              suffix.contains('.') &&
              labels.length >= 3 &&
              labels.first.isNotEmpty &&
              labels.skip(1).join('.') == suffix) {
            return true;
          }
        }
      }
    }
  } catch (_) {
    // A missing, malformed or unsupported SAN cannot be bypassed by a pin.
    return false;
  }
  return false;
}
