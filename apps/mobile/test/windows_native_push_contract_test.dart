import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'windows/runner/shell_notification.cpp',
  ).readAsStringSync();
  final header = File('windows/runner/shell_notification.h').readAsStringSync();
  final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();

  test('Windows uses actionable WinRT toasts with bounded opaque routes', () {
    expect(source, contains('ToastNotificationManager::CreateToastNotifier'));
    expect(source, contains('arguments=\\"open:'));
    expect(source, contains('arguments=\\"reply:'));
    expect(source, contains('arguments=\\"markRead:'));
    expect(source, contains('activationType=\\"foreground'));
    expect(source, contains('constexpr size_t kMaximumRoutes = 64'));
    expect(source, isNot(contains('Shell_NotifyIcon')));
    expect(cmake, contains('"windowsapp.lib"'));
  });

  test('native channel requires an account-scoped route', () {
    expect(source, contains('StringAt(*arguments, "accountId")'));
    expect(source, contains('StringAt(*arguments, "roomToken")'));
    expect(source, contains('"notificationOpened"'));
    expect(source, contains('"notificationAction"'));
    expect(source, contains('"replyText"'));
    expect(source, contains('kind == L"reply" && reply_text.empty()'));
  });

  test('toast XML carries only an opaque route identifier', () {
    final xmlStart = source.indexOf('std::wstring ToastXml(');
    final xmlEnd = source.indexOf('struct Route {', xmlStart);
    expect(xmlStart, greaterThanOrEqualTo(0));
    expect(xmlEnd, greaterThan(xmlStart));
    final xmlBuilder = source.substring(xmlStart, xmlEnd);
    expect(xmlBuilder, contains('route_id'));
    expect(xmlBuilder, isNot(contains('account_id')));
    expect(xmlBuilder, isNot(contains('room_token')));
  });

  test('a message toast sounds like a message, not like anything else', () {
    // Windows plays a default sound for a toast that names none, so this is
    // not about being audible at all — it is about being the RIGHT sound.
    // Upstream Talk draws the same line on Android, where the message channel
    // and the call channel carry different audio; a chat message and a
    // ringing call are not the same interruption.
    final xmlStart = source.indexOf('std::wstring ToastXml(');
    final xmlEnd = source.indexOf('struct Route {', xmlStart);
    final xmlBuilder = source.substring(xmlStart, xmlEnd);

    expect(xmlBuilder, contains('ms-winsoundevent:Notification.IM'));
    expect(
      xmlBuilder,
      isNot(contains('silent=')),
      reason: 'a silenced toast is how a notification stops being noticed',
    );
    expect(
      xmlBuilder.indexOf('<audio'),
      greaterThan(xmlBuilder.indexOf('</actions>')),
      reason: 'audio belongs after actions, or the toast XML is invalid',
    );
  });

  test('activation returns to the Flutter platform thread', () {
    expect(header, contains('kActivationMessage'));
    expect(source, contains('::PostMessageW('));
    expect(source, contains('HandleActivation()'));
  });

  test('unpackaged runtime does not pretend to support killed-app push', () {
    expect(
      header,
      contains('cannot start it for a push or a toast activation'),
    );
    expect(source, isNot(contains('INotificationActivationCallback')));
    expect(source, isNot(contains('PushNotificationChannelManager')));
  });
}
