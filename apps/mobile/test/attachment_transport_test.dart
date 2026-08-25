import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:talk_protocol/talk_protocol.dart';

part 'attachment_transport_lifecycle_test.part.dart';
part 'attachment_transport_test_support.part.dart';
part 'attachment_transport_wire_test.part.dart';

void main() {
  group('HttpAttachmentTransport', () {
    _registerWireTests();
    _registerLifecycleTests();
  });
}
