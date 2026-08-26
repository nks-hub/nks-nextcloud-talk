import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOStreamedResponse;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

part 'chat_composer_giphy_test_capabilities.dart';
part 'chat_composer_giphy_test_repository.dart';
part 'chat_composer_giphy_test_support.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid/nextcloud');
  const authorization = GiphyAuthorization(
    loginName: 'fixture-user',
    appPassword: 'fixture-password',
  );

  _registerGiphyCapabilityTests();
  _registerGiphyRepositoryTests(server, authorization);
}
