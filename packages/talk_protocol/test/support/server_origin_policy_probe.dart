import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';

void main() {
  if (ServerOriginPolicy.debug.allowDebugHttp) {
    stderr.writeln('Debug HTTP remained enabled in a release executable.');
    exitCode = 1;
    return;
  }

  try {
    ServerBase.parse(
      'http://127.0.0.1:8080/nextcloud',
      policy: ServerOriginPolicy.debug,
    );
  } on TalkProtocolException catch (error) {
    if (error.code == TalkProtocolErrorCode.insecureServerAddress) {
      return;
    }
  }

  stderr.writeln('A release executable accepted an HTTP server.');
  exitCode = 1;
}
