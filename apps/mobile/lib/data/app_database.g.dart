// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $AccountsTable extends Accounts
    with TableInfo<$AccountsTable, StoredAccount> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AccountsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverUrlMeta = const VerificationMeta(
    'serverUrl',
  );
  @override
  late final GeneratedColumn<String> serverUrl = GeneratedColumn<String>(
    'server_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _loginNameMeta = const VerificationMeta(
    'loginName',
  );
  @override
  late final GeneratedColumn<String> loginName = GeneratedColumn<String>(
    'login_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverProductNameMeta = const VerificationMeta(
    'serverProductName',
  );
  @override
  late final GeneratedColumn<String> serverProductName =
      GeneratedColumn<String>(
        'server_product_name',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _talkFeaturesJsonMeta = const VerificationMeta(
    'talkFeaturesJson',
  );
  @override
  late final GeneratedColumn<String> talkFeaturesJson = GeneratedColumn<String>(
    'talk_features_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _selectedMeta = const VerificationMeta(
    'selected',
  );
  @override
  late final GeneratedColumn<bool> selected = GeneratedColumn<bool>(
    'selected',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("selected" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMillisMeta = const VerificationMeta(
    'createdAtMillis',
  );
  @override
  late final GeneratedColumn<int> createdAtMillis = GeneratedColumn<int>(
    'created_at_millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _conversationCursorMeta =
      const VerificationMeta('conversationCursor');
  @override
  late final GeneratedColumn<String> conversationCursor =
      GeneratedColumn<String>(
        'conversation_cursor',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _conversationHashMeta = const VerificationMeta(
    'conversationHash',
  );
  @override
  late final GeneratedColumn<String> conversationHash = GeneratedColumn<String>(
    'conversation_hash',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _emptyConfirmationRequestIdMeta =
      const VerificationMeta('emptyConfirmationRequestId');
  @override
  late final GeneratedColumn<String> emptyConfirmationRequestId =
      GeneratedColumn<String>(
        'empty_confirmation_request_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _emptyConfirmationObservedAtMillisMeta =
      const VerificationMeta('emptyConfirmationObservedAtMillis');
  @override
  late final GeneratedColumn<int> emptyConfirmationObservedAtMillis =
      GeneratedColumn<int>(
        'empty_confirmation_observed_at_millis',
        aliasedName,
        true,
        type: DriftSqlType.int,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _lastSyncedAtMillisMeta =
      const VerificationMeta('lastSyncedAtMillis');
  @override
  late final GeneratedColumn<int> lastSyncedAtMillis = GeneratedColumn<int>(
    'last_synced_at_millis',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastSyncErrorMeta = const VerificationMeta(
    'lastSyncError',
  );
  @override
  late final GeneratedColumn<String> lastSyncError = GeneratedColumn<String>(
    'last_sync_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    serverUrl,
    loginName,
    serverProductName,
    talkFeaturesJson,
    selected,
    createdAtMillis,
    conversationCursor,
    conversationHash,
    emptyConfirmationRequestId,
    emptyConfirmationObservedAtMillis,
    lastSyncedAtMillis,
    lastSyncError,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'accounts';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredAccount> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('server_url')) {
      context.handle(
        _serverUrlMeta,
        serverUrl.isAcceptableOrUnknown(data['server_url']!, _serverUrlMeta),
      );
    } else if (isInserting) {
      context.missing(_serverUrlMeta);
    }
    if (data.containsKey('login_name')) {
      context.handle(
        _loginNameMeta,
        loginName.isAcceptableOrUnknown(data['login_name']!, _loginNameMeta),
      );
    } else if (isInserting) {
      context.missing(_loginNameMeta);
    }
    if (data.containsKey('server_product_name')) {
      context.handle(
        _serverProductNameMeta,
        serverProductName.isAcceptableOrUnknown(
          data['server_product_name']!,
          _serverProductNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverProductNameMeta);
    }
    if (data.containsKey('talk_features_json')) {
      context.handle(
        _talkFeaturesJsonMeta,
        talkFeaturesJson.isAcceptableOrUnknown(
          data['talk_features_json']!,
          _talkFeaturesJsonMeta,
        ),
      );
    }
    if (data.containsKey('selected')) {
      context.handle(
        _selectedMeta,
        selected.isAcceptableOrUnknown(data['selected']!, _selectedMeta),
      );
    }
    if (data.containsKey('created_at_millis')) {
      context.handle(
        _createdAtMillisMeta,
        createdAtMillis.isAcceptableOrUnknown(
          data['created_at_millis']!,
          _createdAtMillisMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_createdAtMillisMeta);
    }
    if (data.containsKey('conversation_cursor')) {
      context.handle(
        _conversationCursorMeta,
        conversationCursor.isAcceptableOrUnknown(
          data['conversation_cursor']!,
          _conversationCursorMeta,
        ),
      );
    }
    if (data.containsKey('conversation_hash')) {
      context.handle(
        _conversationHashMeta,
        conversationHash.isAcceptableOrUnknown(
          data['conversation_hash']!,
          _conversationHashMeta,
        ),
      );
    }
    if (data.containsKey('empty_confirmation_request_id')) {
      context.handle(
        _emptyConfirmationRequestIdMeta,
        emptyConfirmationRequestId.isAcceptableOrUnknown(
          data['empty_confirmation_request_id']!,
          _emptyConfirmationRequestIdMeta,
        ),
      );
    }
    if (data.containsKey('empty_confirmation_observed_at_millis')) {
      context.handle(
        _emptyConfirmationObservedAtMillisMeta,
        emptyConfirmationObservedAtMillis.isAcceptableOrUnknown(
          data['empty_confirmation_observed_at_millis']!,
          _emptyConfirmationObservedAtMillisMeta,
        ),
      );
    }
    if (data.containsKey('last_synced_at_millis')) {
      context.handle(
        _lastSyncedAtMillisMeta,
        lastSyncedAtMillis.isAcceptableOrUnknown(
          data['last_synced_at_millis']!,
          _lastSyncedAtMillisMeta,
        ),
      );
    }
    if (data.containsKey('last_sync_error')) {
      context.handle(
        _lastSyncErrorMeta,
        lastSyncError.isAcceptableOrUnknown(
          data['last_sync_error']!,
          _lastSyncErrorMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {serverUrl, loginName},
  ];
  @override
  StoredAccount map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredAccount(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      serverUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_url'],
      )!,
      loginName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}login_name'],
      )!,
      serverProductName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_product_name'],
      )!,
      talkFeaturesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}talk_features_json'],
      )!,
      selected: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}selected'],
      )!,
      createdAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_millis'],
      )!,
      conversationCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_cursor'],
      ),
      conversationHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_hash'],
      ),
      emptyConfirmationRequestId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}empty_confirmation_request_id'],
      ),
      emptyConfirmationObservedAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}empty_confirmation_observed_at_millis'],
      ),
      lastSyncedAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_synced_at_millis'],
      ),
      lastSyncError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_sync_error'],
      ),
    );
  }

  @override
  $AccountsTable createAlias(String alias) {
    return $AccountsTable(attachedDatabase, alias);
  }
}

class StoredAccount extends DataClass implements Insertable<StoredAccount> {
  final String id;
  final String serverUrl;
  final String loginName;
  final String serverProductName;
  final String talkFeaturesJson;
  final bool selected;
  final int createdAtMillis;
  final String? conversationCursor;
  final String? conversationHash;
  final String? emptyConfirmationRequestId;
  final int? emptyConfirmationObservedAtMillis;
  final int? lastSyncedAtMillis;
  final String? lastSyncError;
  const StoredAccount({
    required this.id,
    required this.serverUrl,
    required this.loginName,
    required this.serverProductName,
    required this.talkFeaturesJson,
    required this.selected,
    required this.createdAtMillis,
    this.conversationCursor,
    this.conversationHash,
    this.emptyConfirmationRequestId,
    this.emptyConfirmationObservedAtMillis,
    this.lastSyncedAtMillis,
    this.lastSyncError,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['server_url'] = Variable<String>(serverUrl);
    map['login_name'] = Variable<String>(loginName);
    map['server_product_name'] = Variable<String>(serverProductName);
    map['talk_features_json'] = Variable<String>(talkFeaturesJson);
    map['selected'] = Variable<bool>(selected);
    map['created_at_millis'] = Variable<int>(createdAtMillis);
    if (!nullToAbsent || conversationCursor != null) {
      map['conversation_cursor'] = Variable<String>(conversationCursor);
    }
    if (!nullToAbsent || conversationHash != null) {
      map['conversation_hash'] = Variable<String>(conversationHash);
    }
    if (!nullToAbsent || emptyConfirmationRequestId != null) {
      map['empty_confirmation_request_id'] = Variable<String>(
        emptyConfirmationRequestId,
      );
    }
    if (!nullToAbsent || emptyConfirmationObservedAtMillis != null) {
      map['empty_confirmation_observed_at_millis'] = Variable<int>(
        emptyConfirmationObservedAtMillis,
      );
    }
    if (!nullToAbsent || lastSyncedAtMillis != null) {
      map['last_synced_at_millis'] = Variable<int>(lastSyncedAtMillis);
    }
    if (!nullToAbsent || lastSyncError != null) {
      map['last_sync_error'] = Variable<String>(lastSyncError);
    }
    return map;
  }

  AccountsCompanion toCompanion(bool nullToAbsent) {
    return AccountsCompanion(
      id: Value(id),
      serverUrl: Value(serverUrl),
      loginName: Value(loginName),
      serverProductName: Value(serverProductName),
      talkFeaturesJson: Value(talkFeaturesJson),
      selected: Value(selected),
      createdAtMillis: Value(createdAtMillis),
      conversationCursor: conversationCursor == null && nullToAbsent
          ? const Value.absent()
          : Value(conversationCursor),
      conversationHash: conversationHash == null && nullToAbsent
          ? const Value.absent()
          : Value(conversationHash),
      emptyConfirmationRequestId:
          emptyConfirmationRequestId == null && nullToAbsent
          ? const Value.absent()
          : Value(emptyConfirmationRequestId),
      emptyConfirmationObservedAtMillis:
          emptyConfirmationObservedAtMillis == null && nullToAbsent
          ? const Value.absent()
          : Value(emptyConfirmationObservedAtMillis),
      lastSyncedAtMillis: lastSyncedAtMillis == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSyncedAtMillis),
      lastSyncError: lastSyncError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSyncError),
    );
  }

  factory StoredAccount.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredAccount(
      id: serializer.fromJson<String>(json['id']),
      serverUrl: serializer.fromJson<String>(json['serverUrl']),
      loginName: serializer.fromJson<String>(json['loginName']),
      serverProductName: serializer.fromJson<String>(json['serverProductName']),
      talkFeaturesJson: serializer.fromJson<String>(json['talkFeaturesJson']),
      selected: serializer.fromJson<bool>(json['selected']),
      createdAtMillis: serializer.fromJson<int>(json['createdAtMillis']),
      conversationCursor: serializer.fromJson<String?>(
        json['conversationCursor'],
      ),
      conversationHash: serializer.fromJson<String?>(json['conversationHash']),
      emptyConfirmationRequestId: serializer.fromJson<String?>(
        json['emptyConfirmationRequestId'],
      ),
      emptyConfirmationObservedAtMillis: serializer.fromJson<int?>(
        json['emptyConfirmationObservedAtMillis'],
      ),
      lastSyncedAtMillis: serializer.fromJson<int?>(json['lastSyncedAtMillis']),
      lastSyncError: serializer.fromJson<String?>(json['lastSyncError']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'serverUrl': serializer.toJson<String>(serverUrl),
      'loginName': serializer.toJson<String>(loginName),
      'serverProductName': serializer.toJson<String>(serverProductName),
      'talkFeaturesJson': serializer.toJson<String>(talkFeaturesJson),
      'selected': serializer.toJson<bool>(selected),
      'createdAtMillis': serializer.toJson<int>(createdAtMillis),
      'conversationCursor': serializer.toJson<String?>(conversationCursor),
      'conversationHash': serializer.toJson<String?>(conversationHash),
      'emptyConfirmationRequestId': serializer.toJson<String?>(
        emptyConfirmationRequestId,
      ),
      'emptyConfirmationObservedAtMillis': serializer.toJson<int?>(
        emptyConfirmationObservedAtMillis,
      ),
      'lastSyncedAtMillis': serializer.toJson<int?>(lastSyncedAtMillis),
      'lastSyncError': serializer.toJson<String?>(lastSyncError),
    };
  }

  StoredAccount copyWith({
    String? id,
    String? serverUrl,
    String? loginName,
    String? serverProductName,
    String? talkFeaturesJson,
    bool? selected,
    int? createdAtMillis,
    Value<String?> conversationCursor = const Value.absent(),
    Value<String?> conversationHash = const Value.absent(),
    Value<String?> emptyConfirmationRequestId = const Value.absent(),
    Value<int?> emptyConfirmationObservedAtMillis = const Value.absent(),
    Value<int?> lastSyncedAtMillis = const Value.absent(),
    Value<String?> lastSyncError = const Value.absent(),
  }) => StoredAccount(
    id: id ?? this.id,
    serverUrl: serverUrl ?? this.serverUrl,
    loginName: loginName ?? this.loginName,
    serverProductName: serverProductName ?? this.serverProductName,
    talkFeaturesJson: talkFeaturesJson ?? this.talkFeaturesJson,
    selected: selected ?? this.selected,
    createdAtMillis: createdAtMillis ?? this.createdAtMillis,
    conversationCursor: conversationCursor.present
        ? conversationCursor.value
        : this.conversationCursor,
    conversationHash: conversationHash.present
        ? conversationHash.value
        : this.conversationHash,
    emptyConfirmationRequestId: emptyConfirmationRequestId.present
        ? emptyConfirmationRequestId.value
        : this.emptyConfirmationRequestId,
    emptyConfirmationObservedAtMillis: emptyConfirmationObservedAtMillis.present
        ? emptyConfirmationObservedAtMillis.value
        : this.emptyConfirmationObservedAtMillis,
    lastSyncedAtMillis: lastSyncedAtMillis.present
        ? lastSyncedAtMillis.value
        : this.lastSyncedAtMillis,
    lastSyncError: lastSyncError.present
        ? lastSyncError.value
        : this.lastSyncError,
  );
  StoredAccount copyWithCompanion(AccountsCompanion data) {
    return StoredAccount(
      id: data.id.present ? data.id.value : this.id,
      serverUrl: data.serverUrl.present ? data.serverUrl.value : this.serverUrl,
      loginName: data.loginName.present ? data.loginName.value : this.loginName,
      serverProductName: data.serverProductName.present
          ? data.serverProductName.value
          : this.serverProductName,
      talkFeaturesJson: data.talkFeaturesJson.present
          ? data.talkFeaturesJson.value
          : this.talkFeaturesJson,
      selected: data.selected.present ? data.selected.value : this.selected,
      createdAtMillis: data.createdAtMillis.present
          ? data.createdAtMillis.value
          : this.createdAtMillis,
      conversationCursor: data.conversationCursor.present
          ? data.conversationCursor.value
          : this.conversationCursor,
      conversationHash: data.conversationHash.present
          ? data.conversationHash.value
          : this.conversationHash,
      emptyConfirmationRequestId: data.emptyConfirmationRequestId.present
          ? data.emptyConfirmationRequestId.value
          : this.emptyConfirmationRequestId,
      emptyConfirmationObservedAtMillis:
          data.emptyConfirmationObservedAtMillis.present
          ? data.emptyConfirmationObservedAtMillis.value
          : this.emptyConfirmationObservedAtMillis,
      lastSyncedAtMillis: data.lastSyncedAtMillis.present
          ? data.lastSyncedAtMillis.value
          : this.lastSyncedAtMillis,
      lastSyncError: data.lastSyncError.present
          ? data.lastSyncError.value
          : this.lastSyncError,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredAccount(')
          ..write('id: $id, ')
          ..write('serverUrl: $serverUrl, ')
          ..write('loginName: $loginName, ')
          ..write('serverProductName: $serverProductName, ')
          ..write('talkFeaturesJson: $talkFeaturesJson, ')
          ..write('selected: $selected, ')
          ..write('createdAtMillis: $createdAtMillis, ')
          ..write('conversationCursor: $conversationCursor, ')
          ..write('conversationHash: $conversationHash, ')
          ..write('emptyConfirmationRequestId: $emptyConfirmationRequestId, ')
          ..write(
            'emptyConfirmationObservedAtMillis: $emptyConfirmationObservedAtMillis, ',
          )
          ..write('lastSyncedAtMillis: $lastSyncedAtMillis, ')
          ..write('lastSyncError: $lastSyncError')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    serverUrl,
    loginName,
    serverProductName,
    talkFeaturesJson,
    selected,
    createdAtMillis,
    conversationCursor,
    conversationHash,
    emptyConfirmationRequestId,
    emptyConfirmationObservedAtMillis,
    lastSyncedAtMillis,
    lastSyncError,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredAccount &&
          other.id == this.id &&
          other.serverUrl == this.serverUrl &&
          other.loginName == this.loginName &&
          other.serverProductName == this.serverProductName &&
          other.talkFeaturesJson == this.talkFeaturesJson &&
          other.selected == this.selected &&
          other.createdAtMillis == this.createdAtMillis &&
          other.conversationCursor == this.conversationCursor &&
          other.conversationHash == this.conversationHash &&
          other.emptyConfirmationRequestId == this.emptyConfirmationRequestId &&
          other.emptyConfirmationObservedAtMillis ==
              this.emptyConfirmationObservedAtMillis &&
          other.lastSyncedAtMillis == this.lastSyncedAtMillis &&
          other.lastSyncError == this.lastSyncError);
}

class AccountsCompanion extends UpdateCompanion<StoredAccount> {
  final Value<String> id;
  final Value<String> serverUrl;
  final Value<String> loginName;
  final Value<String> serverProductName;
  final Value<String> talkFeaturesJson;
  final Value<bool> selected;
  final Value<int> createdAtMillis;
  final Value<String?> conversationCursor;
  final Value<String?> conversationHash;
  final Value<String?> emptyConfirmationRequestId;
  final Value<int?> emptyConfirmationObservedAtMillis;
  final Value<int?> lastSyncedAtMillis;
  final Value<String?> lastSyncError;
  final Value<int> rowid;
  const AccountsCompanion({
    this.id = const Value.absent(),
    this.serverUrl = const Value.absent(),
    this.loginName = const Value.absent(),
    this.serverProductName = const Value.absent(),
    this.talkFeaturesJson = const Value.absent(),
    this.selected = const Value.absent(),
    this.createdAtMillis = const Value.absent(),
    this.conversationCursor = const Value.absent(),
    this.conversationHash = const Value.absent(),
    this.emptyConfirmationRequestId = const Value.absent(),
    this.emptyConfirmationObservedAtMillis = const Value.absent(),
    this.lastSyncedAtMillis = const Value.absent(),
    this.lastSyncError = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AccountsCompanion.insert({
    required String id,
    required String serverUrl,
    required String loginName,
    required String serverProductName,
    this.talkFeaturesJson = const Value.absent(),
    this.selected = const Value.absent(),
    required int createdAtMillis,
    this.conversationCursor = const Value.absent(),
    this.conversationHash = const Value.absent(),
    this.emptyConfirmationRequestId = const Value.absent(),
    this.emptyConfirmationObservedAtMillis = const Value.absent(),
    this.lastSyncedAtMillis = const Value.absent(),
    this.lastSyncError = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       serverUrl = Value(serverUrl),
       loginName = Value(loginName),
       serverProductName = Value(serverProductName),
       createdAtMillis = Value(createdAtMillis);
  static Insertable<StoredAccount> custom({
    Expression<String>? id,
    Expression<String>? serverUrl,
    Expression<String>? loginName,
    Expression<String>? serverProductName,
    Expression<String>? talkFeaturesJson,
    Expression<bool>? selected,
    Expression<int>? createdAtMillis,
    Expression<String>? conversationCursor,
    Expression<String>? conversationHash,
    Expression<String>? emptyConfirmationRequestId,
    Expression<int>? emptyConfirmationObservedAtMillis,
    Expression<int>? lastSyncedAtMillis,
    Expression<String>? lastSyncError,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (serverUrl != null) 'server_url': serverUrl,
      if (loginName != null) 'login_name': loginName,
      if (serverProductName != null) 'server_product_name': serverProductName,
      if (talkFeaturesJson != null) 'talk_features_json': talkFeaturesJson,
      if (selected != null) 'selected': selected,
      if (createdAtMillis != null) 'created_at_millis': createdAtMillis,
      if (conversationCursor != null) 'conversation_cursor': conversationCursor,
      if (conversationHash != null) 'conversation_hash': conversationHash,
      if (emptyConfirmationRequestId != null)
        'empty_confirmation_request_id': emptyConfirmationRequestId,
      if (emptyConfirmationObservedAtMillis != null)
        'empty_confirmation_observed_at_millis':
            emptyConfirmationObservedAtMillis,
      if (lastSyncedAtMillis != null)
        'last_synced_at_millis': lastSyncedAtMillis,
      if (lastSyncError != null) 'last_sync_error': lastSyncError,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AccountsCompanion copyWith({
    Value<String>? id,
    Value<String>? serverUrl,
    Value<String>? loginName,
    Value<String>? serverProductName,
    Value<String>? talkFeaturesJson,
    Value<bool>? selected,
    Value<int>? createdAtMillis,
    Value<String?>? conversationCursor,
    Value<String?>? conversationHash,
    Value<String?>? emptyConfirmationRequestId,
    Value<int?>? emptyConfirmationObservedAtMillis,
    Value<int?>? lastSyncedAtMillis,
    Value<String?>? lastSyncError,
    Value<int>? rowid,
  }) {
    return AccountsCompanion(
      id: id ?? this.id,
      serverUrl: serverUrl ?? this.serverUrl,
      loginName: loginName ?? this.loginName,
      serverProductName: serverProductName ?? this.serverProductName,
      talkFeaturesJson: talkFeaturesJson ?? this.talkFeaturesJson,
      selected: selected ?? this.selected,
      createdAtMillis: createdAtMillis ?? this.createdAtMillis,
      conversationCursor: conversationCursor ?? this.conversationCursor,
      conversationHash: conversationHash ?? this.conversationHash,
      emptyConfirmationRequestId:
          emptyConfirmationRequestId ?? this.emptyConfirmationRequestId,
      emptyConfirmationObservedAtMillis:
          emptyConfirmationObservedAtMillis ??
          this.emptyConfirmationObservedAtMillis,
      lastSyncedAtMillis: lastSyncedAtMillis ?? this.lastSyncedAtMillis,
      lastSyncError: lastSyncError ?? this.lastSyncError,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (serverUrl.present) {
      map['server_url'] = Variable<String>(serverUrl.value);
    }
    if (loginName.present) {
      map['login_name'] = Variable<String>(loginName.value);
    }
    if (serverProductName.present) {
      map['server_product_name'] = Variable<String>(serverProductName.value);
    }
    if (talkFeaturesJson.present) {
      map['talk_features_json'] = Variable<String>(talkFeaturesJson.value);
    }
    if (selected.present) {
      map['selected'] = Variable<bool>(selected.value);
    }
    if (createdAtMillis.present) {
      map['created_at_millis'] = Variable<int>(createdAtMillis.value);
    }
    if (conversationCursor.present) {
      map['conversation_cursor'] = Variable<String>(conversationCursor.value);
    }
    if (conversationHash.present) {
      map['conversation_hash'] = Variable<String>(conversationHash.value);
    }
    if (emptyConfirmationRequestId.present) {
      map['empty_confirmation_request_id'] = Variable<String>(
        emptyConfirmationRequestId.value,
      );
    }
    if (emptyConfirmationObservedAtMillis.present) {
      map['empty_confirmation_observed_at_millis'] = Variable<int>(
        emptyConfirmationObservedAtMillis.value,
      );
    }
    if (lastSyncedAtMillis.present) {
      map['last_synced_at_millis'] = Variable<int>(lastSyncedAtMillis.value);
    }
    if (lastSyncError.present) {
      map['last_sync_error'] = Variable<String>(lastSyncError.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AccountsCompanion(')
          ..write('id: $id, ')
          ..write('serverUrl: $serverUrl, ')
          ..write('loginName: $loginName, ')
          ..write('serverProductName: $serverProductName, ')
          ..write('talkFeaturesJson: $talkFeaturesJson, ')
          ..write('selected: $selected, ')
          ..write('createdAtMillis: $createdAtMillis, ')
          ..write('conversationCursor: $conversationCursor, ')
          ..write('conversationHash: $conversationHash, ')
          ..write('emptyConfirmationRequestId: $emptyConfirmationRequestId, ')
          ..write(
            'emptyConfirmationObservedAtMillis: $emptyConfirmationObservedAtMillis, ',
          )
          ..write('lastSyncedAtMillis: $lastSyncedAtMillis, ')
          ..write('lastSyncError: $lastSyncError, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CachedConversationsTable extends CachedConversations
    with TableInfo<$CachedConversationsTable, CachedConversation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _tokenMeta = const VerificationMeta('token');
  @override
  late final GeneratedColumn<String> token = GeneratedColumn<String>(
    'token',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastActivityMeta = const VerificationMeta(
    'lastActivity',
  );
  @override
  late final GeneratedColumn<int> lastActivity = GeneratedColumn<int>(
    'last_activity',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _unreadMessagesMeta = const VerificationMeta(
    'unreadMessages',
  );
  @override
  late final GeneratedColumn<int> unreadMessages = GeneratedColumn<int>(
    'unread_messages',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _favoriteMeta = const VerificationMeta(
    'favorite',
  );
  @override
  late final GeneratedColumn<bool> favorite = GeneratedColumn<bool>(
    'favorite',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("favorite" IN (0, 1))',
    ),
  );
  static const VerificationMeta _isArchivedMeta = const VerificationMeta(
    'isArchived',
  );
  @override
  late final GeneratedColumn<bool> isArchived = GeneratedColumn<bool>(
    'is_archived',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_archived" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _readOnlyMeta = const VerificationMeta(
    'readOnly',
  );
  @override
  late final GeneratedColumn<int> readOnly = GeneratedColumn<int>(
    'read_only',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _roomTypeMeta = const VerificationMeta(
    'roomType',
  );
  @override
  late final GeneratedColumn<int> roomType = GeneratedColumn<int>(
    'room_type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _roomNameMeta = const VerificationMeta(
    'roomName',
  );
  @override
  late final GeneratedColumn<String> roomName = GeneratedColumn<String>(
    'room_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _objectTypeMeta = const VerificationMeta(
    'objectType',
  );
  @override
  late final GeneratedColumn<String> objectType = GeneratedColumn<String>(
    'object_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _avatarVersionMeta = const VerificationMeta(
    'avatarVersion',
  );
  @override
  late final GeneratedColumn<String> avatarVersion = GeneratedColumn<String>(
    'avatar_version',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _isCustomAvatarMeta = const VerificationMeta(
    'isCustomAvatar',
  );
  @override
  late final GeneratedColumn<bool> isCustomAvatar = GeneratedColumn<bool>(
    'is_custom_avatar',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_custom_avatar" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _peerStatusMeta = const VerificationMeta(
    'peerStatus',
  );
  @override
  late final GeneratedColumn<String> peerStatus = GeneratedColumn<String>(
    'peer_status',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _peerStatusIconMeta = const VerificationMeta(
    'peerStatusIcon',
  );
  @override
  late final GeneratedColumn<String> peerStatusIcon = GeneratedColumn<String>(
    'peer_status_icon',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _peerStatusMessageMeta = const VerificationMeta(
    'peerStatusMessage',
  );
  @override
  late final GeneratedColumn<String> peerStatusMessage =
      GeneratedColumn<String>(
        'peer_status_message',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _peerStatusClearAtMeta = const VerificationMeta(
    'peerStatusClearAt',
  );
  @override
  late final GeneratedColumn<int> peerStatusClearAt = GeneratedColumn<int>(
    'peer_status_clear_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastMessageTextMeta = const VerificationMeta(
    'lastMessageText',
  );
  @override
  late final GeneratedColumn<String> lastMessageText = GeneratedColumn<String>(
    'last_message_text',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastMessageTimestampMeta =
      const VerificationMeta('lastMessageTimestamp');
  @override
  late final GeneratedColumn<int> lastMessageTimestamp = GeneratedColumn<int>(
    'last_message_timestamp',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _rawJsonMeta = const VerificationMeta(
    'rawJson',
  );
  @override
  late final GeneratedColumn<String> rawJson = GeneratedColumn<String>(
    'raw_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    token,
    displayName,
    description,
    lastActivity,
    unreadMessages,
    favorite,
    isArchived,
    readOnly,
    roomType,
    roomName,
    objectType,
    avatarVersion,
    isCustomAvatar,
    peerStatus,
    peerStatusIcon,
    peerStatusMessage,
    peerStatusClearAt,
    lastMessageText,
    lastMessageTimestamp,
    rawJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedConversation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('token')) {
      context.handle(
        _tokenMeta,
        token.isAcceptableOrUnknown(data['token']!, _tokenMeta),
      );
    } else if (isInserting) {
      context.missing(_tokenMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_descriptionMeta);
    }
    if (data.containsKey('last_activity')) {
      context.handle(
        _lastActivityMeta,
        lastActivity.isAcceptableOrUnknown(
          data['last_activity']!,
          _lastActivityMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastActivityMeta);
    }
    if (data.containsKey('unread_messages')) {
      context.handle(
        _unreadMessagesMeta,
        unreadMessages.isAcceptableOrUnknown(
          data['unread_messages']!,
          _unreadMessagesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_unreadMessagesMeta);
    }
    if (data.containsKey('favorite')) {
      context.handle(
        _favoriteMeta,
        favorite.isAcceptableOrUnknown(data['favorite']!, _favoriteMeta),
      );
    } else if (isInserting) {
      context.missing(_favoriteMeta);
    }
    if (data.containsKey('is_archived')) {
      context.handle(
        _isArchivedMeta,
        isArchived.isAcceptableOrUnknown(data['is_archived']!, _isArchivedMeta),
      );
    }
    if (data.containsKey('read_only')) {
      context.handle(
        _readOnlyMeta,
        readOnly.isAcceptableOrUnknown(data['read_only']!, _readOnlyMeta),
      );
    }
    if (data.containsKey('room_type')) {
      context.handle(
        _roomTypeMeta,
        roomType.isAcceptableOrUnknown(data['room_type']!, _roomTypeMeta),
      );
    }
    if (data.containsKey('room_name')) {
      context.handle(
        _roomNameMeta,
        roomName.isAcceptableOrUnknown(data['room_name']!, _roomNameMeta),
      );
    }
    if (data.containsKey('object_type')) {
      context.handle(
        _objectTypeMeta,
        objectType.isAcceptableOrUnknown(data['object_type']!, _objectTypeMeta),
      );
    }
    if (data.containsKey('avatar_version')) {
      context.handle(
        _avatarVersionMeta,
        avatarVersion.isAcceptableOrUnknown(
          data['avatar_version']!,
          _avatarVersionMeta,
        ),
      );
    }
    if (data.containsKey('is_custom_avatar')) {
      context.handle(
        _isCustomAvatarMeta,
        isCustomAvatar.isAcceptableOrUnknown(
          data['is_custom_avatar']!,
          _isCustomAvatarMeta,
        ),
      );
    }
    if (data.containsKey('peer_status')) {
      context.handle(
        _peerStatusMeta,
        peerStatus.isAcceptableOrUnknown(data['peer_status']!, _peerStatusMeta),
      );
    }
    if (data.containsKey('peer_status_icon')) {
      context.handle(
        _peerStatusIconMeta,
        peerStatusIcon.isAcceptableOrUnknown(
          data['peer_status_icon']!,
          _peerStatusIconMeta,
        ),
      );
    }
    if (data.containsKey('peer_status_message')) {
      context.handle(
        _peerStatusMessageMeta,
        peerStatusMessage.isAcceptableOrUnknown(
          data['peer_status_message']!,
          _peerStatusMessageMeta,
        ),
      );
    }
    if (data.containsKey('peer_status_clear_at')) {
      context.handle(
        _peerStatusClearAtMeta,
        peerStatusClearAt.isAcceptableOrUnknown(
          data['peer_status_clear_at']!,
          _peerStatusClearAtMeta,
        ),
      );
    }
    if (data.containsKey('last_message_text')) {
      context.handle(
        _lastMessageTextMeta,
        lastMessageText.isAcceptableOrUnknown(
          data['last_message_text']!,
          _lastMessageTextMeta,
        ),
      );
    }
    if (data.containsKey('last_message_timestamp')) {
      context.handle(
        _lastMessageTimestampMeta,
        lastMessageTimestamp.isAcceptableOrUnknown(
          data['last_message_timestamp']!,
          _lastMessageTimestampMeta,
        ),
      );
    }
    if (data.containsKey('raw_json')) {
      context.handle(
        _rawJsonMeta,
        rawJson.isAcceptableOrUnknown(data['raw_json']!, _rawJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_rawJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, token};
  @override
  CachedConversation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedConversation(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      token: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}token'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      )!,
      lastActivity: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_activity'],
      )!,
      unreadMessages: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}unread_messages'],
      )!,
      favorite: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}favorite'],
      )!,
      isArchived: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_archived'],
      )!,
      readOnly: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}read_only'],
      )!,
      roomType: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}room_type'],
      )!,
      roomName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_name'],
      )!,
      objectType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}object_type'],
      )!,
      avatarVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}avatar_version'],
      )!,
      isCustomAvatar: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_custom_avatar'],
      )!,
      peerStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_status'],
      ),
      peerStatusIcon: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_status_icon'],
      ),
      peerStatusMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_status_message'],
      ),
      peerStatusClearAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}peer_status_clear_at'],
      ),
      lastMessageText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_message_text'],
      ),
      lastMessageTimestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_message_timestamp'],
      ),
      rawJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}raw_json'],
      )!,
    );
  }

  @override
  $CachedConversationsTable createAlias(String alias) {
    return $CachedConversationsTable(attachedDatabase, alias);
  }
}

class CachedConversation extends DataClass
    implements Insertable<CachedConversation> {
  final String accountId;
  final String token;
  final String displayName;
  final String description;
  final int lastActivity;
  final int unreadMessages;
  final bool favorite;
  final bool isArchived;
  final int readOnly;
  final int roomType;
  final String roomName;
  final String objectType;
  final String avatarVersion;
  final bool isCustomAvatar;
  final String? peerStatus;
  final String? peerStatusIcon;
  final String? peerStatusMessage;
  final int? peerStatusClearAt;
  final String? lastMessageText;
  final int? lastMessageTimestamp;
  final String rawJson;
  const CachedConversation({
    required this.accountId,
    required this.token,
    required this.displayName,
    required this.description,
    required this.lastActivity,
    required this.unreadMessages,
    required this.favorite,
    required this.isArchived,
    required this.readOnly,
    required this.roomType,
    required this.roomName,
    required this.objectType,
    required this.avatarVersion,
    required this.isCustomAvatar,
    this.peerStatus,
    this.peerStatusIcon,
    this.peerStatusMessage,
    this.peerStatusClearAt,
    this.lastMessageText,
    this.lastMessageTimestamp,
    required this.rawJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['token'] = Variable<String>(token);
    map['display_name'] = Variable<String>(displayName);
    map['description'] = Variable<String>(description);
    map['last_activity'] = Variable<int>(lastActivity);
    map['unread_messages'] = Variable<int>(unreadMessages);
    map['favorite'] = Variable<bool>(favorite);
    map['is_archived'] = Variable<bool>(isArchived);
    map['read_only'] = Variable<int>(readOnly);
    map['room_type'] = Variable<int>(roomType);
    map['room_name'] = Variable<String>(roomName);
    map['object_type'] = Variable<String>(objectType);
    map['avatar_version'] = Variable<String>(avatarVersion);
    map['is_custom_avatar'] = Variable<bool>(isCustomAvatar);
    if (!nullToAbsent || peerStatus != null) {
      map['peer_status'] = Variable<String>(peerStatus);
    }
    if (!nullToAbsent || peerStatusIcon != null) {
      map['peer_status_icon'] = Variable<String>(peerStatusIcon);
    }
    if (!nullToAbsent || peerStatusMessage != null) {
      map['peer_status_message'] = Variable<String>(peerStatusMessage);
    }
    if (!nullToAbsent || peerStatusClearAt != null) {
      map['peer_status_clear_at'] = Variable<int>(peerStatusClearAt);
    }
    if (!nullToAbsent || lastMessageText != null) {
      map['last_message_text'] = Variable<String>(lastMessageText);
    }
    if (!nullToAbsent || lastMessageTimestamp != null) {
      map['last_message_timestamp'] = Variable<int>(lastMessageTimestamp);
    }
    map['raw_json'] = Variable<String>(rawJson);
    return map;
  }

  CachedConversationsCompanion toCompanion(bool nullToAbsent) {
    return CachedConversationsCompanion(
      accountId: Value(accountId),
      token: Value(token),
      displayName: Value(displayName),
      description: Value(description),
      lastActivity: Value(lastActivity),
      unreadMessages: Value(unreadMessages),
      favorite: Value(favorite),
      isArchived: Value(isArchived),
      readOnly: Value(readOnly),
      roomType: Value(roomType),
      roomName: Value(roomName),
      objectType: Value(objectType),
      avatarVersion: Value(avatarVersion),
      isCustomAvatar: Value(isCustomAvatar),
      peerStatus: peerStatus == null && nullToAbsent
          ? const Value.absent()
          : Value(peerStatus),
      peerStatusIcon: peerStatusIcon == null && nullToAbsent
          ? const Value.absent()
          : Value(peerStatusIcon),
      peerStatusMessage: peerStatusMessage == null && nullToAbsent
          ? const Value.absent()
          : Value(peerStatusMessage),
      peerStatusClearAt: peerStatusClearAt == null && nullToAbsent
          ? const Value.absent()
          : Value(peerStatusClearAt),
      lastMessageText: lastMessageText == null && nullToAbsent
          ? const Value.absent()
          : Value(lastMessageText),
      lastMessageTimestamp: lastMessageTimestamp == null && nullToAbsent
          ? const Value.absent()
          : Value(lastMessageTimestamp),
      rawJson: Value(rawJson),
    );
  }

  factory CachedConversation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedConversation(
      accountId: serializer.fromJson<String>(json['accountId']),
      token: serializer.fromJson<String>(json['token']),
      displayName: serializer.fromJson<String>(json['displayName']),
      description: serializer.fromJson<String>(json['description']),
      lastActivity: serializer.fromJson<int>(json['lastActivity']),
      unreadMessages: serializer.fromJson<int>(json['unreadMessages']),
      favorite: serializer.fromJson<bool>(json['favorite']),
      isArchived: serializer.fromJson<bool>(json['isArchived']),
      readOnly: serializer.fromJson<int>(json['readOnly']),
      roomType: serializer.fromJson<int>(json['roomType']),
      roomName: serializer.fromJson<String>(json['roomName']),
      objectType: serializer.fromJson<String>(json['objectType']),
      avatarVersion: serializer.fromJson<String>(json['avatarVersion']),
      isCustomAvatar: serializer.fromJson<bool>(json['isCustomAvatar']),
      peerStatus: serializer.fromJson<String?>(json['peerStatus']),
      peerStatusIcon: serializer.fromJson<String?>(json['peerStatusIcon']),
      peerStatusMessage: serializer.fromJson<String?>(
        json['peerStatusMessage'],
      ),
      peerStatusClearAt: serializer.fromJson<int?>(json['peerStatusClearAt']),
      lastMessageText: serializer.fromJson<String?>(json['lastMessageText']),
      lastMessageTimestamp: serializer.fromJson<int?>(
        json['lastMessageTimestamp'],
      ),
      rawJson: serializer.fromJson<String>(json['rawJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'token': serializer.toJson<String>(token),
      'displayName': serializer.toJson<String>(displayName),
      'description': serializer.toJson<String>(description),
      'lastActivity': serializer.toJson<int>(lastActivity),
      'unreadMessages': serializer.toJson<int>(unreadMessages),
      'favorite': serializer.toJson<bool>(favorite),
      'isArchived': serializer.toJson<bool>(isArchived),
      'readOnly': serializer.toJson<int>(readOnly),
      'roomType': serializer.toJson<int>(roomType),
      'roomName': serializer.toJson<String>(roomName),
      'objectType': serializer.toJson<String>(objectType),
      'avatarVersion': serializer.toJson<String>(avatarVersion),
      'isCustomAvatar': serializer.toJson<bool>(isCustomAvatar),
      'peerStatus': serializer.toJson<String?>(peerStatus),
      'peerStatusIcon': serializer.toJson<String?>(peerStatusIcon),
      'peerStatusMessage': serializer.toJson<String?>(peerStatusMessage),
      'peerStatusClearAt': serializer.toJson<int?>(peerStatusClearAt),
      'lastMessageText': serializer.toJson<String?>(lastMessageText),
      'lastMessageTimestamp': serializer.toJson<int?>(lastMessageTimestamp),
      'rawJson': serializer.toJson<String>(rawJson),
    };
  }

  CachedConversation copyWith({
    String? accountId,
    String? token,
    String? displayName,
    String? description,
    int? lastActivity,
    int? unreadMessages,
    bool? favorite,
    bool? isArchived,
    int? readOnly,
    int? roomType,
    String? roomName,
    String? objectType,
    String? avatarVersion,
    bool? isCustomAvatar,
    Value<String?> peerStatus = const Value.absent(),
    Value<String?> peerStatusIcon = const Value.absent(),
    Value<String?> peerStatusMessage = const Value.absent(),
    Value<int?> peerStatusClearAt = const Value.absent(),
    Value<String?> lastMessageText = const Value.absent(),
    Value<int?> lastMessageTimestamp = const Value.absent(),
    String? rawJson,
  }) => CachedConversation(
    accountId: accountId ?? this.accountId,
    token: token ?? this.token,
    displayName: displayName ?? this.displayName,
    description: description ?? this.description,
    lastActivity: lastActivity ?? this.lastActivity,
    unreadMessages: unreadMessages ?? this.unreadMessages,
    favorite: favorite ?? this.favorite,
    isArchived: isArchived ?? this.isArchived,
    readOnly: readOnly ?? this.readOnly,
    roomType: roomType ?? this.roomType,
    roomName: roomName ?? this.roomName,
    objectType: objectType ?? this.objectType,
    avatarVersion: avatarVersion ?? this.avatarVersion,
    isCustomAvatar: isCustomAvatar ?? this.isCustomAvatar,
    peerStatus: peerStatus.present ? peerStatus.value : this.peerStatus,
    peerStatusIcon: peerStatusIcon.present
        ? peerStatusIcon.value
        : this.peerStatusIcon,
    peerStatusMessage: peerStatusMessage.present
        ? peerStatusMessage.value
        : this.peerStatusMessage,
    peerStatusClearAt: peerStatusClearAt.present
        ? peerStatusClearAt.value
        : this.peerStatusClearAt,
    lastMessageText: lastMessageText.present
        ? lastMessageText.value
        : this.lastMessageText,
    lastMessageTimestamp: lastMessageTimestamp.present
        ? lastMessageTimestamp.value
        : this.lastMessageTimestamp,
    rawJson: rawJson ?? this.rawJson,
  );
  CachedConversation copyWithCompanion(CachedConversationsCompanion data) {
    return CachedConversation(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      token: data.token.present ? data.token.value : this.token,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      description: data.description.present
          ? data.description.value
          : this.description,
      lastActivity: data.lastActivity.present
          ? data.lastActivity.value
          : this.lastActivity,
      unreadMessages: data.unreadMessages.present
          ? data.unreadMessages.value
          : this.unreadMessages,
      favorite: data.favorite.present ? data.favorite.value : this.favorite,
      isArchived: data.isArchived.present
          ? data.isArchived.value
          : this.isArchived,
      readOnly: data.readOnly.present ? data.readOnly.value : this.readOnly,
      roomType: data.roomType.present ? data.roomType.value : this.roomType,
      roomName: data.roomName.present ? data.roomName.value : this.roomName,
      objectType: data.objectType.present
          ? data.objectType.value
          : this.objectType,
      avatarVersion: data.avatarVersion.present
          ? data.avatarVersion.value
          : this.avatarVersion,
      isCustomAvatar: data.isCustomAvatar.present
          ? data.isCustomAvatar.value
          : this.isCustomAvatar,
      peerStatus: data.peerStatus.present
          ? data.peerStatus.value
          : this.peerStatus,
      peerStatusIcon: data.peerStatusIcon.present
          ? data.peerStatusIcon.value
          : this.peerStatusIcon,
      peerStatusMessage: data.peerStatusMessage.present
          ? data.peerStatusMessage.value
          : this.peerStatusMessage,
      peerStatusClearAt: data.peerStatusClearAt.present
          ? data.peerStatusClearAt.value
          : this.peerStatusClearAt,
      lastMessageText: data.lastMessageText.present
          ? data.lastMessageText.value
          : this.lastMessageText,
      lastMessageTimestamp: data.lastMessageTimestamp.present
          ? data.lastMessageTimestamp.value
          : this.lastMessageTimestamp,
      rawJson: data.rawJson.present ? data.rawJson.value : this.rawJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedConversation(')
          ..write('accountId: $accountId, ')
          ..write('token: $token, ')
          ..write('displayName: $displayName, ')
          ..write('description: $description, ')
          ..write('lastActivity: $lastActivity, ')
          ..write('unreadMessages: $unreadMessages, ')
          ..write('favorite: $favorite, ')
          ..write('isArchived: $isArchived, ')
          ..write('readOnly: $readOnly, ')
          ..write('roomType: $roomType, ')
          ..write('roomName: $roomName, ')
          ..write('objectType: $objectType, ')
          ..write('avatarVersion: $avatarVersion, ')
          ..write('isCustomAvatar: $isCustomAvatar, ')
          ..write('peerStatus: $peerStatus, ')
          ..write('peerStatusIcon: $peerStatusIcon, ')
          ..write('peerStatusMessage: $peerStatusMessage, ')
          ..write('peerStatusClearAt: $peerStatusClearAt, ')
          ..write('lastMessageText: $lastMessageText, ')
          ..write('lastMessageTimestamp: $lastMessageTimestamp, ')
          ..write('rawJson: $rawJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    accountId,
    token,
    displayName,
    description,
    lastActivity,
    unreadMessages,
    favorite,
    isArchived,
    readOnly,
    roomType,
    roomName,
    objectType,
    avatarVersion,
    isCustomAvatar,
    peerStatus,
    peerStatusIcon,
    peerStatusMessage,
    peerStatusClearAt,
    lastMessageText,
    lastMessageTimestamp,
    rawJson,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedConversation &&
          other.accountId == this.accountId &&
          other.token == this.token &&
          other.displayName == this.displayName &&
          other.description == this.description &&
          other.lastActivity == this.lastActivity &&
          other.unreadMessages == this.unreadMessages &&
          other.favorite == this.favorite &&
          other.isArchived == this.isArchived &&
          other.readOnly == this.readOnly &&
          other.roomType == this.roomType &&
          other.roomName == this.roomName &&
          other.objectType == this.objectType &&
          other.avatarVersion == this.avatarVersion &&
          other.isCustomAvatar == this.isCustomAvatar &&
          other.peerStatus == this.peerStatus &&
          other.peerStatusIcon == this.peerStatusIcon &&
          other.peerStatusMessage == this.peerStatusMessage &&
          other.peerStatusClearAt == this.peerStatusClearAt &&
          other.lastMessageText == this.lastMessageText &&
          other.lastMessageTimestamp == this.lastMessageTimestamp &&
          other.rawJson == this.rawJson);
}

class CachedConversationsCompanion extends UpdateCompanion<CachedConversation> {
  final Value<String> accountId;
  final Value<String> token;
  final Value<String> displayName;
  final Value<String> description;
  final Value<int> lastActivity;
  final Value<int> unreadMessages;
  final Value<bool> favorite;
  final Value<bool> isArchived;
  final Value<int> readOnly;
  final Value<int> roomType;
  final Value<String> roomName;
  final Value<String> objectType;
  final Value<String> avatarVersion;
  final Value<bool> isCustomAvatar;
  final Value<String?> peerStatus;
  final Value<String?> peerStatusIcon;
  final Value<String?> peerStatusMessage;
  final Value<int?> peerStatusClearAt;
  final Value<String?> lastMessageText;
  final Value<int?> lastMessageTimestamp;
  final Value<String> rawJson;
  final Value<int> rowid;
  const CachedConversationsCompanion({
    this.accountId = const Value.absent(),
    this.token = const Value.absent(),
    this.displayName = const Value.absent(),
    this.description = const Value.absent(),
    this.lastActivity = const Value.absent(),
    this.unreadMessages = const Value.absent(),
    this.favorite = const Value.absent(),
    this.isArchived = const Value.absent(),
    this.readOnly = const Value.absent(),
    this.roomType = const Value.absent(),
    this.roomName = const Value.absent(),
    this.objectType = const Value.absent(),
    this.avatarVersion = const Value.absent(),
    this.isCustomAvatar = const Value.absent(),
    this.peerStatus = const Value.absent(),
    this.peerStatusIcon = const Value.absent(),
    this.peerStatusMessage = const Value.absent(),
    this.peerStatusClearAt = const Value.absent(),
    this.lastMessageText = const Value.absent(),
    this.lastMessageTimestamp = const Value.absent(),
    this.rawJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedConversationsCompanion.insert({
    required String accountId,
    required String token,
    required String displayName,
    required String description,
    required int lastActivity,
    required int unreadMessages,
    required bool favorite,
    this.isArchived = const Value.absent(),
    this.readOnly = const Value.absent(),
    this.roomType = const Value.absent(),
    this.roomName = const Value.absent(),
    this.objectType = const Value.absent(),
    this.avatarVersion = const Value.absent(),
    this.isCustomAvatar = const Value.absent(),
    this.peerStatus = const Value.absent(),
    this.peerStatusIcon = const Value.absent(),
    this.peerStatusMessage = const Value.absent(),
    this.peerStatusClearAt = const Value.absent(),
    this.lastMessageText = const Value.absent(),
    this.lastMessageTimestamp = const Value.absent(),
    required String rawJson,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       token = Value(token),
       displayName = Value(displayName),
       description = Value(description),
       lastActivity = Value(lastActivity),
       unreadMessages = Value(unreadMessages),
       favorite = Value(favorite),
       rawJson = Value(rawJson);
  static Insertable<CachedConversation> custom({
    Expression<String>? accountId,
    Expression<String>? token,
    Expression<String>? displayName,
    Expression<String>? description,
    Expression<int>? lastActivity,
    Expression<int>? unreadMessages,
    Expression<bool>? favorite,
    Expression<bool>? isArchived,
    Expression<int>? readOnly,
    Expression<int>? roomType,
    Expression<String>? roomName,
    Expression<String>? objectType,
    Expression<String>? avatarVersion,
    Expression<bool>? isCustomAvatar,
    Expression<String>? peerStatus,
    Expression<String>? peerStatusIcon,
    Expression<String>? peerStatusMessage,
    Expression<int>? peerStatusClearAt,
    Expression<String>? lastMessageText,
    Expression<int>? lastMessageTimestamp,
    Expression<String>? rawJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (token != null) 'token': token,
      if (displayName != null) 'display_name': displayName,
      if (description != null) 'description': description,
      if (lastActivity != null) 'last_activity': lastActivity,
      if (unreadMessages != null) 'unread_messages': unreadMessages,
      if (favorite != null) 'favorite': favorite,
      if (isArchived != null) 'is_archived': isArchived,
      if (readOnly != null) 'read_only': readOnly,
      if (roomType != null) 'room_type': roomType,
      if (roomName != null) 'room_name': roomName,
      if (objectType != null) 'object_type': objectType,
      if (avatarVersion != null) 'avatar_version': avatarVersion,
      if (isCustomAvatar != null) 'is_custom_avatar': isCustomAvatar,
      if (peerStatus != null) 'peer_status': peerStatus,
      if (peerStatusIcon != null) 'peer_status_icon': peerStatusIcon,
      if (peerStatusMessage != null) 'peer_status_message': peerStatusMessage,
      if (peerStatusClearAt != null) 'peer_status_clear_at': peerStatusClearAt,
      if (lastMessageText != null) 'last_message_text': lastMessageText,
      if (lastMessageTimestamp != null)
        'last_message_timestamp': lastMessageTimestamp,
      if (rawJson != null) 'raw_json': rawJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedConversationsCompanion copyWith({
    Value<String>? accountId,
    Value<String>? token,
    Value<String>? displayName,
    Value<String>? description,
    Value<int>? lastActivity,
    Value<int>? unreadMessages,
    Value<bool>? favorite,
    Value<bool>? isArchived,
    Value<int>? readOnly,
    Value<int>? roomType,
    Value<String>? roomName,
    Value<String>? objectType,
    Value<String>? avatarVersion,
    Value<bool>? isCustomAvatar,
    Value<String?>? peerStatus,
    Value<String?>? peerStatusIcon,
    Value<String?>? peerStatusMessage,
    Value<int?>? peerStatusClearAt,
    Value<String?>? lastMessageText,
    Value<int?>? lastMessageTimestamp,
    Value<String>? rawJson,
    Value<int>? rowid,
  }) {
    return CachedConversationsCompanion(
      accountId: accountId ?? this.accountId,
      token: token ?? this.token,
      displayName: displayName ?? this.displayName,
      description: description ?? this.description,
      lastActivity: lastActivity ?? this.lastActivity,
      unreadMessages: unreadMessages ?? this.unreadMessages,
      favorite: favorite ?? this.favorite,
      isArchived: isArchived ?? this.isArchived,
      readOnly: readOnly ?? this.readOnly,
      roomType: roomType ?? this.roomType,
      roomName: roomName ?? this.roomName,
      objectType: objectType ?? this.objectType,
      avatarVersion: avatarVersion ?? this.avatarVersion,
      isCustomAvatar: isCustomAvatar ?? this.isCustomAvatar,
      peerStatus: peerStatus ?? this.peerStatus,
      peerStatusIcon: peerStatusIcon ?? this.peerStatusIcon,
      peerStatusMessage: peerStatusMessage ?? this.peerStatusMessage,
      peerStatusClearAt: peerStatusClearAt ?? this.peerStatusClearAt,
      lastMessageText: lastMessageText ?? this.lastMessageText,
      lastMessageTimestamp: lastMessageTimestamp ?? this.lastMessageTimestamp,
      rawJson: rawJson ?? this.rawJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (token.present) {
      map['token'] = Variable<String>(token.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (lastActivity.present) {
      map['last_activity'] = Variable<int>(lastActivity.value);
    }
    if (unreadMessages.present) {
      map['unread_messages'] = Variable<int>(unreadMessages.value);
    }
    if (favorite.present) {
      map['favorite'] = Variable<bool>(favorite.value);
    }
    if (isArchived.present) {
      map['is_archived'] = Variable<bool>(isArchived.value);
    }
    if (readOnly.present) {
      map['read_only'] = Variable<int>(readOnly.value);
    }
    if (roomType.present) {
      map['room_type'] = Variable<int>(roomType.value);
    }
    if (roomName.present) {
      map['room_name'] = Variable<String>(roomName.value);
    }
    if (objectType.present) {
      map['object_type'] = Variable<String>(objectType.value);
    }
    if (avatarVersion.present) {
      map['avatar_version'] = Variable<String>(avatarVersion.value);
    }
    if (isCustomAvatar.present) {
      map['is_custom_avatar'] = Variable<bool>(isCustomAvatar.value);
    }
    if (peerStatus.present) {
      map['peer_status'] = Variable<String>(peerStatus.value);
    }
    if (peerStatusIcon.present) {
      map['peer_status_icon'] = Variable<String>(peerStatusIcon.value);
    }
    if (peerStatusMessage.present) {
      map['peer_status_message'] = Variable<String>(peerStatusMessage.value);
    }
    if (peerStatusClearAt.present) {
      map['peer_status_clear_at'] = Variable<int>(peerStatusClearAt.value);
    }
    if (lastMessageText.present) {
      map['last_message_text'] = Variable<String>(lastMessageText.value);
    }
    if (lastMessageTimestamp.present) {
      map['last_message_timestamp'] = Variable<int>(lastMessageTimestamp.value);
    }
    if (rawJson.present) {
      map['raw_json'] = Variable<String>(rawJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedConversationsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('token: $token, ')
          ..write('displayName: $displayName, ')
          ..write('description: $description, ')
          ..write('lastActivity: $lastActivity, ')
          ..write('unreadMessages: $unreadMessages, ')
          ..write('favorite: $favorite, ')
          ..write('isArchived: $isArchived, ')
          ..write('readOnly: $readOnly, ')
          ..write('roomType: $roomType, ')
          ..write('roomName: $roomName, ')
          ..write('objectType: $objectType, ')
          ..write('avatarVersion: $avatarVersion, ')
          ..write('isCustomAvatar: $isCustomAvatar, ')
          ..write('peerStatus: $peerStatus, ')
          ..write('peerStatusIcon: $peerStatusIcon, ')
          ..write('peerStatusMessage: $peerStatusMessage, ')
          ..write('peerStatusClearAt: $peerStatusClearAt, ')
          ..write('lastMessageText: $lastMessageText, ')
          ..write('lastMessageTimestamp: $lastMessageTimestamp, ')
          ..write('rawJson: $rawJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConversationAvatarsTable extends ConversationAvatars
    with TableInfo<$ConversationAvatarsTable, StoredConversationAvatar> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationAvatarsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _cacheKeyMeta = const VerificationMeta(
    'cacheKey',
  );
  @override
  late final GeneratedColumn<String> cacheKey = GeneratedColumn<String>(
    'cache_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<Uint8List> body = GeneratedColumn<Uint8List>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentTypeMeta = const VerificationMeta(
    'contentType',
  );
  @override
  late final GeneratedColumn<String> contentType = GeneratedColumn<String>(
    'content_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isCustomAvatarMeta = const VerificationMeta(
    'isCustomAvatar',
  );
  @override
  late final GeneratedColumn<bool> isCustomAvatar = GeneratedColumn<bool>(
    'is_custom_avatar',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_custom_avatar" IN (0, 1))',
    ),
  );
  static const VerificationMeta _etagMeta = const VerificationMeta('etag');
  @override
  late final GeneratedColumn<String> etag = GeneratedColumn<String>(
    'etag',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastModifiedMeta = const VerificationMeta(
    'lastModified',
  );
  @override
  late final GeneratedColumn<String> lastModified = GeneratedColumn<String>(
    'last_modified',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _expiresAtMillisMeta = const VerificationMeta(
    'expiresAtMillis',
  );
  @override
  late final GeneratedColumn<int> expiresAtMillis = GeneratedColumn<int>(
    'expires_at_millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMillisMeta = const VerificationMeta(
    'updatedAtMillis',
  );
  @override
  late final GeneratedColumn<int> updatedAtMillis = GeneratedColumn<int>(
    'updated_at_millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    cacheKey,
    body,
    contentType,
    isCustomAvatar,
    etag,
    lastModified,
    expiresAtMillis,
    updatedAtMillis,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversation_avatars';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredConversationAvatar> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('cache_key')) {
      context.handle(
        _cacheKeyMeta,
        cacheKey.isAcceptableOrUnknown(data['cache_key']!, _cacheKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_cacheKeyMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('content_type')) {
      context.handle(
        _contentTypeMeta,
        contentType.isAcceptableOrUnknown(
          data['content_type']!,
          _contentTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_contentTypeMeta);
    }
    if (data.containsKey('is_custom_avatar')) {
      context.handle(
        _isCustomAvatarMeta,
        isCustomAvatar.isAcceptableOrUnknown(
          data['is_custom_avatar']!,
          _isCustomAvatarMeta,
        ),
      );
    }
    if (data.containsKey('etag')) {
      context.handle(
        _etagMeta,
        etag.isAcceptableOrUnknown(data['etag']!, _etagMeta),
      );
    }
    if (data.containsKey('last_modified')) {
      context.handle(
        _lastModifiedMeta,
        lastModified.isAcceptableOrUnknown(
          data['last_modified']!,
          _lastModifiedMeta,
        ),
      );
    }
    if (data.containsKey('expires_at_millis')) {
      context.handle(
        _expiresAtMillisMeta,
        expiresAtMillis.isAcceptableOrUnknown(
          data['expires_at_millis']!,
          _expiresAtMillisMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_expiresAtMillisMeta);
    }
    if (data.containsKey('updated_at_millis')) {
      context.handle(
        _updatedAtMillisMeta,
        updatedAtMillis.isAcceptableOrUnknown(
          data['updated_at_millis']!,
          _updatedAtMillisMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMillisMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, cacheKey};
  @override
  StoredConversationAvatar map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredConversationAvatar(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      cacheKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cache_key'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}body'],
      )!,
      contentType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_type'],
      )!,
      isCustomAvatar: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_custom_avatar'],
      ),
      etag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}etag'],
      ),
      lastModified: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_modified'],
      ),
      expiresAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}expires_at_millis'],
      )!,
      updatedAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_millis'],
      )!,
    );
  }

  @override
  $ConversationAvatarsTable createAlias(String alias) {
    return $ConversationAvatarsTable(attachedDatabase, alias);
  }
}

class StoredConversationAvatar extends DataClass
    implements Insertable<StoredConversationAvatar> {
  final String accountId;
  final String cacheKey;
  final Uint8List body;
  final String contentType;
  final bool? isCustomAvatar;
  final String? etag;
  final String? lastModified;
  final int expiresAtMillis;
  final int updatedAtMillis;
  const StoredConversationAvatar({
    required this.accountId,
    required this.cacheKey,
    required this.body,
    required this.contentType,
    this.isCustomAvatar,
    this.etag,
    this.lastModified,
    required this.expiresAtMillis,
    required this.updatedAtMillis,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['cache_key'] = Variable<String>(cacheKey);
    map['body'] = Variable<Uint8List>(body);
    map['content_type'] = Variable<String>(contentType);
    if (!nullToAbsent || isCustomAvatar != null) {
      map['is_custom_avatar'] = Variable<bool>(isCustomAvatar);
    }
    if (!nullToAbsent || etag != null) {
      map['etag'] = Variable<String>(etag);
    }
    if (!nullToAbsent || lastModified != null) {
      map['last_modified'] = Variable<String>(lastModified);
    }
    map['expires_at_millis'] = Variable<int>(expiresAtMillis);
    map['updated_at_millis'] = Variable<int>(updatedAtMillis);
    return map;
  }

  ConversationAvatarsCompanion toCompanion(bool nullToAbsent) {
    return ConversationAvatarsCompanion(
      accountId: Value(accountId),
      cacheKey: Value(cacheKey),
      body: Value(body),
      contentType: Value(contentType),
      isCustomAvatar: isCustomAvatar == null && nullToAbsent
          ? const Value.absent()
          : Value(isCustomAvatar),
      etag: etag == null && nullToAbsent ? const Value.absent() : Value(etag),
      lastModified: lastModified == null && nullToAbsent
          ? const Value.absent()
          : Value(lastModified),
      expiresAtMillis: Value(expiresAtMillis),
      updatedAtMillis: Value(updatedAtMillis),
    );
  }

  factory StoredConversationAvatar.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredConversationAvatar(
      accountId: serializer.fromJson<String>(json['accountId']),
      cacheKey: serializer.fromJson<String>(json['cacheKey']),
      body: serializer.fromJson<Uint8List>(json['body']),
      contentType: serializer.fromJson<String>(json['contentType']),
      isCustomAvatar: serializer.fromJson<bool?>(json['isCustomAvatar']),
      etag: serializer.fromJson<String?>(json['etag']),
      lastModified: serializer.fromJson<String?>(json['lastModified']),
      expiresAtMillis: serializer.fromJson<int>(json['expiresAtMillis']),
      updatedAtMillis: serializer.fromJson<int>(json['updatedAtMillis']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'cacheKey': serializer.toJson<String>(cacheKey),
      'body': serializer.toJson<Uint8List>(body),
      'contentType': serializer.toJson<String>(contentType),
      'isCustomAvatar': serializer.toJson<bool?>(isCustomAvatar),
      'etag': serializer.toJson<String?>(etag),
      'lastModified': serializer.toJson<String?>(lastModified),
      'expiresAtMillis': serializer.toJson<int>(expiresAtMillis),
      'updatedAtMillis': serializer.toJson<int>(updatedAtMillis),
    };
  }

  StoredConversationAvatar copyWith({
    String? accountId,
    String? cacheKey,
    Uint8List? body,
    String? contentType,
    Value<bool?> isCustomAvatar = const Value.absent(),
    Value<String?> etag = const Value.absent(),
    Value<String?> lastModified = const Value.absent(),
    int? expiresAtMillis,
    int? updatedAtMillis,
  }) => StoredConversationAvatar(
    accountId: accountId ?? this.accountId,
    cacheKey: cacheKey ?? this.cacheKey,
    body: body ?? this.body,
    contentType: contentType ?? this.contentType,
    isCustomAvatar: isCustomAvatar.present
        ? isCustomAvatar.value
        : this.isCustomAvatar,
    etag: etag.present ? etag.value : this.etag,
    lastModified: lastModified.present ? lastModified.value : this.lastModified,
    expiresAtMillis: expiresAtMillis ?? this.expiresAtMillis,
    updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
  );
  StoredConversationAvatar copyWithCompanion(
    ConversationAvatarsCompanion data,
  ) {
    return StoredConversationAvatar(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      cacheKey: data.cacheKey.present ? data.cacheKey.value : this.cacheKey,
      body: data.body.present ? data.body.value : this.body,
      contentType: data.contentType.present
          ? data.contentType.value
          : this.contentType,
      isCustomAvatar: data.isCustomAvatar.present
          ? data.isCustomAvatar.value
          : this.isCustomAvatar,
      etag: data.etag.present ? data.etag.value : this.etag,
      lastModified: data.lastModified.present
          ? data.lastModified.value
          : this.lastModified,
      expiresAtMillis: data.expiresAtMillis.present
          ? data.expiresAtMillis.value
          : this.expiresAtMillis,
      updatedAtMillis: data.updatedAtMillis.present
          ? data.updatedAtMillis.value
          : this.updatedAtMillis,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredConversationAvatar(')
          ..write('accountId: $accountId, ')
          ..write('cacheKey: $cacheKey, ')
          ..write('body: $body, ')
          ..write('contentType: $contentType, ')
          ..write('isCustomAvatar: $isCustomAvatar, ')
          ..write('etag: $etag, ')
          ..write('lastModified: $lastModified, ')
          ..write('expiresAtMillis: $expiresAtMillis, ')
          ..write('updatedAtMillis: $updatedAtMillis')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    cacheKey,
    $driftBlobEquality.hash(body),
    contentType,
    isCustomAvatar,
    etag,
    lastModified,
    expiresAtMillis,
    updatedAtMillis,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredConversationAvatar &&
          other.accountId == this.accountId &&
          other.cacheKey == this.cacheKey &&
          $driftBlobEquality.equals(other.body, this.body) &&
          other.contentType == this.contentType &&
          other.isCustomAvatar == this.isCustomAvatar &&
          other.etag == this.etag &&
          other.lastModified == this.lastModified &&
          other.expiresAtMillis == this.expiresAtMillis &&
          other.updatedAtMillis == this.updatedAtMillis);
}

class ConversationAvatarsCompanion
    extends UpdateCompanion<StoredConversationAvatar> {
  final Value<String> accountId;
  final Value<String> cacheKey;
  final Value<Uint8List> body;
  final Value<String> contentType;
  final Value<bool?> isCustomAvatar;
  final Value<String?> etag;
  final Value<String?> lastModified;
  final Value<int> expiresAtMillis;
  final Value<int> updatedAtMillis;
  final Value<int> rowid;
  const ConversationAvatarsCompanion({
    this.accountId = const Value.absent(),
    this.cacheKey = const Value.absent(),
    this.body = const Value.absent(),
    this.contentType = const Value.absent(),
    this.isCustomAvatar = const Value.absent(),
    this.etag = const Value.absent(),
    this.lastModified = const Value.absent(),
    this.expiresAtMillis = const Value.absent(),
    this.updatedAtMillis = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationAvatarsCompanion.insert({
    required String accountId,
    required String cacheKey,
    required Uint8List body,
    required String contentType,
    this.isCustomAvatar = const Value.absent(),
    this.etag = const Value.absent(),
    this.lastModified = const Value.absent(),
    required int expiresAtMillis,
    required int updatedAtMillis,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       cacheKey = Value(cacheKey),
       body = Value(body),
       contentType = Value(contentType),
       expiresAtMillis = Value(expiresAtMillis),
       updatedAtMillis = Value(updatedAtMillis);
  static Insertable<StoredConversationAvatar> custom({
    Expression<String>? accountId,
    Expression<String>? cacheKey,
    Expression<Uint8List>? body,
    Expression<String>? contentType,
    Expression<bool>? isCustomAvatar,
    Expression<String>? etag,
    Expression<String>? lastModified,
    Expression<int>? expiresAtMillis,
    Expression<int>? updatedAtMillis,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (cacheKey != null) 'cache_key': cacheKey,
      if (body != null) 'body': body,
      if (contentType != null) 'content_type': contentType,
      if (isCustomAvatar != null) 'is_custom_avatar': isCustomAvatar,
      if (etag != null) 'etag': etag,
      if (lastModified != null) 'last_modified': lastModified,
      if (expiresAtMillis != null) 'expires_at_millis': expiresAtMillis,
      if (updatedAtMillis != null) 'updated_at_millis': updatedAtMillis,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationAvatarsCompanion copyWith({
    Value<String>? accountId,
    Value<String>? cacheKey,
    Value<Uint8List>? body,
    Value<String>? contentType,
    Value<bool?>? isCustomAvatar,
    Value<String?>? etag,
    Value<String?>? lastModified,
    Value<int>? expiresAtMillis,
    Value<int>? updatedAtMillis,
    Value<int>? rowid,
  }) {
    return ConversationAvatarsCompanion(
      accountId: accountId ?? this.accountId,
      cacheKey: cacheKey ?? this.cacheKey,
      body: body ?? this.body,
      contentType: contentType ?? this.contentType,
      isCustomAvatar: isCustomAvatar ?? this.isCustomAvatar,
      etag: etag ?? this.etag,
      lastModified: lastModified ?? this.lastModified,
      expiresAtMillis: expiresAtMillis ?? this.expiresAtMillis,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (cacheKey.present) {
      map['cache_key'] = Variable<String>(cacheKey.value);
    }
    if (body.present) {
      map['body'] = Variable<Uint8List>(body.value);
    }
    if (contentType.present) {
      map['content_type'] = Variable<String>(contentType.value);
    }
    if (isCustomAvatar.present) {
      map['is_custom_avatar'] = Variable<bool>(isCustomAvatar.value);
    }
    if (etag.present) {
      map['etag'] = Variable<String>(etag.value);
    }
    if (lastModified.present) {
      map['last_modified'] = Variable<String>(lastModified.value);
    }
    if (expiresAtMillis.present) {
      map['expires_at_millis'] = Variable<int>(expiresAtMillis.value);
    }
    if (updatedAtMillis.present) {
      map['updated_at_millis'] = Variable<int>(updatedAtMillis.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationAvatarsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('cacheKey: $cacheKey, ')
          ..write('body: $body, ')
          ..write('contentType: $contentType, ')
          ..write('isCustomAvatar: $isCustomAvatar, ')
          ..write('etag: $etag, ')
          ..write('lastModified: $lastModified, ')
          ..write('expiresAtMillis: $expiresAtMillis, ')
          ..write('updatedAtMillis: $updatedAtMillis, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ChatCapabilitiesTable extends ChatCapabilities
    with TableInfo<$ChatCapabilitiesTable, StoredChatCapability> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatCapabilitiesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _fingerprintMeta = const VerificationMeta(
    'fingerprint',
  );
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
    'fingerprint',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _credentialGenerationMeta =
      const VerificationMeta('credentialGeneration');
  @override
  late final GeneratedColumn<int> credentialGeneration = GeneratedColumn<int>(
    'credential_generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _laneMeta = const VerificationMeta('lane');
  @override
  late final GeneratedColumn<String> lane = GeneratedColumn<String>(
    'lane',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('ready'),
  );
  static const VerificationMeta _updatedAtMillisMeta = const VerificationMeta(
    'updatedAtMillis',
  );
  @override
  late final GeneratedColumn<int> updatedAtMillis = GeneratedColumn<int>(
    'updated_at_millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    fingerprint,
    generation,
    credentialGeneration,
    lane,
    updatedAtMillis,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_capabilities';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredChatCapability> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('fingerprint')) {
      context.handle(
        _fingerprintMeta,
        fingerprint.isAcceptableOrUnknown(
          data['fingerprint']!,
          _fingerprintMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_fingerprintMeta);
    }
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    }
    if (data.containsKey('credential_generation')) {
      context.handle(
        _credentialGenerationMeta,
        credentialGeneration.isAcceptableOrUnknown(
          data['credential_generation']!,
          _credentialGenerationMeta,
        ),
      );
    }
    if (data.containsKey('lane')) {
      context.handle(
        _laneMeta,
        lane.isAcceptableOrUnknown(data['lane']!, _laneMeta),
      );
    }
    if (data.containsKey('updated_at_millis')) {
      context.handle(
        _updatedAtMillisMeta,
        updatedAtMillis.isAcceptableOrUnknown(
          data['updated_at_millis']!,
          _updatedAtMillisMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMillisMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId};
  @override
  StoredChatCapability map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredChatCapability(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      fingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fingerprint'],
      )!,
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      credentialGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}credential_generation'],
      )!,
      lane: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}lane'],
      )!,
      updatedAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_millis'],
      )!,
    );
  }

  @override
  $ChatCapabilitiesTable createAlias(String alias) {
    return $ChatCapabilitiesTable(attachedDatabase, alias);
  }
}

class StoredChatCapability extends DataClass
    implements Insertable<StoredChatCapability> {
  final String accountId;
  final String fingerprint;
  final int generation;
  final int credentialGeneration;
  final String lane;
  final int updatedAtMillis;
  const StoredChatCapability({
    required this.accountId,
    required this.fingerprint,
    required this.generation,
    required this.credentialGeneration,
    required this.lane,
    required this.updatedAtMillis,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['fingerprint'] = Variable<String>(fingerprint);
    map['generation'] = Variable<int>(generation);
    map['credential_generation'] = Variable<int>(credentialGeneration);
    map['lane'] = Variable<String>(lane);
    map['updated_at_millis'] = Variable<int>(updatedAtMillis);
    return map;
  }

  ChatCapabilitiesCompanion toCompanion(bool nullToAbsent) {
    return ChatCapabilitiesCompanion(
      accountId: Value(accountId),
      fingerprint: Value(fingerprint),
      generation: Value(generation),
      credentialGeneration: Value(credentialGeneration),
      lane: Value(lane),
      updatedAtMillis: Value(updatedAtMillis),
    );
  }

  factory StoredChatCapability.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredChatCapability(
      accountId: serializer.fromJson<String>(json['accountId']),
      fingerprint: serializer.fromJson<String>(json['fingerprint']),
      generation: serializer.fromJson<int>(json['generation']),
      credentialGeneration: serializer.fromJson<int>(
        json['credentialGeneration'],
      ),
      lane: serializer.fromJson<String>(json['lane']),
      updatedAtMillis: serializer.fromJson<int>(json['updatedAtMillis']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'fingerprint': serializer.toJson<String>(fingerprint),
      'generation': serializer.toJson<int>(generation),
      'credentialGeneration': serializer.toJson<int>(credentialGeneration),
      'lane': serializer.toJson<String>(lane),
      'updatedAtMillis': serializer.toJson<int>(updatedAtMillis),
    };
  }

  StoredChatCapability copyWith({
    String? accountId,
    String? fingerprint,
    int? generation,
    int? credentialGeneration,
    String? lane,
    int? updatedAtMillis,
  }) => StoredChatCapability(
    accountId: accountId ?? this.accountId,
    fingerprint: fingerprint ?? this.fingerprint,
    generation: generation ?? this.generation,
    credentialGeneration: credentialGeneration ?? this.credentialGeneration,
    lane: lane ?? this.lane,
    updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
  );
  StoredChatCapability copyWithCompanion(ChatCapabilitiesCompanion data) {
    return StoredChatCapability(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      fingerprint: data.fingerprint.present
          ? data.fingerprint.value
          : this.fingerprint,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      credentialGeneration: data.credentialGeneration.present
          ? data.credentialGeneration.value
          : this.credentialGeneration,
      lane: data.lane.present ? data.lane.value : this.lane,
      updatedAtMillis: data.updatedAtMillis.present
          ? data.updatedAtMillis.value
          : this.updatedAtMillis,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredChatCapability(')
          ..write('accountId: $accountId, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('generation: $generation, ')
          ..write('credentialGeneration: $credentialGeneration, ')
          ..write('lane: $lane, ')
          ..write('updatedAtMillis: $updatedAtMillis')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    fingerprint,
    generation,
    credentialGeneration,
    lane,
    updatedAtMillis,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredChatCapability &&
          other.accountId == this.accountId &&
          other.fingerprint == this.fingerprint &&
          other.generation == this.generation &&
          other.credentialGeneration == this.credentialGeneration &&
          other.lane == this.lane &&
          other.updatedAtMillis == this.updatedAtMillis);
}

class ChatCapabilitiesCompanion extends UpdateCompanion<StoredChatCapability> {
  final Value<String> accountId;
  final Value<String> fingerprint;
  final Value<int> generation;
  final Value<int> credentialGeneration;
  final Value<String> lane;
  final Value<int> updatedAtMillis;
  final Value<int> rowid;
  const ChatCapabilitiesCompanion({
    this.accountId = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.generation = const Value.absent(),
    this.credentialGeneration = const Value.absent(),
    this.lane = const Value.absent(),
    this.updatedAtMillis = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChatCapabilitiesCompanion.insert({
    required String accountId,
    required String fingerprint,
    this.generation = const Value.absent(),
    this.credentialGeneration = const Value.absent(),
    this.lane = const Value.absent(),
    required int updatedAtMillis,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       fingerprint = Value(fingerprint),
       updatedAtMillis = Value(updatedAtMillis);
  static Insertable<StoredChatCapability> custom({
    Expression<String>? accountId,
    Expression<String>? fingerprint,
    Expression<int>? generation,
    Expression<int>? credentialGeneration,
    Expression<String>? lane,
    Expression<int>? updatedAtMillis,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (generation != null) 'generation': generation,
      if (credentialGeneration != null)
        'credential_generation': credentialGeneration,
      if (lane != null) 'lane': lane,
      if (updatedAtMillis != null) 'updated_at_millis': updatedAtMillis,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChatCapabilitiesCompanion copyWith({
    Value<String>? accountId,
    Value<String>? fingerprint,
    Value<int>? generation,
    Value<int>? credentialGeneration,
    Value<String>? lane,
    Value<int>? updatedAtMillis,
    Value<int>? rowid,
  }) {
    return ChatCapabilitiesCompanion(
      accountId: accountId ?? this.accountId,
      fingerprint: fingerprint ?? this.fingerprint,
      generation: generation ?? this.generation,
      credentialGeneration: credentialGeneration ?? this.credentialGeneration,
      lane: lane ?? this.lane,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (credentialGeneration.present) {
      map['credential_generation'] = Variable<int>(credentialGeneration.value);
    }
    if (lane.present) {
      map['lane'] = Variable<String>(lane.value);
    }
    if (updatedAtMillis.present) {
      map['updated_at_millis'] = Variable<int>(updatedAtMillis.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatCapabilitiesCompanion(')
          ..write('accountId: $accountId, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('generation: $generation, ')
          ..write('credentialGeneration: $credentialGeneration, ')
          ..write('lane: $lane, ')
          ..write('updatedAtMillis: $updatedAtMillis, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ChatScopesTable extends ChatScopes
    with TableInfo<$ChatScopesTable, StoredChatScope> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatScopesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _roomTokenMeta = const VerificationMeta(
    'roomToken',
  );
  @override
  late final GeneratedColumn<String> roomToken = GeneratedColumn<String>(
    'room_token',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scopeKeyMeta = const VerificationMeta(
    'scopeKey',
  );
  @override
  late final GeneratedColumn<String> scopeKey = GeneratedColumn<String>(
    'scope_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _threadIdMeta = const VerificationMeta(
    'threadId',
  );
  @override
  late final GeneratedColumn<int> threadId = GeneratedColumn<int>(
    'thread_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _historyCursorMeta = const VerificationMeta(
    'historyCursor',
  );
  @override
  late final GeneratedColumn<String> historyCursor = GeneratedColumn<String>(
    'history_cursor',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _futureCursorMeta = const VerificationMeta(
    'futureCursor',
  );
  @override
  late final GeneratedColumn<String> futureCursor = GeneratedColumn<String>(
    'future_cursor',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastCommonReadMeta = const VerificationMeta(
    'lastCommonRead',
  );
  @override
  late final GeneratedColumn<String> lastCommonRead = GeneratedColumn<String>(
    'last_common_read',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastReadMessageMeta = const VerificationMeta(
    'lastReadMessage',
  );
  @override
  late final GeneratedColumn<int> lastReadMessage = GeneratedColumn<int>(
    'last_read_message',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _unreadMessagesMeta = const VerificationMeta(
    'unreadMessages',
  );
  @override
  late final GeneratedColumn<int> unreadMessages = GeneratedColumn<int>(
    'unread_messages',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hasHistoryMeta = const VerificationMeta(
    'hasHistory',
  );
  @override
  late final GeneratedColumn<bool> hasHistory = GeneratedColumn<bool>(
    'has_history',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("has_history" IN (0, 1))',
    ),
  );
  static const VerificationMeta _futureConvergedMeta = const VerificationMeta(
    'futureConverged',
  );
  @override
  late final GeneratedColumn<bool> futureConverged = GeneratedColumn<bool>(
    'future_converged',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("future_converged" IN (0, 1))',
    ),
  );
  static const VerificationMeta _blocksJsonMeta = const VerificationMeta(
    'blocksJson',
  );
  @override
  late final GeneratedColumn<String> blocksJson = GeneratedColumn<String>(
    'blocks_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastSyncedAtMillisMeta =
      const VerificationMeta('lastSyncedAtMillis');
  @override
  late final GeneratedColumn<int> lastSyncedAtMillis = GeneratedColumn<int>(
    'last_synced_at_millis',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastSyncErrorMeta = const VerificationMeta(
    'lastSyncError',
  );
  @override
  late final GeneratedColumn<String> lastSyncError = GeneratedColumn<String>(
    'last_sync_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    roomToken,
    scopeKey,
    threadId,
    historyCursor,
    futureCursor,
    lastCommonRead,
    lastReadMessage,
    unreadMessages,
    hasHistory,
    futureConverged,
    blocksJson,
    lastSyncedAtMillis,
    lastSyncError,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_scopes';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredChatScope> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('room_token')) {
      context.handle(
        _roomTokenMeta,
        roomToken.isAcceptableOrUnknown(data['room_token']!, _roomTokenMeta),
      );
    } else if (isInserting) {
      context.missing(_roomTokenMeta);
    }
    if (data.containsKey('scope_key')) {
      context.handle(
        _scopeKeyMeta,
        scopeKey.isAcceptableOrUnknown(data['scope_key']!, _scopeKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_scopeKeyMeta);
    }
    if (data.containsKey('thread_id')) {
      context.handle(
        _threadIdMeta,
        threadId.isAcceptableOrUnknown(data['thread_id']!, _threadIdMeta),
      );
    }
    if (data.containsKey('history_cursor')) {
      context.handle(
        _historyCursorMeta,
        historyCursor.isAcceptableOrUnknown(
          data['history_cursor']!,
          _historyCursorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_historyCursorMeta);
    }
    if (data.containsKey('future_cursor')) {
      context.handle(
        _futureCursorMeta,
        futureCursor.isAcceptableOrUnknown(
          data['future_cursor']!,
          _futureCursorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_futureCursorMeta);
    }
    if (data.containsKey('last_common_read')) {
      context.handle(
        _lastCommonReadMeta,
        lastCommonRead.isAcceptableOrUnknown(
          data['last_common_read']!,
          _lastCommonReadMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastCommonReadMeta);
    }
    if (data.containsKey('last_read_message')) {
      context.handle(
        _lastReadMessageMeta,
        lastReadMessage.isAcceptableOrUnknown(
          data['last_read_message']!,
          _lastReadMessageMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastReadMessageMeta);
    }
    if (data.containsKey('unread_messages')) {
      context.handle(
        _unreadMessagesMeta,
        unreadMessages.isAcceptableOrUnknown(
          data['unread_messages']!,
          _unreadMessagesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_unreadMessagesMeta);
    }
    if (data.containsKey('has_history')) {
      context.handle(
        _hasHistoryMeta,
        hasHistory.isAcceptableOrUnknown(data['has_history']!, _hasHistoryMeta),
      );
    } else if (isInserting) {
      context.missing(_hasHistoryMeta);
    }
    if (data.containsKey('future_converged')) {
      context.handle(
        _futureConvergedMeta,
        futureConverged.isAcceptableOrUnknown(
          data['future_converged']!,
          _futureConvergedMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_futureConvergedMeta);
    }
    if (data.containsKey('blocks_json')) {
      context.handle(
        _blocksJsonMeta,
        blocksJson.isAcceptableOrUnknown(data['blocks_json']!, _blocksJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_blocksJsonMeta);
    }
    if (data.containsKey('last_synced_at_millis')) {
      context.handle(
        _lastSyncedAtMillisMeta,
        lastSyncedAtMillis.isAcceptableOrUnknown(
          data['last_synced_at_millis']!,
          _lastSyncedAtMillisMeta,
        ),
      );
    }
    if (data.containsKey('last_sync_error')) {
      context.handle(
        _lastSyncErrorMeta,
        lastSyncError.isAcceptableOrUnknown(
          data['last_sync_error']!,
          _lastSyncErrorMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, roomToken, scopeKey};
  @override
  StoredChatScope map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredChatScope(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      roomToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_token'],
      )!,
      scopeKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope_key'],
      )!,
      threadId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}thread_id'],
      ),
      historyCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}history_cursor'],
      )!,
      futureCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}future_cursor'],
      )!,
      lastCommonRead: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_common_read'],
      )!,
      lastReadMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_read_message'],
      )!,
      unreadMessages: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}unread_messages'],
      )!,
      hasHistory: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}has_history'],
      )!,
      futureConverged: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}future_converged'],
      )!,
      blocksJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}blocks_json'],
      )!,
      lastSyncedAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_synced_at_millis'],
      ),
      lastSyncError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_sync_error'],
      ),
    );
  }

  @override
  $ChatScopesTable createAlias(String alias) {
    return $ChatScopesTable(attachedDatabase, alias);
  }
}

class StoredChatScope extends DataClass implements Insertable<StoredChatScope> {
  final String accountId;
  final String roomToken;
  final String scopeKey;
  final int? threadId;
  final String historyCursor;
  final String futureCursor;
  final String lastCommonRead;
  final int lastReadMessage;
  final int unreadMessages;
  final bool hasHistory;
  final bool futureConverged;
  final String blocksJson;
  final int? lastSyncedAtMillis;
  final String? lastSyncError;
  const StoredChatScope({
    required this.accountId,
    required this.roomToken,
    required this.scopeKey,
    this.threadId,
    required this.historyCursor,
    required this.futureCursor,
    required this.lastCommonRead,
    required this.lastReadMessage,
    required this.unreadMessages,
    required this.hasHistory,
    required this.futureConverged,
    required this.blocksJson,
    this.lastSyncedAtMillis,
    this.lastSyncError,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['room_token'] = Variable<String>(roomToken);
    map['scope_key'] = Variable<String>(scopeKey);
    if (!nullToAbsent || threadId != null) {
      map['thread_id'] = Variable<int>(threadId);
    }
    map['history_cursor'] = Variable<String>(historyCursor);
    map['future_cursor'] = Variable<String>(futureCursor);
    map['last_common_read'] = Variable<String>(lastCommonRead);
    map['last_read_message'] = Variable<int>(lastReadMessage);
    map['unread_messages'] = Variable<int>(unreadMessages);
    map['has_history'] = Variable<bool>(hasHistory);
    map['future_converged'] = Variable<bool>(futureConverged);
    map['blocks_json'] = Variable<String>(blocksJson);
    if (!nullToAbsent || lastSyncedAtMillis != null) {
      map['last_synced_at_millis'] = Variable<int>(lastSyncedAtMillis);
    }
    if (!nullToAbsent || lastSyncError != null) {
      map['last_sync_error'] = Variable<String>(lastSyncError);
    }
    return map;
  }

  ChatScopesCompanion toCompanion(bool nullToAbsent) {
    return ChatScopesCompanion(
      accountId: Value(accountId),
      roomToken: Value(roomToken),
      scopeKey: Value(scopeKey),
      threadId: threadId == null && nullToAbsent
          ? const Value.absent()
          : Value(threadId),
      historyCursor: Value(historyCursor),
      futureCursor: Value(futureCursor),
      lastCommonRead: Value(lastCommonRead),
      lastReadMessage: Value(lastReadMessage),
      unreadMessages: Value(unreadMessages),
      hasHistory: Value(hasHistory),
      futureConverged: Value(futureConverged),
      blocksJson: Value(blocksJson),
      lastSyncedAtMillis: lastSyncedAtMillis == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSyncedAtMillis),
      lastSyncError: lastSyncError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSyncError),
    );
  }

  factory StoredChatScope.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredChatScope(
      accountId: serializer.fromJson<String>(json['accountId']),
      roomToken: serializer.fromJson<String>(json['roomToken']),
      scopeKey: serializer.fromJson<String>(json['scopeKey']),
      threadId: serializer.fromJson<int?>(json['threadId']),
      historyCursor: serializer.fromJson<String>(json['historyCursor']),
      futureCursor: serializer.fromJson<String>(json['futureCursor']),
      lastCommonRead: serializer.fromJson<String>(json['lastCommonRead']),
      lastReadMessage: serializer.fromJson<int>(json['lastReadMessage']),
      unreadMessages: serializer.fromJson<int>(json['unreadMessages']),
      hasHistory: serializer.fromJson<bool>(json['hasHistory']),
      futureConverged: serializer.fromJson<bool>(json['futureConverged']),
      blocksJson: serializer.fromJson<String>(json['blocksJson']),
      lastSyncedAtMillis: serializer.fromJson<int?>(json['lastSyncedAtMillis']),
      lastSyncError: serializer.fromJson<String?>(json['lastSyncError']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'roomToken': serializer.toJson<String>(roomToken),
      'scopeKey': serializer.toJson<String>(scopeKey),
      'threadId': serializer.toJson<int?>(threadId),
      'historyCursor': serializer.toJson<String>(historyCursor),
      'futureCursor': serializer.toJson<String>(futureCursor),
      'lastCommonRead': serializer.toJson<String>(lastCommonRead),
      'lastReadMessage': serializer.toJson<int>(lastReadMessage),
      'unreadMessages': serializer.toJson<int>(unreadMessages),
      'hasHistory': serializer.toJson<bool>(hasHistory),
      'futureConverged': serializer.toJson<bool>(futureConverged),
      'blocksJson': serializer.toJson<String>(blocksJson),
      'lastSyncedAtMillis': serializer.toJson<int?>(lastSyncedAtMillis),
      'lastSyncError': serializer.toJson<String?>(lastSyncError),
    };
  }

  StoredChatScope copyWith({
    String? accountId,
    String? roomToken,
    String? scopeKey,
    Value<int?> threadId = const Value.absent(),
    String? historyCursor,
    String? futureCursor,
    String? lastCommonRead,
    int? lastReadMessage,
    int? unreadMessages,
    bool? hasHistory,
    bool? futureConverged,
    String? blocksJson,
    Value<int?> lastSyncedAtMillis = const Value.absent(),
    Value<String?> lastSyncError = const Value.absent(),
  }) => StoredChatScope(
    accountId: accountId ?? this.accountId,
    roomToken: roomToken ?? this.roomToken,
    scopeKey: scopeKey ?? this.scopeKey,
    threadId: threadId.present ? threadId.value : this.threadId,
    historyCursor: historyCursor ?? this.historyCursor,
    futureCursor: futureCursor ?? this.futureCursor,
    lastCommonRead: lastCommonRead ?? this.lastCommonRead,
    lastReadMessage: lastReadMessage ?? this.lastReadMessage,
    unreadMessages: unreadMessages ?? this.unreadMessages,
    hasHistory: hasHistory ?? this.hasHistory,
    futureConverged: futureConverged ?? this.futureConverged,
    blocksJson: blocksJson ?? this.blocksJson,
    lastSyncedAtMillis: lastSyncedAtMillis.present
        ? lastSyncedAtMillis.value
        : this.lastSyncedAtMillis,
    lastSyncError: lastSyncError.present
        ? lastSyncError.value
        : this.lastSyncError,
  );
  StoredChatScope copyWithCompanion(ChatScopesCompanion data) {
    return StoredChatScope(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      roomToken: data.roomToken.present ? data.roomToken.value : this.roomToken,
      scopeKey: data.scopeKey.present ? data.scopeKey.value : this.scopeKey,
      threadId: data.threadId.present ? data.threadId.value : this.threadId,
      historyCursor: data.historyCursor.present
          ? data.historyCursor.value
          : this.historyCursor,
      futureCursor: data.futureCursor.present
          ? data.futureCursor.value
          : this.futureCursor,
      lastCommonRead: data.lastCommonRead.present
          ? data.lastCommonRead.value
          : this.lastCommonRead,
      lastReadMessage: data.lastReadMessage.present
          ? data.lastReadMessage.value
          : this.lastReadMessage,
      unreadMessages: data.unreadMessages.present
          ? data.unreadMessages.value
          : this.unreadMessages,
      hasHistory: data.hasHistory.present
          ? data.hasHistory.value
          : this.hasHistory,
      futureConverged: data.futureConverged.present
          ? data.futureConverged.value
          : this.futureConverged,
      blocksJson: data.blocksJson.present
          ? data.blocksJson.value
          : this.blocksJson,
      lastSyncedAtMillis: data.lastSyncedAtMillis.present
          ? data.lastSyncedAtMillis.value
          : this.lastSyncedAtMillis,
      lastSyncError: data.lastSyncError.present
          ? data.lastSyncError.value
          : this.lastSyncError,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredChatScope(')
          ..write('accountId: $accountId, ')
          ..write('roomToken: $roomToken, ')
          ..write('scopeKey: $scopeKey, ')
          ..write('threadId: $threadId, ')
          ..write('historyCursor: $historyCursor, ')
          ..write('futureCursor: $futureCursor, ')
          ..write('lastCommonRead: $lastCommonRead, ')
          ..write('lastReadMessage: $lastReadMessage, ')
          ..write('unreadMessages: $unreadMessages, ')
          ..write('hasHistory: $hasHistory, ')
          ..write('futureConverged: $futureConverged, ')
          ..write('blocksJson: $blocksJson, ')
          ..write('lastSyncedAtMillis: $lastSyncedAtMillis, ')
          ..write('lastSyncError: $lastSyncError')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    roomToken,
    scopeKey,
    threadId,
    historyCursor,
    futureCursor,
    lastCommonRead,
    lastReadMessage,
    unreadMessages,
    hasHistory,
    futureConverged,
    blocksJson,
    lastSyncedAtMillis,
    lastSyncError,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredChatScope &&
          other.accountId == this.accountId &&
          other.roomToken == this.roomToken &&
          other.scopeKey == this.scopeKey &&
          other.threadId == this.threadId &&
          other.historyCursor == this.historyCursor &&
          other.futureCursor == this.futureCursor &&
          other.lastCommonRead == this.lastCommonRead &&
          other.lastReadMessage == this.lastReadMessage &&
          other.unreadMessages == this.unreadMessages &&
          other.hasHistory == this.hasHistory &&
          other.futureConverged == this.futureConverged &&
          other.blocksJson == this.blocksJson &&
          other.lastSyncedAtMillis == this.lastSyncedAtMillis &&
          other.lastSyncError == this.lastSyncError);
}

class ChatScopesCompanion extends UpdateCompanion<StoredChatScope> {
  final Value<String> accountId;
  final Value<String> roomToken;
  final Value<String> scopeKey;
  final Value<int?> threadId;
  final Value<String> historyCursor;
  final Value<String> futureCursor;
  final Value<String> lastCommonRead;
  final Value<int> lastReadMessage;
  final Value<int> unreadMessages;
  final Value<bool> hasHistory;
  final Value<bool> futureConverged;
  final Value<String> blocksJson;
  final Value<int?> lastSyncedAtMillis;
  final Value<String?> lastSyncError;
  final Value<int> rowid;
  const ChatScopesCompanion({
    this.accountId = const Value.absent(),
    this.roomToken = const Value.absent(),
    this.scopeKey = const Value.absent(),
    this.threadId = const Value.absent(),
    this.historyCursor = const Value.absent(),
    this.futureCursor = const Value.absent(),
    this.lastCommonRead = const Value.absent(),
    this.lastReadMessage = const Value.absent(),
    this.unreadMessages = const Value.absent(),
    this.hasHistory = const Value.absent(),
    this.futureConverged = const Value.absent(),
    this.blocksJson = const Value.absent(),
    this.lastSyncedAtMillis = const Value.absent(),
    this.lastSyncError = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChatScopesCompanion.insert({
    required String accountId,
    required String roomToken,
    required String scopeKey,
    this.threadId = const Value.absent(),
    required String historyCursor,
    required String futureCursor,
    required String lastCommonRead,
    required int lastReadMessage,
    required int unreadMessages,
    required bool hasHistory,
    required bool futureConverged,
    required String blocksJson,
    this.lastSyncedAtMillis = const Value.absent(),
    this.lastSyncError = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       roomToken = Value(roomToken),
       scopeKey = Value(scopeKey),
       historyCursor = Value(historyCursor),
       futureCursor = Value(futureCursor),
       lastCommonRead = Value(lastCommonRead),
       lastReadMessage = Value(lastReadMessage),
       unreadMessages = Value(unreadMessages),
       hasHistory = Value(hasHistory),
       futureConverged = Value(futureConverged),
       blocksJson = Value(blocksJson);
  static Insertable<StoredChatScope> custom({
    Expression<String>? accountId,
    Expression<String>? roomToken,
    Expression<String>? scopeKey,
    Expression<int>? threadId,
    Expression<String>? historyCursor,
    Expression<String>? futureCursor,
    Expression<String>? lastCommonRead,
    Expression<int>? lastReadMessage,
    Expression<int>? unreadMessages,
    Expression<bool>? hasHistory,
    Expression<bool>? futureConverged,
    Expression<String>? blocksJson,
    Expression<int>? lastSyncedAtMillis,
    Expression<String>? lastSyncError,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (roomToken != null) 'room_token': roomToken,
      if (scopeKey != null) 'scope_key': scopeKey,
      if (threadId != null) 'thread_id': threadId,
      if (historyCursor != null) 'history_cursor': historyCursor,
      if (futureCursor != null) 'future_cursor': futureCursor,
      if (lastCommonRead != null) 'last_common_read': lastCommonRead,
      if (lastReadMessage != null) 'last_read_message': lastReadMessage,
      if (unreadMessages != null) 'unread_messages': unreadMessages,
      if (hasHistory != null) 'has_history': hasHistory,
      if (futureConverged != null) 'future_converged': futureConverged,
      if (blocksJson != null) 'blocks_json': blocksJson,
      if (lastSyncedAtMillis != null)
        'last_synced_at_millis': lastSyncedAtMillis,
      if (lastSyncError != null) 'last_sync_error': lastSyncError,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChatScopesCompanion copyWith({
    Value<String>? accountId,
    Value<String>? roomToken,
    Value<String>? scopeKey,
    Value<int?>? threadId,
    Value<String>? historyCursor,
    Value<String>? futureCursor,
    Value<String>? lastCommonRead,
    Value<int>? lastReadMessage,
    Value<int>? unreadMessages,
    Value<bool>? hasHistory,
    Value<bool>? futureConverged,
    Value<String>? blocksJson,
    Value<int?>? lastSyncedAtMillis,
    Value<String?>? lastSyncError,
    Value<int>? rowid,
  }) {
    return ChatScopesCompanion(
      accountId: accountId ?? this.accountId,
      roomToken: roomToken ?? this.roomToken,
      scopeKey: scopeKey ?? this.scopeKey,
      threadId: threadId ?? this.threadId,
      historyCursor: historyCursor ?? this.historyCursor,
      futureCursor: futureCursor ?? this.futureCursor,
      lastCommonRead: lastCommonRead ?? this.lastCommonRead,
      lastReadMessage: lastReadMessage ?? this.lastReadMessage,
      unreadMessages: unreadMessages ?? this.unreadMessages,
      hasHistory: hasHistory ?? this.hasHistory,
      futureConverged: futureConverged ?? this.futureConverged,
      blocksJson: blocksJson ?? this.blocksJson,
      lastSyncedAtMillis: lastSyncedAtMillis ?? this.lastSyncedAtMillis,
      lastSyncError: lastSyncError ?? this.lastSyncError,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (roomToken.present) {
      map['room_token'] = Variable<String>(roomToken.value);
    }
    if (scopeKey.present) {
      map['scope_key'] = Variable<String>(scopeKey.value);
    }
    if (threadId.present) {
      map['thread_id'] = Variable<int>(threadId.value);
    }
    if (historyCursor.present) {
      map['history_cursor'] = Variable<String>(historyCursor.value);
    }
    if (futureCursor.present) {
      map['future_cursor'] = Variable<String>(futureCursor.value);
    }
    if (lastCommonRead.present) {
      map['last_common_read'] = Variable<String>(lastCommonRead.value);
    }
    if (lastReadMessage.present) {
      map['last_read_message'] = Variable<int>(lastReadMessage.value);
    }
    if (unreadMessages.present) {
      map['unread_messages'] = Variable<int>(unreadMessages.value);
    }
    if (hasHistory.present) {
      map['has_history'] = Variable<bool>(hasHistory.value);
    }
    if (futureConverged.present) {
      map['future_converged'] = Variable<bool>(futureConverged.value);
    }
    if (blocksJson.present) {
      map['blocks_json'] = Variable<String>(blocksJson.value);
    }
    if (lastSyncedAtMillis.present) {
      map['last_synced_at_millis'] = Variable<int>(lastSyncedAtMillis.value);
    }
    if (lastSyncError.present) {
      map['last_sync_error'] = Variable<String>(lastSyncError.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatScopesCompanion(')
          ..write('accountId: $accountId, ')
          ..write('roomToken: $roomToken, ')
          ..write('scopeKey: $scopeKey, ')
          ..write('threadId: $threadId, ')
          ..write('historyCursor: $historyCursor, ')
          ..write('futureCursor: $futureCursor, ')
          ..write('lastCommonRead: $lastCommonRead, ')
          ..write('lastReadMessage: $lastReadMessage, ')
          ..write('unreadMessages: $unreadMessages, ')
          ..write('hasHistory: $hasHistory, ')
          ..write('futureConverged: $futureConverged, ')
          ..write('blocksJson: $blocksJson, ')
          ..write('lastSyncedAtMillis: $lastSyncedAtMillis, ')
          ..write('lastSyncError: $lastSyncError, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CachedChatMessagesTable extends CachedChatMessages
    with TableInfo<$CachedChatMessagesTable, CachedChatMessage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedChatMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _roomTokenMeta = const VerificationMeta(
    'roomToken',
  );
  @override
  late final GeneratedColumn<String> roomToken = GeneratedColumn<String>(
    'room_token',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<int> messageId = GeneratedColumn<int>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _actorTypeMeta = const VerificationMeta(
    'actorType',
  );
  @override
  late final GeneratedColumn<String> actorType = GeneratedColumn<String>(
    'actor_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _actorIdMeta = const VerificationMeta(
    'actorId',
  );
  @override
  late final GeneratedColumn<String> actorId = GeneratedColumn<String>(
    'actor_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _actorDisplayNameMeta = const VerificationMeta(
    'actorDisplayName',
  );
  @override
  late final GeneratedColumn<String> actorDisplayName = GeneratedColumn<String>(
    'actor_display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<int> timestamp = GeneratedColumn<int>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _systemMessageMeta = const VerificationMeta(
    'systemMessage',
  );
  @override
  late final GeneratedColumn<String> systemMessage = GeneratedColumn<String>(
    'system_message',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageTypeMeta = const VerificationMeta(
    'messageType',
  );
  @override
  late final GeneratedColumn<String> messageType = GeneratedColumn<String>(
    'message_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _referenceIdMeta = const VerificationMeta(
    'referenceId',
  );
  @override
  late final GeneratedColumn<String> referenceId = GeneratedColumn<String>(
    'reference_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayTextMeta = const VerificationMeta(
    'displayText',
  );
  @override
  late final GeneratedColumn<String> displayText = GeneratedColumn<String>(
    'display_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
    ),
  );
  static const VerificationMeta _threadIdMeta = const VerificationMeta(
    'threadId',
  );
  @override
  late final GeneratedColumn<int> threadId = GeneratedColumn<int>(
    'thread_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _rawJsonMeta = const VerificationMeta(
    'rawJson',
  );
  @override
  late final GeneratedColumn<String> rawJson = GeneratedColumn<String>(
    'raw_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    roomToken,
    messageId,
    actorType,
    actorId,
    actorDisplayName,
    timestamp,
    systemMessage,
    messageType,
    referenceId,
    displayText,
    deleted,
    threadId,
    rawJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_chat_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedChatMessage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('room_token')) {
      context.handle(
        _roomTokenMeta,
        roomToken.isAcceptableOrUnknown(data['room_token']!, _roomTokenMeta),
      );
    } else if (isInserting) {
      context.missing(_roomTokenMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('actor_type')) {
      context.handle(
        _actorTypeMeta,
        actorType.isAcceptableOrUnknown(data['actor_type']!, _actorTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_actorTypeMeta);
    }
    if (data.containsKey('actor_id')) {
      context.handle(
        _actorIdMeta,
        actorId.isAcceptableOrUnknown(data['actor_id']!, _actorIdMeta),
      );
    } else if (isInserting) {
      context.missing(_actorIdMeta);
    }
    if (data.containsKey('actor_display_name')) {
      context.handle(
        _actorDisplayNameMeta,
        actorDisplayName.isAcceptableOrUnknown(
          data['actor_display_name']!,
          _actorDisplayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_actorDisplayNameMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    if (data.containsKey('system_message')) {
      context.handle(
        _systemMessageMeta,
        systemMessage.isAcceptableOrUnknown(
          data['system_message']!,
          _systemMessageMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_systemMessageMeta);
    }
    if (data.containsKey('message_type')) {
      context.handle(
        _messageTypeMeta,
        messageType.isAcceptableOrUnknown(
          data['message_type']!,
          _messageTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_messageTypeMeta);
    }
    if (data.containsKey('reference_id')) {
      context.handle(
        _referenceIdMeta,
        referenceId.isAcceptableOrUnknown(
          data['reference_id']!,
          _referenceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_referenceIdMeta);
    }
    if (data.containsKey('display_text')) {
      context.handle(
        _displayTextMeta,
        displayText.isAcceptableOrUnknown(
          data['display_text']!,
          _displayTextMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayTextMeta);
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    } else if (isInserting) {
      context.missing(_deletedMeta);
    }
    if (data.containsKey('thread_id')) {
      context.handle(
        _threadIdMeta,
        threadId.isAcceptableOrUnknown(data['thread_id']!, _threadIdMeta),
      );
    }
    if (data.containsKey('raw_json')) {
      context.handle(
        _rawJsonMeta,
        rawJson.isAcceptableOrUnknown(data['raw_json']!, _rawJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_rawJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, roomToken, messageId};
  @override
  CachedChatMessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedChatMessage(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      roomToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_token'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}message_id'],
      )!,
      actorType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}actor_type'],
      )!,
      actorId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}actor_id'],
      )!,
      actorDisplayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}actor_display_name'],
      )!,
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}timestamp'],
      )!,
      systemMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}system_message'],
      )!,
      messageType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_type'],
      )!,
      referenceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reference_id'],
      )!,
      displayText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_text'],
      )!,
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      )!,
      threadId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}thread_id'],
      ),
      rawJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}raw_json'],
      )!,
    );
  }

  @override
  $CachedChatMessagesTable createAlias(String alias) {
    return $CachedChatMessagesTable(attachedDatabase, alias);
  }
}

class CachedChatMessage extends DataClass
    implements Insertable<CachedChatMessage> {
  final String accountId;
  final String roomToken;
  final int messageId;
  final String actorType;
  final String actorId;
  final String actorDisplayName;
  final int timestamp;
  final String systemMessage;
  final String messageType;
  final String referenceId;
  final String displayText;
  final bool deleted;
  final int? threadId;
  final String rawJson;
  const CachedChatMessage({
    required this.accountId,
    required this.roomToken,
    required this.messageId,
    required this.actorType,
    required this.actorId,
    required this.actorDisplayName,
    required this.timestamp,
    required this.systemMessage,
    required this.messageType,
    required this.referenceId,
    required this.displayText,
    required this.deleted,
    this.threadId,
    required this.rawJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['room_token'] = Variable<String>(roomToken);
    map['message_id'] = Variable<int>(messageId);
    map['actor_type'] = Variable<String>(actorType);
    map['actor_id'] = Variable<String>(actorId);
    map['actor_display_name'] = Variable<String>(actorDisplayName);
    map['timestamp'] = Variable<int>(timestamp);
    map['system_message'] = Variable<String>(systemMessage);
    map['message_type'] = Variable<String>(messageType);
    map['reference_id'] = Variable<String>(referenceId);
    map['display_text'] = Variable<String>(displayText);
    map['deleted'] = Variable<bool>(deleted);
    if (!nullToAbsent || threadId != null) {
      map['thread_id'] = Variable<int>(threadId);
    }
    map['raw_json'] = Variable<String>(rawJson);
    return map;
  }

  CachedChatMessagesCompanion toCompanion(bool nullToAbsent) {
    return CachedChatMessagesCompanion(
      accountId: Value(accountId),
      roomToken: Value(roomToken),
      messageId: Value(messageId),
      actorType: Value(actorType),
      actorId: Value(actorId),
      actorDisplayName: Value(actorDisplayName),
      timestamp: Value(timestamp),
      systemMessage: Value(systemMessage),
      messageType: Value(messageType),
      referenceId: Value(referenceId),
      displayText: Value(displayText),
      deleted: Value(deleted),
      threadId: threadId == null && nullToAbsent
          ? const Value.absent()
          : Value(threadId),
      rawJson: Value(rawJson),
    );
  }

  factory CachedChatMessage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedChatMessage(
      accountId: serializer.fromJson<String>(json['accountId']),
      roomToken: serializer.fromJson<String>(json['roomToken']),
      messageId: serializer.fromJson<int>(json['messageId']),
      actorType: serializer.fromJson<String>(json['actorType']),
      actorId: serializer.fromJson<String>(json['actorId']),
      actorDisplayName: serializer.fromJson<String>(json['actorDisplayName']),
      timestamp: serializer.fromJson<int>(json['timestamp']),
      systemMessage: serializer.fromJson<String>(json['systemMessage']),
      messageType: serializer.fromJson<String>(json['messageType']),
      referenceId: serializer.fromJson<String>(json['referenceId']),
      displayText: serializer.fromJson<String>(json['displayText']),
      deleted: serializer.fromJson<bool>(json['deleted']),
      threadId: serializer.fromJson<int?>(json['threadId']),
      rawJson: serializer.fromJson<String>(json['rawJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'roomToken': serializer.toJson<String>(roomToken),
      'messageId': serializer.toJson<int>(messageId),
      'actorType': serializer.toJson<String>(actorType),
      'actorId': serializer.toJson<String>(actorId),
      'actorDisplayName': serializer.toJson<String>(actorDisplayName),
      'timestamp': serializer.toJson<int>(timestamp),
      'systemMessage': serializer.toJson<String>(systemMessage),
      'messageType': serializer.toJson<String>(messageType),
      'referenceId': serializer.toJson<String>(referenceId),
      'displayText': serializer.toJson<String>(displayText),
      'deleted': serializer.toJson<bool>(deleted),
      'threadId': serializer.toJson<int?>(threadId),
      'rawJson': serializer.toJson<String>(rawJson),
    };
  }

  CachedChatMessage copyWith({
    String? accountId,
    String? roomToken,
    int? messageId,
    String? actorType,
    String? actorId,
    String? actorDisplayName,
    int? timestamp,
    String? systemMessage,
    String? messageType,
    String? referenceId,
    String? displayText,
    bool? deleted,
    Value<int?> threadId = const Value.absent(),
    String? rawJson,
  }) => CachedChatMessage(
    accountId: accountId ?? this.accountId,
    roomToken: roomToken ?? this.roomToken,
    messageId: messageId ?? this.messageId,
    actorType: actorType ?? this.actorType,
    actorId: actorId ?? this.actorId,
    actorDisplayName: actorDisplayName ?? this.actorDisplayName,
    timestamp: timestamp ?? this.timestamp,
    systemMessage: systemMessage ?? this.systemMessage,
    messageType: messageType ?? this.messageType,
    referenceId: referenceId ?? this.referenceId,
    displayText: displayText ?? this.displayText,
    deleted: deleted ?? this.deleted,
    threadId: threadId.present ? threadId.value : this.threadId,
    rawJson: rawJson ?? this.rawJson,
  );
  CachedChatMessage copyWithCompanion(CachedChatMessagesCompanion data) {
    return CachedChatMessage(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      roomToken: data.roomToken.present ? data.roomToken.value : this.roomToken,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      actorType: data.actorType.present ? data.actorType.value : this.actorType,
      actorId: data.actorId.present ? data.actorId.value : this.actorId,
      actorDisplayName: data.actorDisplayName.present
          ? data.actorDisplayName.value
          : this.actorDisplayName,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      systemMessage: data.systemMessage.present
          ? data.systemMessage.value
          : this.systemMessage,
      messageType: data.messageType.present
          ? data.messageType.value
          : this.messageType,
      referenceId: data.referenceId.present
          ? data.referenceId.value
          : this.referenceId,
      displayText: data.displayText.present
          ? data.displayText.value
          : this.displayText,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
      threadId: data.threadId.present ? data.threadId.value : this.threadId,
      rawJson: data.rawJson.present ? data.rawJson.value : this.rawJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedChatMessage(')
          ..write('accountId: $accountId, ')
          ..write('roomToken: $roomToken, ')
          ..write('messageId: $messageId, ')
          ..write('actorType: $actorType, ')
          ..write('actorId: $actorId, ')
          ..write('actorDisplayName: $actorDisplayName, ')
          ..write('timestamp: $timestamp, ')
          ..write('systemMessage: $systemMessage, ')
          ..write('messageType: $messageType, ')
          ..write('referenceId: $referenceId, ')
          ..write('displayText: $displayText, ')
          ..write('deleted: $deleted, ')
          ..write('threadId: $threadId, ')
          ..write('rawJson: $rawJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    roomToken,
    messageId,
    actorType,
    actorId,
    actorDisplayName,
    timestamp,
    systemMessage,
    messageType,
    referenceId,
    displayText,
    deleted,
    threadId,
    rawJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedChatMessage &&
          other.accountId == this.accountId &&
          other.roomToken == this.roomToken &&
          other.messageId == this.messageId &&
          other.actorType == this.actorType &&
          other.actorId == this.actorId &&
          other.actorDisplayName == this.actorDisplayName &&
          other.timestamp == this.timestamp &&
          other.systemMessage == this.systemMessage &&
          other.messageType == this.messageType &&
          other.referenceId == this.referenceId &&
          other.displayText == this.displayText &&
          other.deleted == this.deleted &&
          other.threadId == this.threadId &&
          other.rawJson == this.rawJson);
}

class CachedChatMessagesCompanion extends UpdateCompanion<CachedChatMessage> {
  final Value<String> accountId;
  final Value<String> roomToken;
  final Value<int> messageId;
  final Value<String> actorType;
  final Value<String> actorId;
  final Value<String> actorDisplayName;
  final Value<int> timestamp;
  final Value<String> systemMessage;
  final Value<String> messageType;
  final Value<String> referenceId;
  final Value<String> displayText;
  final Value<bool> deleted;
  final Value<int?> threadId;
  final Value<String> rawJson;
  final Value<int> rowid;
  const CachedChatMessagesCompanion({
    this.accountId = const Value.absent(),
    this.roomToken = const Value.absent(),
    this.messageId = const Value.absent(),
    this.actorType = const Value.absent(),
    this.actorId = const Value.absent(),
    this.actorDisplayName = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.systemMessage = const Value.absent(),
    this.messageType = const Value.absent(),
    this.referenceId = const Value.absent(),
    this.displayText = const Value.absent(),
    this.deleted = const Value.absent(),
    this.threadId = const Value.absent(),
    this.rawJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedChatMessagesCompanion.insert({
    required String accountId,
    required String roomToken,
    required int messageId,
    required String actorType,
    required String actorId,
    required String actorDisplayName,
    required int timestamp,
    required String systemMessage,
    required String messageType,
    required String referenceId,
    required String displayText,
    required bool deleted,
    this.threadId = const Value.absent(),
    required String rawJson,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       roomToken = Value(roomToken),
       messageId = Value(messageId),
       actorType = Value(actorType),
       actorId = Value(actorId),
       actorDisplayName = Value(actorDisplayName),
       timestamp = Value(timestamp),
       systemMessage = Value(systemMessage),
       messageType = Value(messageType),
       referenceId = Value(referenceId),
       displayText = Value(displayText),
       deleted = Value(deleted),
       rawJson = Value(rawJson);
  static Insertable<CachedChatMessage> custom({
    Expression<String>? accountId,
    Expression<String>? roomToken,
    Expression<int>? messageId,
    Expression<String>? actorType,
    Expression<String>? actorId,
    Expression<String>? actorDisplayName,
    Expression<int>? timestamp,
    Expression<String>? systemMessage,
    Expression<String>? messageType,
    Expression<String>? referenceId,
    Expression<String>? displayText,
    Expression<bool>? deleted,
    Expression<int>? threadId,
    Expression<String>? rawJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (roomToken != null) 'room_token': roomToken,
      if (messageId != null) 'message_id': messageId,
      if (actorType != null) 'actor_type': actorType,
      if (actorId != null) 'actor_id': actorId,
      if (actorDisplayName != null) 'actor_display_name': actorDisplayName,
      if (timestamp != null) 'timestamp': timestamp,
      if (systemMessage != null) 'system_message': systemMessage,
      if (messageType != null) 'message_type': messageType,
      if (referenceId != null) 'reference_id': referenceId,
      if (displayText != null) 'display_text': displayText,
      if (deleted != null) 'deleted': deleted,
      if (threadId != null) 'thread_id': threadId,
      if (rawJson != null) 'raw_json': rawJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedChatMessagesCompanion copyWith({
    Value<String>? accountId,
    Value<String>? roomToken,
    Value<int>? messageId,
    Value<String>? actorType,
    Value<String>? actorId,
    Value<String>? actorDisplayName,
    Value<int>? timestamp,
    Value<String>? systemMessage,
    Value<String>? messageType,
    Value<String>? referenceId,
    Value<String>? displayText,
    Value<bool>? deleted,
    Value<int?>? threadId,
    Value<String>? rawJson,
    Value<int>? rowid,
  }) {
    return CachedChatMessagesCompanion(
      accountId: accountId ?? this.accountId,
      roomToken: roomToken ?? this.roomToken,
      messageId: messageId ?? this.messageId,
      actorType: actorType ?? this.actorType,
      actorId: actorId ?? this.actorId,
      actorDisplayName: actorDisplayName ?? this.actorDisplayName,
      timestamp: timestamp ?? this.timestamp,
      systemMessage: systemMessage ?? this.systemMessage,
      messageType: messageType ?? this.messageType,
      referenceId: referenceId ?? this.referenceId,
      displayText: displayText ?? this.displayText,
      deleted: deleted ?? this.deleted,
      threadId: threadId ?? this.threadId,
      rawJson: rawJson ?? this.rawJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (roomToken.present) {
      map['room_token'] = Variable<String>(roomToken.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<int>(messageId.value);
    }
    if (actorType.present) {
      map['actor_type'] = Variable<String>(actorType.value);
    }
    if (actorId.present) {
      map['actor_id'] = Variable<String>(actorId.value);
    }
    if (actorDisplayName.present) {
      map['actor_display_name'] = Variable<String>(actorDisplayName.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<int>(timestamp.value);
    }
    if (systemMessage.present) {
      map['system_message'] = Variable<String>(systemMessage.value);
    }
    if (messageType.present) {
      map['message_type'] = Variable<String>(messageType.value);
    }
    if (referenceId.present) {
      map['reference_id'] = Variable<String>(referenceId.value);
    }
    if (displayText.present) {
      map['display_text'] = Variable<String>(displayText.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (threadId.present) {
      map['thread_id'] = Variable<int>(threadId.value);
    }
    if (rawJson.present) {
      map['raw_json'] = Variable<String>(rawJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedChatMessagesCompanion(')
          ..write('accountId: $accountId, ')
          ..write('roomToken: $roomToken, ')
          ..write('messageId: $messageId, ')
          ..write('actorType: $actorType, ')
          ..write('actorId: $actorId, ')
          ..write('actorDisplayName: $actorDisplayName, ')
          ..write('timestamp: $timestamp, ')
          ..write('systemMessage: $systemMessage, ')
          ..write('messageType: $messageType, ')
          ..write('referenceId: $referenceId, ')
          ..write('displayText: $displayText, ')
          ..write('deleted: $deleted, ')
          ..write('threadId: $threadId, ')
          ..write('rawJson: $rawJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TextSendOperationsTable extends TextSendOperations
    with TableInfo<$TextSendOperationsTable, StoredTextSendOperation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TextSendOperationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _operationIdMeta = const VerificationMeta(
    'operationId',
  );
  @override
  late final GeneratedColumn<String> operationId = GeneratedColumn<String>(
    'operation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roomTokenMeta = const VerificationMeta(
    'roomToken',
  );
  @override
  late final GeneratedColumn<String> roomToken = GeneratedColumn<String>(
    'room_token',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _referenceIdMeta = const VerificationMeta(
    'referenceId',
  );
  @override
  late final GeneratedColumn<String> referenceId = GeneratedColumn<String>(
    'reference_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageMeta = const VerificationMeta(
    'message',
  );
  @override
  late final GeneratedColumn<String> message = GeneratedColumn<String>(
    'message',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _replayContractRevisionMeta =
      const VerificationMeta('replayContractRevision');
  @override
  late final GeneratedColumn<String> replayContractRevision =
      GeneratedColumn<String>(
        'replay_contract_revision',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _enqueueSequenceMeta = const VerificationMeta(
    'enqueueSequence',
  );
  @override
  late final GeneratedColumn<int> enqueueSequence = GeneratedColumn<int>(
    'enqueue_sequence',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _outboxStateMeta = const VerificationMeta(
    'outboxState',
  );
  @override
  late final GeneratedColumn<String> outboxState = GeneratedColumn<String>(
    'outbox_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attemptCountMeta = const VerificationMeta(
    'attemptCount',
  );
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
    'attempt_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageIdsJsonMeta = const VerificationMeta(
    'messageIdsJson',
  );
  @override
  late final GeneratedColumn<String> messageIdsJson = GeneratedColumn<String>(
    'message_ids_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _duplicateRiskAcknowledgedMeta =
      const VerificationMeta('duplicateRiskAcknowledged');
  @override
  late final GeneratedColumn<bool> duplicateRiskAcknowledged =
      GeneratedColumn<bool>(
        'duplicate_risk_acknowledged',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: true,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("duplicate_risk_acknowledged" IN (0, 1))',
        ),
      );
  static const VerificationMeta _errorClassMeta = const VerificationMeta(
    'errorClass',
  );
  @override
  late final GeneratedColumn<String> errorClass = GeneratedColumn<String>(
    'error_class',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nextAttemptAtMeta = const VerificationMeta(
    'nextAttemptAt',
  );
  @override
  late final GeneratedColumn<int> nextAttemptAt = GeneratedColumn<int>(
    'next_attempt_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _replyToMeta = const VerificationMeta(
    'replyTo',
  );
  @override
  late final GeneratedColumn<int> replyTo = GeneratedColumn<int>(
    'reply_to',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _threadIdMeta = const VerificationMeta(
    'threadId',
  );
  @override
  late final GeneratedColumn<int> threadId = GeneratedColumn<int>(
    'thread_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _replyToTokenMeta = const VerificationMeta(
    'replyToToken',
  );
  @override
  late final GeneratedColumn<String> replyToToken = GeneratedColumn<String>(
    'reply_to_token',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _parentRoomTokenMeta = const VerificationMeta(
    'parentRoomToken',
  );
  @override
  late final GeneratedColumn<String> parentRoomToken = GeneratedColumn<String>(
    'parent_room_token',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMillisMeta = const VerificationMeta(
    'createdAtMillis',
  );
  @override
  late final GeneratedColumn<int> createdAtMillis = GeneratedColumn<int>(
    'created_at_millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMillisMeta = const VerificationMeta(
    'updatedAtMillis',
  );
  @override
  late final GeneratedColumn<int> updatedAtMillis = GeneratedColumn<int>(
    'updated_at_millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    operationId,
    roomToken,
    referenceId,
    message,
    replayContractRevision,
    enqueueSequence,
    outboxState,
    attemptCount,
    messageIdsJson,
    duplicateRiskAcknowledged,
    errorClass,
    nextAttemptAt,
    replyTo,
    threadId,
    replyToToken,
    parentRoomToken,
    createdAtMillis,
    updatedAtMillis,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'text_send_operations';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredTextSendOperation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('operation_id')) {
      context.handle(
        _operationIdMeta,
        operationId.isAcceptableOrUnknown(
          data['operation_id']!,
          _operationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationIdMeta);
    }
    if (data.containsKey('room_token')) {
      context.handle(
        _roomTokenMeta,
        roomToken.isAcceptableOrUnknown(data['room_token']!, _roomTokenMeta),
      );
    } else if (isInserting) {
      context.missing(_roomTokenMeta);
    }
    if (data.containsKey('reference_id')) {
      context.handle(
        _referenceIdMeta,
        referenceId.isAcceptableOrUnknown(
          data['reference_id']!,
          _referenceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_referenceIdMeta);
    }
    if (data.containsKey('message')) {
      context.handle(
        _messageMeta,
        message.isAcceptableOrUnknown(data['message']!, _messageMeta),
      );
    } else if (isInserting) {
      context.missing(_messageMeta);
    }
    if (data.containsKey('replay_contract_revision')) {
      context.handle(
        _replayContractRevisionMeta,
        replayContractRevision.isAcceptableOrUnknown(
          data['replay_contract_revision']!,
          _replayContractRevisionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_replayContractRevisionMeta);
    }
    if (data.containsKey('enqueue_sequence')) {
      context.handle(
        _enqueueSequenceMeta,
        enqueueSequence.isAcceptableOrUnknown(
          data['enqueue_sequence']!,
          _enqueueSequenceMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_enqueueSequenceMeta);
    }
    if (data.containsKey('outbox_state')) {
      context.handle(
        _outboxStateMeta,
        outboxState.isAcceptableOrUnknown(
          data['outbox_state']!,
          _outboxStateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_outboxStateMeta);
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
        _attemptCountMeta,
        attemptCount.isAcceptableOrUnknown(
          data['attempt_count']!,
          _attemptCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_attemptCountMeta);
    }
    if (data.containsKey('message_ids_json')) {
      context.handle(
        _messageIdsJsonMeta,
        messageIdsJson.isAcceptableOrUnknown(
          data['message_ids_json']!,
          _messageIdsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_messageIdsJsonMeta);
    }
    if (data.containsKey('duplicate_risk_acknowledged')) {
      context.handle(
        _duplicateRiskAcknowledgedMeta,
        duplicateRiskAcknowledged.isAcceptableOrUnknown(
          data['duplicate_risk_acknowledged']!,
          _duplicateRiskAcknowledgedMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_duplicateRiskAcknowledgedMeta);
    }
    if (data.containsKey('error_class')) {
      context.handle(
        _errorClassMeta,
        errorClass.isAcceptableOrUnknown(data['error_class']!, _errorClassMeta),
      );
    }
    if (data.containsKey('next_attempt_at')) {
      context.handle(
        _nextAttemptAtMeta,
        nextAttemptAt.isAcceptableOrUnknown(
          data['next_attempt_at']!,
          _nextAttemptAtMeta,
        ),
      );
    }
    if (data.containsKey('reply_to')) {
      context.handle(
        _replyToMeta,
        replyTo.isAcceptableOrUnknown(data['reply_to']!, _replyToMeta),
      );
    }
    if (data.containsKey('thread_id')) {
      context.handle(
        _threadIdMeta,
        threadId.isAcceptableOrUnknown(data['thread_id']!, _threadIdMeta),
      );
    }
    if (data.containsKey('reply_to_token')) {
      context.handle(
        _replyToTokenMeta,
        replyToToken.isAcceptableOrUnknown(
          data['reply_to_token']!,
          _replyToTokenMeta,
        ),
      );
    }
    if (data.containsKey('parent_room_token')) {
      context.handle(
        _parentRoomTokenMeta,
        parentRoomToken.isAcceptableOrUnknown(
          data['parent_room_token']!,
          _parentRoomTokenMeta,
        ),
      );
    }
    if (data.containsKey('created_at_millis')) {
      context.handle(
        _createdAtMillisMeta,
        createdAtMillis.isAcceptableOrUnknown(
          data['created_at_millis']!,
          _createdAtMillisMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_createdAtMillisMeta);
    }
    if (data.containsKey('updated_at_millis')) {
      context.handle(
        _updatedAtMillisMeta,
        updatedAtMillis.isAcceptableOrUnknown(
          data['updated_at_millis']!,
          _updatedAtMillisMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMillisMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, operationId};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, referenceId},
    {accountId, roomToken, enqueueSequence},
  ];
  @override
  StoredTextSendOperation map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredTextSendOperation(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      operationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation_id'],
      )!,
      roomToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_token'],
      )!,
      referenceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reference_id'],
      )!,
      message: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message'],
      )!,
      replayContractRevision: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}replay_contract_revision'],
      )!,
      enqueueSequence: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}enqueue_sequence'],
      )!,
      outboxState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}outbox_state'],
      )!,
      attemptCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempt_count'],
      )!,
      messageIdsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_ids_json'],
      )!,
      duplicateRiskAcknowledged: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}duplicate_risk_acknowledged'],
      )!,
      errorClass: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_class'],
      ),
      nextAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_attempt_at'],
      ),
      replyTo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reply_to'],
      ),
      threadId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}thread_id'],
      ),
      replyToToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reply_to_token'],
      ),
      parentRoomToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_room_token'],
      ),
      createdAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_millis'],
      )!,
      updatedAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_millis'],
      )!,
    );
  }

  @override
  $TextSendOperationsTable createAlias(String alias) {
    return $TextSendOperationsTable(attachedDatabase, alias);
  }
}

class StoredTextSendOperation extends DataClass
    implements Insertable<StoredTextSendOperation> {
  final String accountId;
  final String operationId;
  final String roomToken;
  final String referenceId;
  final String message;
  final String replayContractRevision;
  final int enqueueSequence;
  final String outboxState;
  final int attemptCount;
  final String messageIdsJson;
  final bool duplicateRiskAcknowledged;
  final String? errorClass;
  final int? nextAttemptAt;
  final int? replyTo;
  final int? threadId;
  final String? replyToToken;
  final String? parentRoomToken;
  final int createdAtMillis;
  final int updatedAtMillis;
  const StoredTextSendOperation({
    required this.accountId,
    required this.operationId,
    required this.roomToken,
    required this.referenceId,
    required this.message,
    required this.replayContractRevision,
    required this.enqueueSequence,
    required this.outboxState,
    required this.attemptCount,
    required this.messageIdsJson,
    required this.duplicateRiskAcknowledged,
    this.errorClass,
    this.nextAttemptAt,
    this.replyTo,
    this.threadId,
    this.replyToToken,
    this.parentRoomToken,
    required this.createdAtMillis,
    required this.updatedAtMillis,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['operation_id'] = Variable<String>(operationId);
    map['room_token'] = Variable<String>(roomToken);
    map['reference_id'] = Variable<String>(referenceId);
    map['message'] = Variable<String>(message);
    map['replay_contract_revision'] = Variable<String>(replayContractRevision);
    map['enqueue_sequence'] = Variable<int>(enqueueSequence);
    map['outbox_state'] = Variable<String>(outboxState);
    map['attempt_count'] = Variable<int>(attemptCount);
    map['message_ids_json'] = Variable<String>(messageIdsJson);
    map['duplicate_risk_acknowledged'] = Variable<bool>(
      duplicateRiskAcknowledged,
    );
    if (!nullToAbsent || errorClass != null) {
      map['error_class'] = Variable<String>(errorClass);
    }
    if (!nullToAbsent || nextAttemptAt != null) {
      map['next_attempt_at'] = Variable<int>(nextAttemptAt);
    }
    if (!nullToAbsent || replyTo != null) {
      map['reply_to'] = Variable<int>(replyTo);
    }
    if (!nullToAbsent || threadId != null) {
      map['thread_id'] = Variable<int>(threadId);
    }
    if (!nullToAbsent || replyToToken != null) {
      map['reply_to_token'] = Variable<String>(replyToToken);
    }
    if (!nullToAbsent || parentRoomToken != null) {
      map['parent_room_token'] = Variable<String>(parentRoomToken);
    }
    map['created_at_millis'] = Variable<int>(createdAtMillis);
    map['updated_at_millis'] = Variable<int>(updatedAtMillis);
    return map;
  }

  TextSendOperationsCompanion toCompanion(bool nullToAbsent) {
    return TextSendOperationsCompanion(
      accountId: Value(accountId),
      operationId: Value(operationId),
      roomToken: Value(roomToken),
      referenceId: Value(referenceId),
      message: Value(message),
      replayContractRevision: Value(replayContractRevision),
      enqueueSequence: Value(enqueueSequence),
      outboxState: Value(outboxState),
      attemptCount: Value(attemptCount),
      messageIdsJson: Value(messageIdsJson),
      duplicateRiskAcknowledged: Value(duplicateRiskAcknowledged),
      errorClass: errorClass == null && nullToAbsent
          ? const Value.absent()
          : Value(errorClass),
      nextAttemptAt: nextAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextAttemptAt),
      replyTo: replyTo == null && nullToAbsent
          ? const Value.absent()
          : Value(replyTo),
      threadId: threadId == null && nullToAbsent
          ? const Value.absent()
          : Value(threadId),
      replyToToken: replyToToken == null && nullToAbsent
          ? const Value.absent()
          : Value(replyToToken),
      parentRoomToken: parentRoomToken == null && nullToAbsent
          ? const Value.absent()
          : Value(parentRoomToken),
      createdAtMillis: Value(createdAtMillis),
      updatedAtMillis: Value(updatedAtMillis),
    );
  }

  factory StoredTextSendOperation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredTextSendOperation(
      accountId: serializer.fromJson<String>(json['accountId']),
      operationId: serializer.fromJson<String>(json['operationId']),
      roomToken: serializer.fromJson<String>(json['roomToken']),
      referenceId: serializer.fromJson<String>(json['referenceId']),
      message: serializer.fromJson<String>(json['message']),
      replayContractRevision: serializer.fromJson<String>(
        json['replayContractRevision'],
      ),
      enqueueSequence: serializer.fromJson<int>(json['enqueueSequence']),
      outboxState: serializer.fromJson<String>(json['outboxState']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      messageIdsJson: serializer.fromJson<String>(json['messageIdsJson']),
      duplicateRiskAcknowledged: serializer.fromJson<bool>(
        json['duplicateRiskAcknowledged'],
      ),
      errorClass: serializer.fromJson<String?>(json['errorClass']),
      nextAttemptAt: serializer.fromJson<int?>(json['nextAttemptAt']),
      replyTo: serializer.fromJson<int?>(json['replyTo']),
      threadId: serializer.fromJson<int?>(json['threadId']),
      replyToToken: serializer.fromJson<String?>(json['replyToToken']),
      parentRoomToken: serializer.fromJson<String?>(json['parentRoomToken']),
      createdAtMillis: serializer.fromJson<int>(json['createdAtMillis']),
      updatedAtMillis: serializer.fromJson<int>(json['updatedAtMillis']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'operationId': serializer.toJson<String>(operationId),
      'roomToken': serializer.toJson<String>(roomToken),
      'referenceId': serializer.toJson<String>(referenceId),
      'message': serializer.toJson<String>(message),
      'replayContractRevision': serializer.toJson<String>(
        replayContractRevision,
      ),
      'enqueueSequence': serializer.toJson<int>(enqueueSequence),
      'outboxState': serializer.toJson<String>(outboxState),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'messageIdsJson': serializer.toJson<String>(messageIdsJson),
      'duplicateRiskAcknowledged': serializer.toJson<bool>(
        duplicateRiskAcknowledged,
      ),
      'errorClass': serializer.toJson<String?>(errorClass),
      'nextAttemptAt': serializer.toJson<int?>(nextAttemptAt),
      'replyTo': serializer.toJson<int?>(replyTo),
      'threadId': serializer.toJson<int?>(threadId),
      'replyToToken': serializer.toJson<String?>(replyToToken),
      'parentRoomToken': serializer.toJson<String?>(parentRoomToken),
      'createdAtMillis': serializer.toJson<int>(createdAtMillis),
      'updatedAtMillis': serializer.toJson<int>(updatedAtMillis),
    };
  }

  StoredTextSendOperation copyWith({
    String? accountId,
    String? operationId,
    String? roomToken,
    String? referenceId,
    String? message,
    String? replayContractRevision,
    int? enqueueSequence,
    String? outboxState,
    int? attemptCount,
    String? messageIdsJson,
    bool? duplicateRiskAcknowledged,
    Value<String?> errorClass = const Value.absent(),
    Value<int?> nextAttemptAt = const Value.absent(),
    Value<int?> replyTo = const Value.absent(),
    Value<int?> threadId = const Value.absent(),
    Value<String?> replyToToken = const Value.absent(),
    Value<String?> parentRoomToken = const Value.absent(),
    int? createdAtMillis,
    int? updatedAtMillis,
  }) => StoredTextSendOperation(
    accountId: accountId ?? this.accountId,
    operationId: operationId ?? this.operationId,
    roomToken: roomToken ?? this.roomToken,
    referenceId: referenceId ?? this.referenceId,
    message: message ?? this.message,
    replayContractRevision:
        replayContractRevision ?? this.replayContractRevision,
    enqueueSequence: enqueueSequence ?? this.enqueueSequence,
    outboxState: outboxState ?? this.outboxState,
    attemptCount: attemptCount ?? this.attemptCount,
    messageIdsJson: messageIdsJson ?? this.messageIdsJson,
    duplicateRiskAcknowledged:
        duplicateRiskAcknowledged ?? this.duplicateRiskAcknowledged,
    errorClass: errorClass.present ? errorClass.value : this.errorClass,
    nextAttemptAt: nextAttemptAt.present
        ? nextAttemptAt.value
        : this.nextAttemptAt,
    replyTo: replyTo.present ? replyTo.value : this.replyTo,
    threadId: threadId.present ? threadId.value : this.threadId,
    replyToToken: replyToToken.present ? replyToToken.value : this.replyToToken,
    parentRoomToken: parentRoomToken.present
        ? parentRoomToken.value
        : this.parentRoomToken,
    createdAtMillis: createdAtMillis ?? this.createdAtMillis,
    updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
  );
  StoredTextSendOperation copyWithCompanion(TextSendOperationsCompanion data) {
    return StoredTextSendOperation(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      operationId: data.operationId.present
          ? data.operationId.value
          : this.operationId,
      roomToken: data.roomToken.present ? data.roomToken.value : this.roomToken,
      referenceId: data.referenceId.present
          ? data.referenceId.value
          : this.referenceId,
      message: data.message.present ? data.message.value : this.message,
      replayContractRevision: data.replayContractRevision.present
          ? data.replayContractRevision.value
          : this.replayContractRevision,
      enqueueSequence: data.enqueueSequence.present
          ? data.enqueueSequence.value
          : this.enqueueSequence,
      outboxState: data.outboxState.present
          ? data.outboxState.value
          : this.outboxState,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      messageIdsJson: data.messageIdsJson.present
          ? data.messageIdsJson.value
          : this.messageIdsJson,
      duplicateRiskAcknowledged: data.duplicateRiskAcknowledged.present
          ? data.duplicateRiskAcknowledged.value
          : this.duplicateRiskAcknowledged,
      errorClass: data.errorClass.present
          ? data.errorClass.value
          : this.errorClass,
      nextAttemptAt: data.nextAttemptAt.present
          ? data.nextAttemptAt.value
          : this.nextAttemptAt,
      replyTo: data.replyTo.present ? data.replyTo.value : this.replyTo,
      threadId: data.threadId.present ? data.threadId.value : this.threadId,
      replyToToken: data.replyToToken.present
          ? data.replyToToken.value
          : this.replyToToken,
      parentRoomToken: data.parentRoomToken.present
          ? data.parentRoomToken.value
          : this.parentRoomToken,
      createdAtMillis: data.createdAtMillis.present
          ? data.createdAtMillis.value
          : this.createdAtMillis,
      updatedAtMillis: data.updatedAtMillis.present
          ? data.updatedAtMillis.value
          : this.updatedAtMillis,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredTextSendOperation(')
          ..write('accountId: $accountId, ')
          ..write('operationId: $operationId, ')
          ..write('roomToken: $roomToken, ')
          ..write('referenceId: $referenceId, ')
          ..write('message: $message, ')
          ..write('replayContractRevision: $replayContractRevision, ')
          ..write('enqueueSequence: $enqueueSequence, ')
          ..write('outboxState: $outboxState, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('messageIdsJson: $messageIdsJson, ')
          ..write('duplicateRiskAcknowledged: $duplicateRiskAcknowledged, ')
          ..write('errorClass: $errorClass, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('replyTo: $replyTo, ')
          ..write('threadId: $threadId, ')
          ..write('replyToToken: $replyToToken, ')
          ..write('parentRoomToken: $parentRoomToken, ')
          ..write('createdAtMillis: $createdAtMillis, ')
          ..write('updatedAtMillis: $updatedAtMillis')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    operationId,
    roomToken,
    referenceId,
    message,
    replayContractRevision,
    enqueueSequence,
    outboxState,
    attemptCount,
    messageIdsJson,
    duplicateRiskAcknowledged,
    errorClass,
    nextAttemptAt,
    replyTo,
    threadId,
    replyToToken,
    parentRoomToken,
    createdAtMillis,
    updatedAtMillis,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredTextSendOperation &&
          other.accountId == this.accountId &&
          other.operationId == this.operationId &&
          other.roomToken == this.roomToken &&
          other.referenceId == this.referenceId &&
          other.message == this.message &&
          other.replayContractRevision == this.replayContractRevision &&
          other.enqueueSequence == this.enqueueSequence &&
          other.outboxState == this.outboxState &&
          other.attemptCount == this.attemptCount &&
          other.messageIdsJson == this.messageIdsJson &&
          other.duplicateRiskAcknowledged == this.duplicateRiskAcknowledged &&
          other.errorClass == this.errorClass &&
          other.nextAttemptAt == this.nextAttemptAt &&
          other.replyTo == this.replyTo &&
          other.threadId == this.threadId &&
          other.replyToToken == this.replyToToken &&
          other.parentRoomToken == this.parentRoomToken &&
          other.createdAtMillis == this.createdAtMillis &&
          other.updatedAtMillis == this.updatedAtMillis);
}

class TextSendOperationsCompanion
    extends UpdateCompanion<StoredTextSendOperation> {
  final Value<String> accountId;
  final Value<String> operationId;
  final Value<String> roomToken;
  final Value<String> referenceId;
  final Value<String> message;
  final Value<String> replayContractRevision;
  final Value<int> enqueueSequence;
  final Value<String> outboxState;
  final Value<int> attemptCount;
  final Value<String> messageIdsJson;
  final Value<bool> duplicateRiskAcknowledged;
  final Value<String?> errorClass;
  final Value<int?> nextAttemptAt;
  final Value<int?> replyTo;
  final Value<int?> threadId;
  final Value<String?> replyToToken;
  final Value<String?> parentRoomToken;
  final Value<int> createdAtMillis;
  final Value<int> updatedAtMillis;
  final Value<int> rowid;
  const TextSendOperationsCompanion({
    this.accountId = const Value.absent(),
    this.operationId = const Value.absent(),
    this.roomToken = const Value.absent(),
    this.referenceId = const Value.absent(),
    this.message = const Value.absent(),
    this.replayContractRevision = const Value.absent(),
    this.enqueueSequence = const Value.absent(),
    this.outboxState = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.messageIdsJson = const Value.absent(),
    this.duplicateRiskAcknowledged = const Value.absent(),
    this.errorClass = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.replyTo = const Value.absent(),
    this.threadId = const Value.absent(),
    this.replyToToken = const Value.absent(),
    this.parentRoomToken = const Value.absent(),
    this.createdAtMillis = const Value.absent(),
    this.updatedAtMillis = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TextSendOperationsCompanion.insert({
    required String accountId,
    required String operationId,
    required String roomToken,
    required String referenceId,
    required String message,
    required String replayContractRevision,
    required int enqueueSequence,
    required String outboxState,
    required int attemptCount,
    required String messageIdsJson,
    required bool duplicateRiskAcknowledged,
    this.errorClass = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.replyTo = const Value.absent(),
    this.threadId = const Value.absent(),
    this.replyToToken = const Value.absent(),
    this.parentRoomToken = const Value.absent(),
    required int createdAtMillis,
    required int updatedAtMillis,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       operationId = Value(operationId),
       roomToken = Value(roomToken),
       referenceId = Value(referenceId),
       message = Value(message),
       replayContractRevision = Value(replayContractRevision),
       enqueueSequence = Value(enqueueSequence),
       outboxState = Value(outboxState),
       attemptCount = Value(attemptCount),
       messageIdsJson = Value(messageIdsJson),
       duplicateRiskAcknowledged = Value(duplicateRiskAcknowledged),
       createdAtMillis = Value(createdAtMillis),
       updatedAtMillis = Value(updatedAtMillis);
  static Insertable<StoredTextSendOperation> custom({
    Expression<String>? accountId,
    Expression<String>? operationId,
    Expression<String>? roomToken,
    Expression<String>? referenceId,
    Expression<String>? message,
    Expression<String>? replayContractRevision,
    Expression<int>? enqueueSequence,
    Expression<String>? outboxState,
    Expression<int>? attemptCount,
    Expression<String>? messageIdsJson,
    Expression<bool>? duplicateRiskAcknowledged,
    Expression<String>? errorClass,
    Expression<int>? nextAttemptAt,
    Expression<int>? replyTo,
    Expression<int>? threadId,
    Expression<String>? replyToToken,
    Expression<String>? parentRoomToken,
    Expression<int>? createdAtMillis,
    Expression<int>? updatedAtMillis,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (operationId != null) 'operation_id': operationId,
      if (roomToken != null) 'room_token': roomToken,
      if (referenceId != null) 'reference_id': referenceId,
      if (message != null) 'message': message,
      if (replayContractRevision != null)
        'replay_contract_revision': replayContractRevision,
      if (enqueueSequence != null) 'enqueue_sequence': enqueueSequence,
      if (outboxState != null) 'outbox_state': outboxState,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (messageIdsJson != null) 'message_ids_json': messageIdsJson,
      if (duplicateRiskAcknowledged != null)
        'duplicate_risk_acknowledged': duplicateRiskAcknowledged,
      if (errorClass != null) 'error_class': errorClass,
      if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
      if (replyTo != null) 'reply_to': replyTo,
      if (threadId != null) 'thread_id': threadId,
      if (replyToToken != null) 'reply_to_token': replyToToken,
      if (parentRoomToken != null) 'parent_room_token': parentRoomToken,
      if (createdAtMillis != null) 'created_at_millis': createdAtMillis,
      if (updatedAtMillis != null) 'updated_at_millis': updatedAtMillis,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TextSendOperationsCompanion copyWith({
    Value<String>? accountId,
    Value<String>? operationId,
    Value<String>? roomToken,
    Value<String>? referenceId,
    Value<String>? message,
    Value<String>? replayContractRevision,
    Value<int>? enqueueSequence,
    Value<String>? outboxState,
    Value<int>? attemptCount,
    Value<String>? messageIdsJson,
    Value<bool>? duplicateRiskAcknowledged,
    Value<String?>? errorClass,
    Value<int?>? nextAttemptAt,
    Value<int?>? replyTo,
    Value<int?>? threadId,
    Value<String?>? replyToToken,
    Value<String?>? parentRoomToken,
    Value<int>? createdAtMillis,
    Value<int>? updatedAtMillis,
    Value<int>? rowid,
  }) {
    return TextSendOperationsCompanion(
      accountId: accountId ?? this.accountId,
      operationId: operationId ?? this.operationId,
      roomToken: roomToken ?? this.roomToken,
      referenceId: referenceId ?? this.referenceId,
      message: message ?? this.message,
      replayContractRevision:
          replayContractRevision ?? this.replayContractRevision,
      enqueueSequence: enqueueSequence ?? this.enqueueSequence,
      outboxState: outboxState ?? this.outboxState,
      attemptCount: attemptCount ?? this.attemptCount,
      messageIdsJson: messageIdsJson ?? this.messageIdsJson,
      duplicateRiskAcknowledged:
          duplicateRiskAcknowledged ?? this.duplicateRiskAcknowledged,
      errorClass: errorClass ?? this.errorClass,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      replyTo: replyTo ?? this.replyTo,
      threadId: threadId ?? this.threadId,
      replyToToken: replyToToken ?? this.replyToToken,
      parentRoomToken: parentRoomToken ?? this.parentRoomToken,
      createdAtMillis: createdAtMillis ?? this.createdAtMillis,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (operationId.present) {
      map['operation_id'] = Variable<String>(operationId.value);
    }
    if (roomToken.present) {
      map['room_token'] = Variable<String>(roomToken.value);
    }
    if (referenceId.present) {
      map['reference_id'] = Variable<String>(referenceId.value);
    }
    if (message.present) {
      map['message'] = Variable<String>(message.value);
    }
    if (replayContractRevision.present) {
      map['replay_contract_revision'] = Variable<String>(
        replayContractRevision.value,
      );
    }
    if (enqueueSequence.present) {
      map['enqueue_sequence'] = Variable<int>(enqueueSequence.value);
    }
    if (outboxState.present) {
      map['outbox_state'] = Variable<String>(outboxState.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (messageIdsJson.present) {
      map['message_ids_json'] = Variable<String>(messageIdsJson.value);
    }
    if (duplicateRiskAcknowledged.present) {
      map['duplicate_risk_acknowledged'] = Variable<bool>(
        duplicateRiskAcknowledged.value,
      );
    }
    if (errorClass.present) {
      map['error_class'] = Variable<String>(errorClass.value);
    }
    if (nextAttemptAt.present) {
      map['next_attempt_at'] = Variable<int>(nextAttemptAt.value);
    }
    if (replyTo.present) {
      map['reply_to'] = Variable<int>(replyTo.value);
    }
    if (threadId.present) {
      map['thread_id'] = Variable<int>(threadId.value);
    }
    if (replyToToken.present) {
      map['reply_to_token'] = Variable<String>(replyToToken.value);
    }
    if (parentRoomToken.present) {
      map['parent_room_token'] = Variable<String>(parentRoomToken.value);
    }
    if (createdAtMillis.present) {
      map['created_at_millis'] = Variable<int>(createdAtMillis.value);
    }
    if (updatedAtMillis.present) {
      map['updated_at_millis'] = Variable<int>(updatedAtMillis.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TextSendOperationsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('operationId: $operationId, ')
          ..write('roomToken: $roomToken, ')
          ..write('referenceId: $referenceId, ')
          ..write('message: $message, ')
          ..write('replayContractRevision: $replayContractRevision, ')
          ..write('enqueueSequence: $enqueueSequence, ')
          ..write('outboxState: $outboxState, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('messageIdsJson: $messageIdsJson, ')
          ..write('duplicateRiskAcknowledged: $duplicateRiskAcknowledged, ')
          ..write('errorClass: $errorClass, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('replyTo: $replyTo, ')
          ..write('threadId: $threadId, ')
          ..write('replyToToken: $replyToToken, ')
          ..write('parentRoomToken: $parentRoomToken, ')
          ..write('createdAtMillis: $createdAtMillis, ')
          ..write('updatedAtMillis: $updatedAtMillis, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ChatDraftsTable extends ChatDrafts
    with TableInfo<$ChatDraftsTable, StoredChatDraft> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatDraftsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _roomTokenMeta = const VerificationMeta(
    'roomToken',
  );
  @override
  late final GeneratedColumn<String> roomToken = GeneratedColumn<String>(
    'room_token',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scopeKeyMeta = const VerificationMeta(
    'scopeKey',
  );
  @override
  late final GeneratedColumn<String> scopeKey = GeneratedColumn<String>(
    'scope_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _draftTextMeta = const VerificationMeta(
    'draftText',
  );
  @override
  late final GeneratedColumn<String> draftText = GeneratedColumn<String>(
    'draft_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMillisMeta = const VerificationMeta(
    'updatedAtMillis',
  );
  @override
  late final GeneratedColumn<int> updatedAtMillis = GeneratedColumn<int>(
    'updated_at_millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    roomToken,
    scopeKey,
    draftText,
    updatedAtMillis,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_drafts';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredChatDraft> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('room_token')) {
      context.handle(
        _roomTokenMeta,
        roomToken.isAcceptableOrUnknown(data['room_token']!, _roomTokenMeta),
      );
    } else if (isInserting) {
      context.missing(_roomTokenMeta);
    }
    if (data.containsKey('scope_key')) {
      context.handle(
        _scopeKeyMeta,
        scopeKey.isAcceptableOrUnknown(data['scope_key']!, _scopeKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_scopeKeyMeta);
    }
    if (data.containsKey('draft_text')) {
      context.handle(
        _draftTextMeta,
        draftText.isAcceptableOrUnknown(data['draft_text']!, _draftTextMeta),
      );
    } else if (isInserting) {
      context.missing(_draftTextMeta);
    }
    if (data.containsKey('updated_at_millis')) {
      context.handle(
        _updatedAtMillisMeta,
        updatedAtMillis.isAcceptableOrUnknown(
          data['updated_at_millis']!,
          _updatedAtMillisMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMillisMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, roomToken, scopeKey};
  @override
  StoredChatDraft map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredChatDraft(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      roomToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_token'],
      )!,
      scopeKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope_key'],
      )!,
      draftText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}draft_text'],
      )!,
      updatedAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_millis'],
      )!,
    );
  }

  @override
  $ChatDraftsTable createAlias(String alias) {
    return $ChatDraftsTable(attachedDatabase, alias);
  }
}

class StoredChatDraft extends DataClass implements Insertable<StoredChatDraft> {
  final String accountId;
  final String roomToken;
  final String scopeKey;
  final String draftText;
  final int updatedAtMillis;
  const StoredChatDraft({
    required this.accountId,
    required this.roomToken,
    required this.scopeKey,
    required this.draftText,
    required this.updatedAtMillis,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['room_token'] = Variable<String>(roomToken);
    map['scope_key'] = Variable<String>(scopeKey);
    map['draft_text'] = Variable<String>(draftText);
    map['updated_at_millis'] = Variable<int>(updatedAtMillis);
    return map;
  }

  ChatDraftsCompanion toCompanion(bool nullToAbsent) {
    return ChatDraftsCompanion(
      accountId: Value(accountId),
      roomToken: Value(roomToken),
      scopeKey: Value(scopeKey),
      draftText: Value(draftText),
      updatedAtMillis: Value(updatedAtMillis),
    );
  }

  factory StoredChatDraft.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredChatDraft(
      accountId: serializer.fromJson<String>(json['accountId']),
      roomToken: serializer.fromJson<String>(json['roomToken']),
      scopeKey: serializer.fromJson<String>(json['scopeKey']),
      draftText: serializer.fromJson<String>(json['draftText']),
      updatedAtMillis: serializer.fromJson<int>(json['updatedAtMillis']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'roomToken': serializer.toJson<String>(roomToken),
      'scopeKey': serializer.toJson<String>(scopeKey),
      'draftText': serializer.toJson<String>(draftText),
      'updatedAtMillis': serializer.toJson<int>(updatedAtMillis),
    };
  }

  StoredChatDraft copyWith({
    String? accountId,
    String? roomToken,
    String? scopeKey,
    String? draftText,
    int? updatedAtMillis,
  }) => StoredChatDraft(
    accountId: accountId ?? this.accountId,
    roomToken: roomToken ?? this.roomToken,
    scopeKey: scopeKey ?? this.scopeKey,
    draftText: draftText ?? this.draftText,
    updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
  );
  StoredChatDraft copyWithCompanion(ChatDraftsCompanion data) {
    return StoredChatDraft(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      roomToken: data.roomToken.present ? data.roomToken.value : this.roomToken,
      scopeKey: data.scopeKey.present ? data.scopeKey.value : this.scopeKey,
      draftText: data.draftText.present ? data.draftText.value : this.draftText,
      updatedAtMillis: data.updatedAtMillis.present
          ? data.updatedAtMillis.value
          : this.updatedAtMillis,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredChatDraft(')
          ..write('accountId: $accountId, ')
          ..write('roomToken: $roomToken, ')
          ..write('scopeKey: $scopeKey, ')
          ..write('draftText: $draftText, ')
          ..write('updatedAtMillis: $updatedAtMillis')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(accountId, roomToken, scopeKey, draftText, updatedAtMillis);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredChatDraft &&
          other.accountId == this.accountId &&
          other.roomToken == this.roomToken &&
          other.scopeKey == this.scopeKey &&
          other.draftText == this.draftText &&
          other.updatedAtMillis == this.updatedAtMillis);
}

class ChatDraftsCompanion extends UpdateCompanion<StoredChatDraft> {
  final Value<String> accountId;
  final Value<String> roomToken;
  final Value<String> scopeKey;
  final Value<String> draftText;
  final Value<int> updatedAtMillis;
  final Value<int> rowid;
  const ChatDraftsCompanion({
    this.accountId = const Value.absent(),
    this.roomToken = const Value.absent(),
    this.scopeKey = const Value.absent(),
    this.draftText = const Value.absent(),
    this.updatedAtMillis = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChatDraftsCompanion.insert({
    required String accountId,
    required String roomToken,
    required String scopeKey,
    required String draftText,
    required int updatedAtMillis,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       roomToken = Value(roomToken),
       scopeKey = Value(scopeKey),
       draftText = Value(draftText),
       updatedAtMillis = Value(updatedAtMillis);
  static Insertable<StoredChatDraft> custom({
    Expression<String>? accountId,
    Expression<String>? roomToken,
    Expression<String>? scopeKey,
    Expression<String>? draftText,
    Expression<int>? updatedAtMillis,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (roomToken != null) 'room_token': roomToken,
      if (scopeKey != null) 'scope_key': scopeKey,
      if (draftText != null) 'draft_text': draftText,
      if (updatedAtMillis != null) 'updated_at_millis': updatedAtMillis,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChatDraftsCompanion copyWith({
    Value<String>? accountId,
    Value<String>? roomToken,
    Value<String>? scopeKey,
    Value<String>? draftText,
    Value<int>? updatedAtMillis,
    Value<int>? rowid,
  }) {
    return ChatDraftsCompanion(
      accountId: accountId ?? this.accountId,
      roomToken: roomToken ?? this.roomToken,
      scopeKey: scopeKey ?? this.scopeKey,
      draftText: draftText ?? this.draftText,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (roomToken.present) {
      map['room_token'] = Variable<String>(roomToken.value);
    }
    if (scopeKey.present) {
      map['scope_key'] = Variable<String>(scopeKey.value);
    }
    if (draftText.present) {
      map['draft_text'] = Variable<String>(draftText.value);
    }
    if (updatedAtMillis.present) {
      map['updated_at_millis'] = Variable<int>(updatedAtMillis.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatDraftsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('roomToken: $roomToken, ')
          ..write('scopeKey: $scopeKey, ')
          ..write('draftText: $draftText, ')
          ..write('updatedAtMillis: $updatedAtMillis, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AttachmentRuntimeAccountsTable extends AttachmentRuntimeAccounts
    with
        TableInfo<
          $AttachmentRuntimeAccountsTable,
          StoredAttachmentRuntimeAccount
        > {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AttachmentRuntimeAccountsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES accounts (id)',
    ),
  );
  static const VerificationMeta _serverUrlMeta = const VerificationMeta(
    'serverUrl',
  );
  @override
  late final GeneratedColumn<String> serverUrl = GeneratedColumn<String>(
    'server_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _laneMeta = const VerificationMeta('lane');
  @override
  late final GeneratedColumn<String> lane = GeneratedColumn<String>(
    'lane',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _credentialGenerationMeta =
      const VerificationMeta('credentialGeneration');
  @override
  late final GeneratedColumn<int> credentialGeneration = GeneratedColumn<int>(
    'credential_generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _capabilityGenerationMeta =
      const VerificationMeta('capabilityGeneration');
  @override
  late final GeneratedColumn<int> capabilityGeneration = GeneratedColumn<int>(
    'capability_generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMillisMeta = const VerificationMeta(
    'updatedAtMillis',
  );
  @override
  late final GeneratedColumn<int> updatedAtMillis = GeneratedColumn<int>(
    'updated_at_millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    serverUrl,
    lane,
    credentialGeneration,
    capabilityGeneration,
    updatedAtMillis,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'attachment_runtime_accounts';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredAttachmentRuntimeAccount> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('server_url')) {
      context.handle(
        _serverUrlMeta,
        serverUrl.isAcceptableOrUnknown(data['server_url']!, _serverUrlMeta),
      );
    } else if (isInserting) {
      context.missing(_serverUrlMeta);
    }
    if (data.containsKey('lane')) {
      context.handle(
        _laneMeta,
        lane.isAcceptableOrUnknown(data['lane']!, _laneMeta),
      );
    } else if (isInserting) {
      context.missing(_laneMeta);
    }
    if (data.containsKey('credential_generation')) {
      context.handle(
        _credentialGenerationMeta,
        credentialGeneration.isAcceptableOrUnknown(
          data['credential_generation']!,
          _credentialGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_credentialGenerationMeta);
    }
    if (data.containsKey('capability_generation')) {
      context.handle(
        _capabilityGenerationMeta,
        capabilityGeneration.isAcceptableOrUnknown(
          data['capability_generation']!,
          _capabilityGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_capabilityGenerationMeta);
    }
    if (data.containsKey('updated_at_millis')) {
      context.handle(
        _updatedAtMillisMeta,
        updatedAtMillis.isAcceptableOrUnknown(
          data['updated_at_millis']!,
          _updatedAtMillisMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMillisMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId};
  @override
  StoredAttachmentRuntimeAccount map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredAttachmentRuntimeAccount(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      serverUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_url'],
      )!,
      lane: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}lane'],
      )!,
      credentialGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}credential_generation'],
      )!,
      capabilityGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}capability_generation'],
      )!,
      updatedAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_millis'],
      )!,
    );
  }

  @override
  $AttachmentRuntimeAccountsTable createAlias(String alias) {
    return $AttachmentRuntimeAccountsTable(attachedDatabase, alias);
  }
}

class StoredAttachmentRuntimeAccount extends DataClass
    implements Insertable<StoredAttachmentRuntimeAccount> {
  final String accountId;
  final String serverUrl;
  final String lane;
  final int credentialGeneration;
  final int capabilityGeneration;
  final int updatedAtMillis;
  const StoredAttachmentRuntimeAccount({
    required this.accountId,
    required this.serverUrl,
    required this.lane,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required this.updatedAtMillis,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['server_url'] = Variable<String>(serverUrl);
    map['lane'] = Variable<String>(lane);
    map['credential_generation'] = Variable<int>(credentialGeneration);
    map['capability_generation'] = Variable<int>(capabilityGeneration);
    map['updated_at_millis'] = Variable<int>(updatedAtMillis);
    return map;
  }

  AttachmentRuntimeAccountsCompanion toCompanion(bool nullToAbsent) {
    return AttachmentRuntimeAccountsCompanion(
      accountId: Value(accountId),
      serverUrl: Value(serverUrl),
      lane: Value(lane),
      credentialGeneration: Value(credentialGeneration),
      capabilityGeneration: Value(capabilityGeneration),
      updatedAtMillis: Value(updatedAtMillis),
    );
  }

  factory StoredAttachmentRuntimeAccount.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredAttachmentRuntimeAccount(
      accountId: serializer.fromJson<String>(json['accountId']),
      serverUrl: serializer.fromJson<String>(json['serverUrl']),
      lane: serializer.fromJson<String>(json['lane']),
      credentialGeneration: serializer.fromJson<int>(
        json['credentialGeneration'],
      ),
      capabilityGeneration: serializer.fromJson<int>(
        json['capabilityGeneration'],
      ),
      updatedAtMillis: serializer.fromJson<int>(json['updatedAtMillis']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'serverUrl': serializer.toJson<String>(serverUrl),
      'lane': serializer.toJson<String>(lane),
      'credentialGeneration': serializer.toJson<int>(credentialGeneration),
      'capabilityGeneration': serializer.toJson<int>(capabilityGeneration),
      'updatedAtMillis': serializer.toJson<int>(updatedAtMillis),
    };
  }

  StoredAttachmentRuntimeAccount copyWith({
    String? accountId,
    String? serverUrl,
    String? lane,
    int? credentialGeneration,
    int? capabilityGeneration,
    int? updatedAtMillis,
  }) => StoredAttachmentRuntimeAccount(
    accountId: accountId ?? this.accountId,
    serverUrl: serverUrl ?? this.serverUrl,
    lane: lane ?? this.lane,
    credentialGeneration: credentialGeneration ?? this.credentialGeneration,
    capabilityGeneration: capabilityGeneration ?? this.capabilityGeneration,
    updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
  );
  StoredAttachmentRuntimeAccount copyWithCompanion(
    AttachmentRuntimeAccountsCompanion data,
  ) {
    return StoredAttachmentRuntimeAccount(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      serverUrl: data.serverUrl.present ? data.serverUrl.value : this.serverUrl,
      lane: data.lane.present ? data.lane.value : this.lane,
      credentialGeneration: data.credentialGeneration.present
          ? data.credentialGeneration.value
          : this.credentialGeneration,
      capabilityGeneration: data.capabilityGeneration.present
          ? data.capabilityGeneration.value
          : this.capabilityGeneration,
      updatedAtMillis: data.updatedAtMillis.present
          ? data.updatedAtMillis.value
          : this.updatedAtMillis,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredAttachmentRuntimeAccount(')
          ..write('accountId: $accountId, ')
          ..write('serverUrl: $serverUrl, ')
          ..write('lane: $lane, ')
          ..write('credentialGeneration: $credentialGeneration, ')
          ..write('capabilityGeneration: $capabilityGeneration, ')
          ..write('updatedAtMillis: $updatedAtMillis')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    serverUrl,
    lane,
    credentialGeneration,
    capabilityGeneration,
    updatedAtMillis,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredAttachmentRuntimeAccount &&
          other.accountId == this.accountId &&
          other.serverUrl == this.serverUrl &&
          other.lane == this.lane &&
          other.credentialGeneration == this.credentialGeneration &&
          other.capabilityGeneration == this.capabilityGeneration &&
          other.updatedAtMillis == this.updatedAtMillis);
}

class AttachmentRuntimeAccountsCompanion
    extends UpdateCompanion<StoredAttachmentRuntimeAccount> {
  final Value<String> accountId;
  final Value<String> serverUrl;
  final Value<String> lane;
  final Value<int> credentialGeneration;
  final Value<int> capabilityGeneration;
  final Value<int> updatedAtMillis;
  final Value<int> rowid;
  const AttachmentRuntimeAccountsCompanion({
    this.accountId = const Value.absent(),
    this.serverUrl = const Value.absent(),
    this.lane = const Value.absent(),
    this.credentialGeneration = const Value.absent(),
    this.capabilityGeneration = const Value.absent(),
    this.updatedAtMillis = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AttachmentRuntimeAccountsCompanion.insert({
    required String accountId,
    required String serverUrl,
    required String lane,
    required int credentialGeneration,
    required int capabilityGeneration,
    required int updatedAtMillis,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       serverUrl = Value(serverUrl),
       lane = Value(lane),
       credentialGeneration = Value(credentialGeneration),
       capabilityGeneration = Value(capabilityGeneration),
       updatedAtMillis = Value(updatedAtMillis);
  static Insertable<StoredAttachmentRuntimeAccount> custom({
    Expression<String>? accountId,
    Expression<String>? serverUrl,
    Expression<String>? lane,
    Expression<int>? credentialGeneration,
    Expression<int>? capabilityGeneration,
    Expression<int>? updatedAtMillis,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (serverUrl != null) 'server_url': serverUrl,
      if (lane != null) 'lane': lane,
      if (credentialGeneration != null)
        'credential_generation': credentialGeneration,
      if (capabilityGeneration != null)
        'capability_generation': capabilityGeneration,
      if (updatedAtMillis != null) 'updated_at_millis': updatedAtMillis,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AttachmentRuntimeAccountsCompanion copyWith({
    Value<String>? accountId,
    Value<String>? serverUrl,
    Value<String>? lane,
    Value<int>? credentialGeneration,
    Value<int>? capabilityGeneration,
    Value<int>? updatedAtMillis,
    Value<int>? rowid,
  }) {
    return AttachmentRuntimeAccountsCompanion(
      accountId: accountId ?? this.accountId,
      serverUrl: serverUrl ?? this.serverUrl,
      lane: lane ?? this.lane,
      credentialGeneration: credentialGeneration ?? this.credentialGeneration,
      capabilityGeneration: capabilityGeneration ?? this.capabilityGeneration,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (serverUrl.present) {
      map['server_url'] = Variable<String>(serverUrl.value);
    }
    if (lane.present) {
      map['lane'] = Variable<String>(lane.value);
    }
    if (credentialGeneration.present) {
      map['credential_generation'] = Variable<int>(credentialGeneration.value);
    }
    if (capabilityGeneration.present) {
      map['capability_generation'] = Variable<int>(capabilityGeneration.value);
    }
    if (updatedAtMillis.present) {
      map['updated_at_millis'] = Variable<int>(updatedAtMillis.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AttachmentRuntimeAccountsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('serverUrl: $serverUrl, ')
          ..write('lane: $lane, ')
          ..write('credentialGeneration: $credentialGeneration, ')
          ..write('capabilityGeneration: $capabilityGeneration, ')
          ..write('updatedAtMillis: $updatedAtMillis, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AttachmentJobsTable extends AttachmentJobs
    with TableInfo<$AttachmentJobsTable, StoredAttachmentJob> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AttachmentJobsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES attachment_runtime_accounts (account_id)',
    ),
  );
  static const VerificationMeta _jobIdMeta = const VerificationMeta('jobId');
  @override
  late final GeneratedColumn<String> jobId = GeneratedColumn<String>(
    'job_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverUrlMeta = const VerificationMeta(
    'serverUrl',
  );
  @override
  late final GeneratedColumn<String> serverUrl = GeneratedColumn<String>(
    'server_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _capabilityGenerationMeta =
      const VerificationMeta('capabilityGeneration');
  @override
  late final GeneratedColumn<int> capabilityGeneration = GeneratedColumn<int>(
    'capability_generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _replayContractRevisionMeta =
      const VerificationMeta('replayContractRevision');
  @override
  late final GeneratedColumn<String> replayContractRevision =
      GeneratedColumn<String>(
        'replay_contract_revision',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _davUserIdMeta = const VerificationMeta(
    'davUserId',
  );
  @override
  late final GeneratedColumn<String> davUserId = GeneratedColumn<String>(
    'dav_user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roomTokenMeta = const VerificationMeta(
    'roomToken',
  );
  @override
  late final GeneratedColumn<String> roomToken = GeneratedColumn<String>(
    'room_token',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _referenceIdMeta = const VerificationMeta(
    'referenceId',
  );
  @override
  late final GeneratedColumn<String> referenceId = GeneratedColumn<String>(
    'reference_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceHandleMeta = const VerificationMeta(
    'sourceHandle',
  );
  @override
  late final GeneratedColumn<String> sourceHandle = GeneratedColumn<String>(
    'source_handle',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceOwnershipMeta = const VerificationMeta(
    'sourceOwnership',
  );
  @override
  late final GeneratedColumn<String> sourceOwnership = GeneratedColumn<String>(
    'source_ownership',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceByteLengthMeta = const VerificationMeta(
    'sourceByteLength',
  );
  @override
  late final GeneratedColumn<int> sourceByteLength = GeneratedColumn<int>(
    'source_byte_length',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceSha256Meta = const VerificationMeta(
    'sourceSha256',
  );
  @override
  late final GeneratedColumn<String> sourceSha256 = GeneratedColumn<String>(
    'source_sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMimeTypeMeta = const VerificationMeta(
    'sourceMimeType',
  );
  @override
  late final GeneratedColumn<String> sourceMimeType = GeneratedColumn<String>(
    'source_mime_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceDisplayNameMeta = const VerificationMeta(
    'sourceDisplayName',
  );
  @override
  late final GeneratedColumn<String> sourceDisplayName =
      GeneratedColumn<String>(
        'source_display_name',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _messageKindMeta = const VerificationMeta(
    'messageKind',
  );
  @override
  late final GeneratedColumn<String> messageKind = GeneratedColumn<String>(
    'message_kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _captionMeta = const VerificationMeta(
    'caption',
  );
  @override
  late final GeneratedColumn<String> caption = GeneratedColumn<String>(
    'caption',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _replyToMeta = const VerificationMeta(
    'replyTo',
  );
  @override
  late final GeneratedColumn<int> replyTo = GeneratedColumn<int>(
    'reply_to',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _threadIdMeta = const VerificationMeta(
    'threadId',
  );
  @override
  late final GeneratedColumn<int> threadId = GeneratedColumn<int>(
    'thread_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _threadTitleMeta = const VerificationMeta(
    'threadTitle',
  );
  @override
  late final GeneratedColumn<String> threadTitle = GeneratedColumn<String>(
    'thread_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _silentMeta = const VerificationMeta('silent');
  @override
  late final GeneratedColumn<bool> silent = GeneratedColumn<bool>(
    'silent',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("silent" IN (0, 1))',
    ),
  );
  static const VerificationMeta _enqueueSequenceMeta = const VerificationMeta(
    'enqueueSequence',
  );
  @override
  late final GeneratedColumn<int> enqueueSequence = GeneratedColumn<int>(
    'enqueue_sequence',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _normalUploadMaximumBytesMeta =
      const VerificationMeta('normalUploadMaximumBytes');
  @override
  late final GeneratedColumn<int> normalUploadMaximumBytes =
      GeneratedColumn<int>(
        'normal_upload_maximum_bytes',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _chunkSizeBytesMeta = const VerificationMeta(
    'chunkSizeBytes',
  );
  @override
  late final GeneratedColumn<int> chunkSizeBytes = GeneratedColumn<int>(
    'chunk_size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _uploadSessionIdMeta = const VerificationMeta(
    'uploadSessionId',
  );
  @override
  late final GeneratedColumn<String> uploadSessionId = GeneratedColumn<String>(
    'upload_session_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _phaseMeta = const VerificationMeta('phase');
  @override
  late final GeneratedColumn<String> phase = GeneratedColumn<String>(
    'phase',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resumePhaseMeta = const VerificationMeta(
    'resumePhase',
  );
  @override
  late final GeneratedColumn<String> resumePhase = GeneratedColumn<String>(
    'resume_phase',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteDraftFolderMeta = const VerificationMeta(
    'remoteDraftFolder',
  );
  @override
  late final GeneratedColumn<String> remoteDraftFolder =
      GeneratedColumn<String>(
        'remote_draft_folder',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _remoteTemporaryPathMeta =
      const VerificationMeta('remoteTemporaryPath');
  @override
  late final GeneratedColumn<String> remoteTemporaryPath =
      GeneratedColumn<String>(
        'remote_temporary_path',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _chunkCollectionReadyMeta =
      const VerificationMeta('chunkCollectionReady');
  @override
  late final GeneratedColumn<bool> chunkCollectionReady = GeneratedColumn<bool>(
    'chunk_collection_ready',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("chunk_collection_ready" IN (0, 1))',
    ),
  );
  static const VerificationMeta _chunkManifestLoadedMeta =
      const VerificationMeta('chunkManifestLoaded');
  @override
  late final GeneratedColumn<bool> chunkManifestLoaded = GeneratedColumn<bool>(
    'chunk_manifest_loaded',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("chunk_manifest_loaded" IN (0, 1))',
    ),
  );
  static const VerificationMeta _verifiedChunksJsonMeta =
      const VerificationMeta('verifiedChunksJson');
  @override
  late final GeneratedColumn<String> verifiedChunksJson =
      GeneratedColumn<String>(
        'verified_chunks_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _inFlightStepMeta = const VerificationMeta(
    'inFlightStep',
  );
  @override
  late final GeneratedColumn<String> inFlightStep = GeneratedColumn<String>(
    'in_flight_step',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _inFlightRequestIdMeta = const VerificationMeta(
    'inFlightRequestId',
  );
  @override
  late final GeneratedColumn<String> inFlightRequestId =
      GeneratedColumn<String>(
        'in_flight_request_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _attemptCountMeta = const VerificationMeta(
    'attemptCount',
  );
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
    'attempt_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _finalizationDispatchedMeta =
      const VerificationMeta('finalizationDispatched');
  @override
  late final GeneratedColumn<bool> finalizationDispatched =
      GeneratedColumn<bool>(
        'finalization_dispatched',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: true,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("finalization_dispatched" IN (0, 1))',
        ),
      );
  static const VerificationMeta _cleanupChunkSessionMeta =
      const VerificationMeta('cleanupChunkSession');
  @override
  late final GeneratedColumn<bool> cleanupChunkSession = GeneratedColumn<bool>(
    'cleanup_chunk_session',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("cleanup_chunk_session" IN (0, 1))',
    ),
  );
  static const VerificationMeta _cleanupDraftFileMeta = const VerificationMeta(
    'cleanupDraftFile',
  );
  @override
  late final GeneratedColumn<bool> cleanupDraftFile = GeneratedColumn<bool>(
    'cleanup_draft_file',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("cleanup_draft_file" IN (0, 1))',
    ),
  );
  static const VerificationMeta _messageIdsJsonMeta = const VerificationMeta(
    'messageIdsJson',
  );
  @override
  late final GeneratedColumn<String> messageIdsJson = GeneratedColumn<String>(
    'message_ids_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _errorClassMeta = const VerificationMeta(
    'errorClass',
  );
  @override
  late final GeneratedColumn<String> errorClass = GeneratedColumn<String>(
    'error_class',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _profileFederatedMeta = const VerificationMeta(
    'profileFederated',
  );
  @override
  late final GeneratedColumn<bool> profileFederated = GeneratedColumn<bool>(
    'profile_federated',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("profile_federated" IN (0, 1))',
    ),
  );
  static const VerificationMeta _profileEnabledMeta = const VerificationMeta(
    'profileEnabled',
  );
  @override
  late final GeneratedColumn<bool> profileEnabled = GeneratedColumn<bool>(
    'profile_enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("profile_enabled" IN (0, 1))',
    ),
  );
  static const VerificationMeta _profileCaptionMeta = const VerificationMeta(
    'profileCaption',
  );
  @override
  late final GeneratedColumn<bool> profileCaption = GeneratedColumn<bool>(
    'profile_caption',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("profile_caption" IN (0, 1))',
    ),
  );
  static const VerificationMeta _profileVoiceMeta = const VerificationMeta(
    'profileVoice',
  );
  @override
  late final GeneratedColumn<bool> profileVoice = GeneratedColumn<bool>(
    'profile_voice',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("profile_voice" IN (0, 1))',
    ),
  );
  static const VerificationMeta _profileReplyMeta = const VerificationMeta(
    'profileReply',
  );
  @override
  late final GeneratedColumn<bool> profileReply = GeneratedColumn<bool>(
    'profile_reply',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("profile_reply" IN (0, 1))',
    ),
  );
  static const VerificationMeta _profileThreadsMeta = const VerificationMeta(
    'profileThreads',
  );
  @override
  late final GeneratedColumn<bool> profileThreads = GeneratedColumn<bool>(
    'profile_threads',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("profile_threads" IN (0, 1))',
    ),
  );
  static const VerificationMeta _profileSilentMeta = const VerificationMeta(
    'profileSilent',
  );
  @override
  late final GeneratedColumn<bool> profileSilent = GeneratedColumn<bool>(
    'profile_silent',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("profile_silent" IN (0, 1))',
    ),
  );
  static const VerificationMeta _roomCanWriteMeta = const VerificationMeta(
    'roomCanWrite',
  );
  @override
  late final GeneratedColumn<bool> roomCanWrite = GeneratedColumn<bool>(
    'room_can_write',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("room_can_write" IN (0, 1))',
    ),
  );
  static const VerificationMeta _automaticRetryCountMeta =
      const VerificationMeta('automaticRetryCount');
  @override
  late final GeneratedColumn<int> automaticRetryCount = GeneratedColumn<int>(
    'automatic_retry_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _nextAttemptAtMillisMeta =
      const VerificationMeta('nextAttemptAtMillis');
  @override
  late final GeneratedColumn<int> nextAttemptAtMillis = GeneratedColumn<int>(
    'next_attempt_at_millis',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceReleasedMeta = const VerificationMeta(
    'sourceReleased',
  );
  @override
  late final GeneratedColumn<bool> sourceReleased = GeneratedColumn<bool>(
    'source_released',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("source_released" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _localCleanupErrorMeta = const VerificationMeta(
    'localCleanupError',
  );
  @override
  late final GeneratedColumn<String> localCleanupError =
      GeneratedColumn<String>(
        'local_cleanup_error',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _createdAtMillisMeta = const VerificationMeta(
    'createdAtMillis',
  );
  @override
  late final GeneratedColumn<int> createdAtMillis = GeneratedColumn<int>(
    'created_at_millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMillisMeta = const VerificationMeta(
    'updatedAtMillis',
  );
  @override
  late final GeneratedColumn<int> updatedAtMillis = GeneratedColumn<int>(
    'updated_at_millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    jobId,
    serverUrl,
    capabilityGeneration,
    replayContractRevision,
    davUserId,
    roomToken,
    referenceId,
    sourceHandle,
    sourceOwnership,
    sourceByteLength,
    sourceSha256,
    sourceMimeType,
    sourceDisplayName,
    messageKind,
    caption,
    replyTo,
    threadId,
    threadTitle,
    silent,
    enqueueSequence,
    normalUploadMaximumBytes,
    chunkSizeBytes,
    uploadSessionId,
    phase,
    resumePhase,
    remoteDraftFolder,
    remoteTemporaryPath,
    chunkCollectionReady,
    chunkManifestLoaded,
    verifiedChunksJson,
    inFlightStep,
    inFlightRequestId,
    attemptCount,
    finalizationDispatched,
    cleanupChunkSession,
    cleanupDraftFile,
    messageIdsJson,
    errorClass,
    profileFederated,
    profileEnabled,
    profileCaption,
    profileVoice,
    profileReply,
    profileThreads,
    profileSilent,
    roomCanWrite,
    automaticRetryCount,
    nextAttemptAtMillis,
    sourceReleased,
    localCleanupError,
    createdAtMillis,
    updatedAtMillis,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'attachment_jobs';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredAttachmentJob> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('job_id')) {
      context.handle(
        _jobIdMeta,
        jobId.isAcceptableOrUnknown(data['job_id']!, _jobIdMeta),
      );
    } else if (isInserting) {
      context.missing(_jobIdMeta);
    }
    if (data.containsKey('server_url')) {
      context.handle(
        _serverUrlMeta,
        serverUrl.isAcceptableOrUnknown(data['server_url']!, _serverUrlMeta),
      );
    } else if (isInserting) {
      context.missing(_serverUrlMeta);
    }
    if (data.containsKey('capability_generation')) {
      context.handle(
        _capabilityGenerationMeta,
        capabilityGeneration.isAcceptableOrUnknown(
          data['capability_generation']!,
          _capabilityGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_capabilityGenerationMeta);
    }
    if (data.containsKey('replay_contract_revision')) {
      context.handle(
        _replayContractRevisionMeta,
        replayContractRevision.isAcceptableOrUnknown(
          data['replay_contract_revision']!,
          _replayContractRevisionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_replayContractRevisionMeta);
    }
    if (data.containsKey('dav_user_id')) {
      context.handle(
        _davUserIdMeta,
        davUserId.isAcceptableOrUnknown(data['dav_user_id']!, _davUserIdMeta),
      );
    } else if (isInserting) {
      context.missing(_davUserIdMeta);
    }
    if (data.containsKey('room_token')) {
      context.handle(
        _roomTokenMeta,
        roomToken.isAcceptableOrUnknown(data['room_token']!, _roomTokenMeta),
      );
    } else if (isInserting) {
      context.missing(_roomTokenMeta);
    }
    if (data.containsKey('reference_id')) {
      context.handle(
        _referenceIdMeta,
        referenceId.isAcceptableOrUnknown(
          data['reference_id']!,
          _referenceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_referenceIdMeta);
    }
    if (data.containsKey('source_handle')) {
      context.handle(
        _sourceHandleMeta,
        sourceHandle.isAcceptableOrUnknown(
          data['source_handle']!,
          _sourceHandleMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceHandleMeta);
    }
    if (data.containsKey('source_ownership')) {
      context.handle(
        _sourceOwnershipMeta,
        sourceOwnership.isAcceptableOrUnknown(
          data['source_ownership']!,
          _sourceOwnershipMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceOwnershipMeta);
    }
    if (data.containsKey('source_byte_length')) {
      context.handle(
        _sourceByteLengthMeta,
        sourceByteLength.isAcceptableOrUnknown(
          data['source_byte_length']!,
          _sourceByteLengthMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceByteLengthMeta);
    }
    if (data.containsKey('source_sha256')) {
      context.handle(
        _sourceSha256Meta,
        sourceSha256.isAcceptableOrUnknown(
          data['source_sha256']!,
          _sourceSha256Meta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceSha256Meta);
    }
    if (data.containsKey('source_mime_type')) {
      context.handle(
        _sourceMimeTypeMeta,
        sourceMimeType.isAcceptableOrUnknown(
          data['source_mime_type']!,
          _sourceMimeTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceMimeTypeMeta);
    }
    if (data.containsKey('source_display_name')) {
      context.handle(
        _sourceDisplayNameMeta,
        sourceDisplayName.isAcceptableOrUnknown(
          data['source_display_name']!,
          _sourceDisplayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceDisplayNameMeta);
    }
    if (data.containsKey('message_kind')) {
      context.handle(
        _messageKindMeta,
        messageKind.isAcceptableOrUnknown(
          data['message_kind']!,
          _messageKindMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_messageKindMeta);
    }
    if (data.containsKey('caption')) {
      context.handle(
        _captionMeta,
        caption.isAcceptableOrUnknown(data['caption']!, _captionMeta),
      );
    }
    if (data.containsKey('reply_to')) {
      context.handle(
        _replyToMeta,
        replyTo.isAcceptableOrUnknown(data['reply_to']!, _replyToMeta),
      );
    }
    if (data.containsKey('thread_id')) {
      context.handle(
        _threadIdMeta,
        threadId.isAcceptableOrUnknown(data['thread_id']!, _threadIdMeta),
      );
    }
    if (data.containsKey('thread_title')) {
      context.handle(
        _threadTitleMeta,
        threadTitle.isAcceptableOrUnknown(
          data['thread_title']!,
          _threadTitleMeta,
        ),
      );
    }
    if (data.containsKey('silent')) {
      context.handle(
        _silentMeta,
        silent.isAcceptableOrUnknown(data['silent']!, _silentMeta),
      );
    } else if (isInserting) {
      context.missing(_silentMeta);
    }
    if (data.containsKey('enqueue_sequence')) {
      context.handle(
        _enqueueSequenceMeta,
        enqueueSequence.isAcceptableOrUnknown(
          data['enqueue_sequence']!,
          _enqueueSequenceMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_enqueueSequenceMeta);
    }
    if (data.containsKey('normal_upload_maximum_bytes')) {
      context.handle(
        _normalUploadMaximumBytesMeta,
        normalUploadMaximumBytes.isAcceptableOrUnknown(
          data['normal_upload_maximum_bytes']!,
          _normalUploadMaximumBytesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_normalUploadMaximumBytesMeta);
    }
    if (data.containsKey('chunk_size_bytes')) {
      context.handle(
        _chunkSizeBytesMeta,
        chunkSizeBytes.isAcceptableOrUnknown(
          data['chunk_size_bytes']!,
          _chunkSizeBytesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_chunkSizeBytesMeta);
    }
    if (data.containsKey('upload_session_id')) {
      context.handle(
        _uploadSessionIdMeta,
        uploadSessionId.isAcceptableOrUnknown(
          data['upload_session_id']!,
          _uploadSessionIdMeta,
        ),
      );
    }
    if (data.containsKey('phase')) {
      context.handle(
        _phaseMeta,
        phase.isAcceptableOrUnknown(data['phase']!, _phaseMeta),
      );
    } else if (isInserting) {
      context.missing(_phaseMeta);
    }
    if (data.containsKey('resume_phase')) {
      context.handle(
        _resumePhaseMeta,
        resumePhase.isAcceptableOrUnknown(
          data['resume_phase']!,
          _resumePhaseMeta,
        ),
      );
    }
    if (data.containsKey('remote_draft_folder')) {
      context.handle(
        _remoteDraftFolderMeta,
        remoteDraftFolder.isAcceptableOrUnknown(
          data['remote_draft_folder']!,
          _remoteDraftFolderMeta,
        ),
      );
    }
    if (data.containsKey('remote_temporary_path')) {
      context.handle(
        _remoteTemporaryPathMeta,
        remoteTemporaryPath.isAcceptableOrUnknown(
          data['remote_temporary_path']!,
          _remoteTemporaryPathMeta,
        ),
      );
    }
    if (data.containsKey('chunk_collection_ready')) {
      context.handle(
        _chunkCollectionReadyMeta,
        chunkCollectionReady.isAcceptableOrUnknown(
          data['chunk_collection_ready']!,
          _chunkCollectionReadyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_chunkCollectionReadyMeta);
    }
    if (data.containsKey('chunk_manifest_loaded')) {
      context.handle(
        _chunkManifestLoadedMeta,
        chunkManifestLoaded.isAcceptableOrUnknown(
          data['chunk_manifest_loaded']!,
          _chunkManifestLoadedMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_chunkManifestLoadedMeta);
    }
    if (data.containsKey('verified_chunks_json')) {
      context.handle(
        _verifiedChunksJsonMeta,
        verifiedChunksJson.isAcceptableOrUnknown(
          data['verified_chunks_json']!,
          _verifiedChunksJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_verifiedChunksJsonMeta);
    }
    if (data.containsKey('in_flight_step')) {
      context.handle(
        _inFlightStepMeta,
        inFlightStep.isAcceptableOrUnknown(
          data['in_flight_step']!,
          _inFlightStepMeta,
        ),
      );
    }
    if (data.containsKey('in_flight_request_id')) {
      context.handle(
        _inFlightRequestIdMeta,
        inFlightRequestId.isAcceptableOrUnknown(
          data['in_flight_request_id']!,
          _inFlightRequestIdMeta,
        ),
      );
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
        _attemptCountMeta,
        attemptCount.isAcceptableOrUnknown(
          data['attempt_count']!,
          _attemptCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_attemptCountMeta);
    }
    if (data.containsKey('finalization_dispatched')) {
      context.handle(
        _finalizationDispatchedMeta,
        finalizationDispatched.isAcceptableOrUnknown(
          data['finalization_dispatched']!,
          _finalizationDispatchedMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_finalizationDispatchedMeta);
    }
    if (data.containsKey('cleanup_chunk_session')) {
      context.handle(
        _cleanupChunkSessionMeta,
        cleanupChunkSession.isAcceptableOrUnknown(
          data['cleanup_chunk_session']!,
          _cleanupChunkSessionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_cleanupChunkSessionMeta);
    }
    if (data.containsKey('cleanup_draft_file')) {
      context.handle(
        _cleanupDraftFileMeta,
        cleanupDraftFile.isAcceptableOrUnknown(
          data['cleanup_draft_file']!,
          _cleanupDraftFileMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_cleanupDraftFileMeta);
    }
    if (data.containsKey('message_ids_json')) {
      context.handle(
        _messageIdsJsonMeta,
        messageIdsJson.isAcceptableOrUnknown(
          data['message_ids_json']!,
          _messageIdsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_messageIdsJsonMeta);
    }
    if (data.containsKey('error_class')) {
      context.handle(
        _errorClassMeta,
        errorClass.isAcceptableOrUnknown(data['error_class']!, _errorClassMeta),
      );
    }
    if (data.containsKey('profile_federated')) {
      context.handle(
        _profileFederatedMeta,
        profileFederated.isAcceptableOrUnknown(
          data['profile_federated']!,
          _profileFederatedMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_profileFederatedMeta);
    }
    if (data.containsKey('profile_enabled')) {
      context.handle(
        _profileEnabledMeta,
        profileEnabled.isAcceptableOrUnknown(
          data['profile_enabled']!,
          _profileEnabledMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_profileEnabledMeta);
    }
    if (data.containsKey('profile_caption')) {
      context.handle(
        _profileCaptionMeta,
        profileCaption.isAcceptableOrUnknown(
          data['profile_caption']!,
          _profileCaptionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_profileCaptionMeta);
    }
    if (data.containsKey('profile_voice')) {
      context.handle(
        _profileVoiceMeta,
        profileVoice.isAcceptableOrUnknown(
          data['profile_voice']!,
          _profileVoiceMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_profileVoiceMeta);
    }
    if (data.containsKey('profile_reply')) {
      context.handle(
        _profileReplyMeta,
        profileReply.isAcceptableOrUnknown(
          data['profile_reply']!,
          _profileReplyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_profileReplyMeta);
    }
    if (data.containsKey('profile_threads')) {
      context.handle(
        _profileThreadsMeta,
        profileThreads.isAcceptableOrUnknown(
          data['profile_threads']!,
          _profileThreadsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_profileThreadsMeta);
    }
    if (data.containsKey('profile_silent')) {
      context.handle(
        _profileSilentMeta,
        profileSilent.isAcceptableOrUnknown(
          data['profile_silent']!,
          _profileSilentMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_profileSilentMeta);
    }
    if (data.containsKey('room_can_write')) {
      context.handle(
        _roomCanWriteMeta,
        roomCanWrite.isAcceptableOrUnknown(
          data['room_can_write']!,
          _roomCanWriteMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_roomCanWriteMeta);
    }
    if (data.containsKey('automatic_retry_count')) {
      context.handle(
        _automaticRetryCountMeta,
        automaticRetryCount.isAcceptableOrUnknown(
          data['automatic_retry_count']!,
          _automaticRetryCountMeta,
        ),
      );
    }
    if (data.containsKey('next_attempt_at_millis')) {
      context.handle(
        _nextAttemptAtMillisMeta,
        nextAttemptAtMillis.isAcceptableOrUnknown(
          data['next_attempt_at_millis']!,
          _nextAttemptAtMillisMeta,
        ),
      );
    }
    if (data.containsKey('source_released')) {
      context.handle(
        _sourceReleasedMeta,
        sourceReleased.isAcceptableOrUnknown(
          data['source_released']!,
          _sourceReleasedMeta,
        ),
      );
    }
    if (data.containsKey('local_cleanup_error')) {
      context.handle(
        _localCleanupErrorMeta,
        localCleanupError.isAcceptableOrUnknown(
          data['local_cleanup_error']!,
          _localCleanupErrorMeta,
        ),
      );
    }
    if (data.containsKey('created_at_millis')) {
      context.handle(
        _createdAtMillisMeta,
        createdAtMillis.isAcceptableOrUnknown(
          data['created_at_millis']!,
          _createdAtMillisMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_createdAtMillisMeta);
    }
    if (data.containsKey('updated_at_millis')) {
      context.handle(
        _updatedAtMillisMeta,
        updatedAtMillis.isAcceptableOrUnknown(
          data['updated_at_millis']!,
          _updatedAtMillisMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMillisMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, jobId};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, referenceId},
    {accountId, roomToken, enqueueSequence},
  ];
  @override
  StoredAttachmentJob map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredAttachmentJob(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      jobId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}job_id'],
      )!,
      serverUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_url'],
      )!,
      capabilityGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}capability_generation'],
      )!,
      replayContractRevision: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}replay_contract_revision'],
      )!,
      davUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dav_user_id'],
      )!,
      roomToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_token'],
      )!,
      referenceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reference_id'],
      )!,
      sourceHandle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_handle'],
      )!,
      sourceOwnership: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_ownership'],
      )!,
      sourceByteLength: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}source_byte_length'],
      )!,
      sourceSha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_sha256'],
      )!,
      sourceMimeType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_mime_type'],
      )!,
      sourceDisplayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_display_name'],
      )!,
      messageKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_kind'],
      )!,
      caption: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}caption'],
      ),
      replyTo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reply_to'],
      ),
      threadId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}thread_id'],
      ),
      threadTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thread_title'],
      ),
      silent: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}silent'],
      )!,
      enqueueSequence: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}enqueue_sequence'],
      )!,
      normalUploadMaximumBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}normal_upload_maximum_bytes'],
      )!,
      chunkSizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}chunk_size_bytes'],
      )!,
      uploadSessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}upload_session_id'],
      ),
      phase: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}phase'],
      )!,
      resumePhase: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resume_phase'],
      ),
      remoteDraftFolder: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_draft_folder'],
      ),
      remoteTemporaryPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_temporary_path'],
      ),
      chunkCollectionReady: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}chunk_collection_ready'],
      )!,
      chunkManifestLoaded: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}chunk_manifest_loaded'],
      )!,
      verifiedChunksJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}verified_chunks_json'],
      )!,
      inFlightStep: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}in_flight_step'],
      ),
      inFlightRequestId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}in_flight_request_id'],
      ),
      attemptCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempt_count'],
      )!,
      finalizationDispatched: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}finalization_dispatched'],
      )!,
      cleanupChunkSession: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}cleanup_chunk_session'],
      )!,
      cleanupDraftFile: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}cleanup_draft_file'],
      )!,
      messageIdsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_ids_json'],
      )!,
      errorClass: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_class'],
      ),
      profileFederated: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}profile_federated'],
      )!,
      profileEnabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}profile_enabled'],
      )!,
      profileCaption: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}profile_caption'],
      )!,
      profileVoice: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}profile_voice'],
      )!,
      profileReply: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}profile_reply'],
      )!,
      profileThreads: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}profile_threads'],
      )!,
      profileSilent: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}profile_silent'],
      )!,
      roomCanWrite: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}room_can_write'],
      )!,
      automaticRetryCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}automatic_retry_count'],
      )!,
      nextAttemptAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_attempt_at_millis'],
      ),
      sourceReleased: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}source_released'],
      )!,
      localCleanupError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_cleanup_error'],
      ),
      createdAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_millis'],
      )!,
      updatedAtMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_millis'],
      )!,
    );
  }

  @override
  $AttachmentJobsTable createAlias(String alias) {
    return $AttachmentJobsTable(attachedDatabase, alias);
  }
}

class StoredAttachmentJob extends DataClass
    implements Insertable<StoredAttachmentJob> {
  final String accountId;
  final String jobId;
  final String serverUrl;
  final int capabilityGeneration;
  final String replayContractRevision;
  final String davUserId;
  final String roomToken;
  final String referenceId;
  final String sourceHandle;
  final String sourceOwnership;
  final int sourceByteLength;
  final String sourceSha256;
  final String sourceMimeType;
  final String sourceDisplayName;
  final String messageKind;
  final String? caption;
  final int? replyTo;
  final int? threadId;
  final String? threadTitle;
  final bool silent;
  final int enqueueSequence;
  final int normalUploadMaximumBytes;
  final int chunkSizeBytes;
  final String? uploadSessionId;
  final String phase;
  final String? resumePhase;
  final String? remoteDraftFolder;
  final String? remoteTemporaryPath;
  final bool chunkCollectionReady;
  final bool chunkManifestLoaded;
  final String verifiedChunksJson;
  final String? inFlightStep;
  final String? inFlightRequestId;
  final int attemptCount;
  final bool finalizationDispatched;
  final bool cleanupChunkSession;
  final bool cleanupDraftFile;
  final String messageIdsJson;
  final String? errorClass;
  final bool profileFederated;
  final bool profileEnabled;
  final bool profileCaption;
  final bool profileVoice;
  final bool profileReply;
  final bool profileThreads;
  final bool profileSilent;
  final bool roomCanWrite;
  final int automaticRetryCount;
  final int? nextAttemptAtMillis;
  final bool sourceReleased;
  final String? localCleanupError;
  final int createdAtMillis;
  final int updatedAtMillis;
  const StoredAttachmentJob({
    required this.accountId,
    required this.jobId,
    required this.serverUrl,
    required this.capabilityGeneration,
    required this.replayContractRevision,
    required this.davUserId,
    required this.roomToken,
    required this.referenceId,
    required this.sourceHandle,
    required this.sourceOwnership,
    required this.sourceByteLength,
    required this.sourceSha256,
    required this.sourceMimeType,
    required this.sourceDisplayName,
    required this.messageKind,
    this.caption,
    this.replyTo,
    this.threadId,
    this.threadTitle,
    required this.silent,
    required this.enqueueSequence,
    required this.normalUploadMaximumBytes,
    required this.chunkSizeBytes,
    this.uploadSessionId,
    required this.phase,
    this.resumePhase,
    this.remoteDraftFolder,
    this.remoteTemporaryPath,
    required this.chunkCollectionReady,
    required this.chunkManifestLoaded,
    required this.verifiedChunksJson,
    this.inFlightStep,
    this.inFlightRequestId,
    required this.attemptCount,
    required this.finalizationDispatched,
    required this.cleanupChunkSession,
    required this.cleanupDraftFile,
    required this.messageIdsJson,
    this.errorClass,
    required this.profileFederated,
    required this.profileEnabled,
    required this.profileCaption,
    required this.profileVoice,
    required this.profileReply,
    required this.profileThreads,
    required this.profileSilent,
    required this.roomCanWrite,
    required this.automaticRetryCount,
    this.nextAttemptAtMillis,
    required this.sourceReleased,
    this.localCleanupError,
    required this.createdAtMillis,
    required this.updatedAtMillis,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['job_id'] = Variable<String>(jobId);
    map['server_url'] = Variable<String>(serverUrl);
    map['capability_generation'] = Variable<int>(capabilityGeneration);
    map['replay_contract_revision'] = Variable<String>(replayContractRevision);
    map['dav_user_id'] = Variable<String>(davUserId);
    map['room_token'] = Variable<String>(roomToken);
    map['reference_id'] = Variable<String>(referenceId);
    map['source_handle'] = Variable<String>(sourceHandle);
    map['source_ownership'] = Variable<String>(sourceOwnership);
    map['source_byte_length'] = Variable<int>(sourceByteLength);
    map['source_sha256'] = Variable<String>(sourceSha256);
    map['source_mime_type'] = Variable<String>(sourceMimeType);
    map['source_display_name'] = Variable<String>(sourceDisplayName);
    map['message_kind'] = Variable<String>(messageKind);
    if (!nullToAbsent || caption != null) {
      map['caption'] = Variable<String>(caption);
    }
    if (!nullToAbsent || replyTo != null) {
      map['reply_to'] = Variable<int>(replyTo);
    }
    if (!nullToAbsent || threadId != null) {
      map['thread_id'] = Variable<int>(threadId);
    }
    if (!nullToAbsent || threadTitle != null) {
      map['thread_title'] = Variable<String>(threadTitle);
    }
    map['silent'] = Variable<bool>(silent);
    map['enqueue_sequence'] = Variable<int>(enqueueSequence);
    map['normal_upload_maximum_bytes'] = Variable<int>(
      normalUploadMaximumBytes,
    );
    map['chunk_size_bytes'] = Variable<int>(chunkSizeBytes);
    if (!nullToAbsent || uploadSessionId != null) {
      map['upload_session_id'] = Variable<String>(uploadSessionId);
    }
    map['phase'] = Variable<String>(phase);
    if (!nullToAbsent || resumePhase != null) {
      map['resume_phase'] = Variable<String>(resumePhase);
    }
    if (!nullToAbsent || remoteDraftFolder != null) {
      map['remote_draft_folder'] = Variable<String>(remoteDraftFolder);
    }
    if (!nullToAbsent || remoteTemporaryPath != null) {
      map['remote_temporary_path'] = Variable<String>(remoteTemporaryPath);
    }
    map['chunk_collection_ready'] = Variable<bool>(chunkCollectionReady);
    map['chunk_manifest_loaded'] = Variable<bool>(chunkManifestLoaded);
    map['verified_chunks_json'] = Variable<String>(verifiedChunksJson);
    if (!nullToAbsent || inFlightStep != null) {
      map['in_flight_step'] = Variable<String>(inFlightStep);
    }
    if (!nullToAbsent || inFlightRequestId != null) {
      map['in_flight_request_id'] = Variable<String>(inFlightRequestId);
    }
    map['attempt_count'] = Variable<int>(attemptCount);
    map['finalization_dispatched'] = Variable<bool>(finalizationDispatched);
    map['cleanup_chunk_session'] = Variable<bool>(cleanupChunkSession);
    map['cleanup_draft_file'] = Variable<bool>(cleanupDraftFile);
    map['message_ids_json'] = Variable<String>(messageIdsJson);
    if (!nullToAbsent || errorClass != null) {
      map['error_class'] = Variable<String>(errorClass);
    }
    map['profile_federated'] = Variable<bool>(profileFederated);
    map['profile_enabled'] = Variable<bool>(profileEnabled);
    map['profile_caption'] = Variable<bool>(profileCaption);
    map['profile_voice'] = Variable<bool>(profileVoice);
    map['profile_reply'] = Variable<bool>(profileReply);
    map['profile_threads'] = Variable<bool>(profileThreads);
    map['profile_silent'] = Variable<bool>(profileSilent);
    map['room_can_write'] = Variable<bool>(roomCanWrite);
    map['automatic_retry_count'] = Variable<int>(automaticRetryCount);
    if (!nullToAbsent || nextAttemptAtMillis != null) {
      map['next_attempt_at_millis'] = Variable<int>(nextAttemptAtMillis);
    }
    map['source_released'] = Variable<bool>(sourceReleased);
    if (!nullToAbsent || localCleanupError != null) {
      map['local_cleanup_error'] = Variable<String>(localCleanupError);
    }
    map['created_at_millis'] = Variable<int>(createdAtMillis);
    map['updated_at_millis'] = Variable<int>(updatedAtMillis);
    return map;
  }

  AttachmentJobsCompanion toCompanion(bool nullToAbsent) {
    return AttachmentJobsCompanion(
      accountId: Value(accountId),
      jobId: Value(jobId),
      serverUrl: Value(serverUrl),
      capabilityGeneration: Value(capabilityGeneration),
      replayContractRevision: Value(replayContractRevision),
      davUserId: Value(davUserId),
      roomToken: Value(roomToken),
      referenceId: Value(referenceId),
      sourceHandle: Value(sourceHandle),
      sourceOwnership: Value(sourceOwnership),
      sourceByteLength: Value(sourceByteLength),
      sourceSha256: Value(sourceSha256),
      sourceMimeType: Value(sourceMimeType),
      sourceDisplayName: Value(sourceDisplayName),
      messageKind: Value(messageKind),
      caption: caption == null && nullToAbsent
          ? const Value.absent()
          : Value(caption),
      replyTo: replyTo == null && nullToAbsent
          ? const Value.absent()
          : Value(replyTo),
      threadId: threadId == null && nullToAbsent
          ? const Value.absent()
          : Value(threadId),
      threadTitle: threadTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(threadTitle),
      silent: Value(silent),
      enqueueSequence: Value(enqueueSequence),
      normalUploadMaximumBytes: Value(normalUploadMaximumBytes),
      chunkSizeBytes: Value(chunkSizeBytes),
      uploadSessionId: uploadSessionId == null && nullToAbsent
          ? const Value.absent()
          : Value(uploadSessionId),
      phase: Value(phase),
      resumePhase: resumePhase == null && nullToAbsent
          ? const Value.absent()
          : Value(resumePhase),
      remoteDraftFolder: remoteDraftFolder == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteDraftFolder),
      remoteTemporaryPath: remoteTemporaryPath == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteTemporaryPath),
      chunkCollectionReady: Value(chunkCollectionReady),
      chunkManifestLoaded: Value(chunkManifestLoaded),
      verifiedChunksJson: Value(verifiedChunksJson),
      inFlightStep: inFlightStep == null && nullToAbsent
          ? const Value.absent()
          : Value(inFlightStep),
      inFlightRequestId: inFlightRequestId == null && nullToAbsent
          ? const Value.absent()
          : Value(inFlightRequestId),
      attemptCount: Value(attemptCount),
      finalizationDispatched: Value(finalizationDispatched),
      cleanupChunkSession: Value(cleanupChunkSession),
      cleanupDraftFile: Value(cleanupDraftFile),
      messageIdsJson: Value(messageIdsJson),
      errorClass: errorClass == null && nullToAbsent
          ? const Value.absent()
          : Value(errorClass),
      profileFederated: Value(profileFederated),
      profileEnabled: Value(profileEnabled),
      profileCaption: Value(profileCaption),
      profileVoice: Value(profileVoice),
      profileReply: Value(profileReply),
      profileThreads: Value(profileThreads),
      profileSilent: Value(profileSilent),
      roomCanWrite: Value(roomCanWrite),
      automaticRetryCount: Value(automaticRetryCount),
      nextAttemptAtMillis: nextAttemptAtMillis == null && nullToAbsent
          ? const Value.absent()
          : Value(nextAttemptAtMillis),
      sourceReleased: Value(sourceReleased),
      localCleanupError: localCleanupError == null && nullToAbsent
          ? const Value.absent()
          : Value(localCleanupError),
      createdAtMillis: Value(createdAtMillis),
      updatedAtMillis: Value(updatedAtMillis),
    );
  }

  factory StoredAttachmentJob.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredAttachmentJob(
      accountId: serializer.fromJson<String>(json['accountId']),
      jobId: serializer.fromJson<String>(json['jobId']),
      serverUrl: serializer.fromJson<String>(json['serverUrl']),
      capabilityGeneration: serializer.fromJson<int>(
        json['capabilityGeneration'],
      ),
      replayContractRevision: serializer.fromJson<String>(
        json['replayContractRevision'],
      ),
      davUserId: serializer.fromJson<String>(json['davUserId']),
      roomToken: serializer.fromJson<String>(json['roomToken']),
      referenceId: serializer.fromJson<String>(json['referenceId']),
      sourceHandle: serializer.fromJson<String>(json['sourceHandle']),
      sourceOwnership: serializer.fromJson<String>(json['sourceOwnership']),
      sourceByteLength: serializer.fromJson<int>(json['sourceByteLength']),
      sourceSha256: serializer.fromJson<String>(json['sourceSha256']),
      sourceMimeType: serializer.fromJson<String>(json['sourceMimeType']),
      sourceDisplayName: serializer.fromJson<String>(json['sourceDisplayName']),
      messageKind: serializer.fromJson<String>(json['messageKind']),
      caption: serializer.fromJson<String?>(json['caption']),
      replyTo: serializer.fromJson<int?>(json['replyTo']),
      threadId: serializer.fromJson<int?>(json['threadId']),
      threadTitle: serializer.fromJson<String?>(json['threadTitle']),
      silent: serializer.fromJson<bool>(json['silent']),
      enqueueSequence: serializer.fromJson<int>(json['enqueueSequence']),
      normalUploadMaximumBytes: serializer.fromJson<int>(
        json['normalUploadMaximumBytes'],
      ),
      chunkSizeBytes: serializer.fromJson<int>(json['chunkSizeBytes']),
      uploadSessionId: serializer.fromJson<String?>(json['uploadSessionId']),
      phase: serializer.fromJson<String>(json['phase']),
      resumePhase: serializer.fromJson<String?>(json['resumePhase']),
      remoteDraftFolder: serializer.fromJson<String?>(
        json['remoteDraftFolder'],
      ),
      remoteTemporaryPath: serializer.fromJson<String?>(
        json['remoteTemporaryPath'],
      ),
      chunkCollectionReady: serializer.fromJson<bool>(
        json['chunkCollectionReady'],
      ),
      chunkManifestLoaded: serializer.fromJson<bool>(
        json['chunkManifestLoaded'],
      ),
      verifiedChunksJson: serializer.fromJson<String>(
        json['verifiedChunksJson'],
      ),
      inFlightStep: serializer.fromJson<String?>(json['inFlightStep']),
      inFlightRequestId: serializer.fromJson<String?>(
        json['inFlightRequestId'],
      ),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      finalizationDispatched: serializer.fromJson<bool>(
        json['finalizationDispatched'],
      ),
      cleanupChunkSession: serializer.fromJson<bool>(
        json['cleanupChunkSession'],
      ),
      cleanupDraftFile: serializer.fromJson<bool>(json['cleanupDraftFile']),
      messageIdsJson: serializer.fromJson<String>(json['messageIdsJson']),
      errorClass: serializer.fromJson<String?>(json['errorClass']),
      profileFederated: serializer.fromJson<bool>(json['profileFederated']),
      profileEnabled: serializer.fromJson<bool>(json['profileEnabled']),
      profileCaption: serializer.fromJson<bool>(json['profileCaption']),
      profileVoice: serializer.fromJson<bool>(json['profileVoice']),
      profileReply: serializer.fromJson<bool>(json['profileReply']),
      profileThreads: serializer.fromJson<bool>(json['profileThreads']),
      profileSilent: serializer.fromJson<bool>(json['profileSilent']),
      roomCanWrite: serializer.fromJson<bool>(json['roomCanWrite']),
      automaticRetryCount: serializer.fromJson<int>(
        json['automaticRetryCount'],
      ),
      nextAttemptAtMillis: serializer.fromJson<int?>(
        json['nextAttemptAtMillis'],
      ),
      sourceReleased: serializer.fromJson<bool>(json['sourceReleased']),
      localCleanupError: serializer.fromJson<String?>(
        json['localCleanupError'],
      ),
      createdAtMillis: serializer.fromJson<int>(json['createdAtMillis']),
      updatedAtMillis: serializer.fromJson<int>(json['updatedAtMillis']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'jobId': serializer.toJson<String>(jobId),
      'serverUrl': serializer.toJson<String>(serverUrl),
      'capabilityGeneration': serializer.toJson<int>(capabilityGeneration),
      'replayContractRevision': serializer.toJson<String>(
        replayContractRevision,
      ),
      'davUserId': serializer.toJson<String>(davUserId),
      'roomToken': serializer.toJson<String>(roomToken),
      'referenceId': serializer.toJson<String>(referenceId),
      'sourceHandle': serializer.toJson<String>(sourceHandle),
      'sourceOwnership': serializer.toJson<String>(sourceOwnership),
      'sourceByteLength': serializer.toJson<int>(sourceByteLength),
      'sourceSha256': serializer.toJson<String>(sourceSha256),
      'sourceMimeType': serializer.toJson<String>(sourceMimeType),
      'sourceDisplayName': serializer.toJson<String>(sourceDisplayName),
      'messageKind': serializer.toJson<String>(messageKind),
      'caption': serializer.toJson<String?>(caption),
      'replyTo': serializer.toJson<int?>(replyTo),
      'threadId': serializer.toJson<int?>(threadId),
      'threadTitle': serializer.toJson<String?>(threadTitle),
      'silent': serializer.toJson<bool>(silent),
      'enqueueSequence': serializer.toJson<int>(enqueueSequence),
      'normalUploadMaximumBytes': serializer.toJson<int>(
        normalUploadMaximumBytes,
      ),
      'chunkSizeBytes': serializer.toJson<int>(chunkSizeBytes),
      'uploadSessionId': serializer.toJson<String?>(uploadSessionId),
      'phase': serializer.toJson<String>(phase),
      'resumePhase': serializer.toJson<String?>(resumePhase),
      'remoteDraftFolder': serializer.toJson<String?>(remoteDraftFolder),
      'remoteTemporaryPath': serializer.toJson<String?>(remoteTemporaryPath),
      'chunkCollectionReady': serializer.toJson<bool>(chunkCollectionReady),
      'chunkManifestLoaded': serializer.toJson<bool>(chunkManifestLoaded),
      'verifiedChunksJson': serializer.toJson<String>(verifiedChunksJson),
      'inFlightStep': serializer.toJson<String?>(inFlightStep),
      'inFlightRequestId': serializer.toJson<String?>(inFlightRequestId),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'finalizationDispatched': serializer.toJson<bool>(finalizationDispatched),
      'cleanupChunkSession': serializer.toJson<bool>(cleanupChunkSession),
      'cleanupDraftFile': serializer.toJson<bool>(cleanupDraftFile),
      'messageIdsJson': serializer.toJson<String>(messageIdsJson),
      'errorClass': serializer.toJson<String?>(errorClass),
      'profileFederated': serializer.toJson<bool>(profileFederated),
      'profileEnabled': serializer.toJson<bool>(profileEnabled),
      'profileCaption': serializer.toJson<bool>(profileCaption),
      'profileVoice': serializer.toJson<bool>(profileVoice),
      'profileReply': serializer.toJson<bool>(profileReply),
      'profileThreads': serializer.toJson<bool>(profileThreads),
      'profileSilent': serializer.toJson<bool>(profileSilent),
      'roomCanWrite': serializer.toJson<bool>(roomCanWrite),
      'automaticRetryCount': serializer.toJson<int>(automaticRetryCount),
      'nextAttemptAtMillis': serializer.toJson<int?>(nextAttemptAtMillis),
      'sourceReleased': serializer.toJson<bool>(sourceReleased),
      'localCleanupError': serializer.toJson<String?>(localCleanupError),
      'createdAtMillis': serializer.toJson<int>(createdAtMillis),
      'updatedAtMillis': serializer.toJson<int>(updatedAtMillis),
    };
  }

  StoredAttachmentJob copyWith({
    String? accountId,
    String? jobId,
    String? serverUrl,
    int? capabilityGeneration,
    String? replayContractRevision,
    String? davUserId,
    String? roomToken,
    String? referenceId,
    String? sourceHandle,
    String? sourceOwnership,
    int? sourceByteLength,
    String? sourceSha256,
    String? sourceMimeType,
    String? sourceDisplayName,
    String? messageKind,
    Value<String?> caption = const Value.absent(),
    Value<int?> replyTo = const Value.absent(),
    Value<int?> threadId = const Value.absent(),
    Value<String?> threadTitle = const Value.absent(),
    bool? silent,
    int? enqueueSequence,
    int? normalUploadMaximumBytes,
    int? chunkSizeBytes,
    Value<String?> uploadSessionId = const Value.absent(),
    String? phase,
    Value<String?> resumePhase = const Value.absent(),
    Value<String?> remoteDraftFolder = const Value.absent(),
    Value<String?> remoteTemporaryPath = const Value.absent(),
    bool? chunkCollectionReady,
    bool? chunkManifestLoaded,
    String? verifiedChunksJson,
    Value<String?> inFlightStep = const Value.absent(),
    Value<String?> inFlightRequestId = const Value.absent(),
    int? attemptCount,
    bool? finalizationDispatched,
    bool? cleanupChunkSession,
    bool? cleanupDraftFile,
    String? messageIdsJson,
    Value<String?> errorClass = const Value.absent(),
    bool? profileFederated,
    bool? profileEnabled,
    bool? profileCaption,
    bool? profileVoice,
    bool? profileReply,
    bool? profileThreads,
    bool? profileSilent,
    bool? roomCanWrite,
    int? automaticRetryCount,
    Value<int?> nextAttemptAtMillis = const Value.absent(),
    bool? sourceReleased,
    Value<String?> localCleanupError = const Value.absent(),
    int? createdAtMillis,
    int? updatedAtMillis,
  }) => StoredAttachmentJob(
    accountId: accountId ?? this.accountId,
    jobId: jobId ?? this.jobId,
    serverUrl: serverUrl ?? this.serverUrl,
    capabilityGeneration: capabilityGeneration ?? this.capabilityGeneration,
    replayContractRevision:
        replayContractRevision ?? this.replayContractRevision,
    davUserId: davUserId ?? this.davUserId,
    roomToken: roomToken ?? this.roomToken,
    referenceId: referenceId ?? this.referenceId,
    sourceHandle: sourceHandle ?? this.sourceHandle,
    sourceOwnership: sourceOwnership ?? this.sourceOwnership,
    sourceByteLength: sourceByteLength ?? this.sourceByteLength,
    sourceSha256: sourceSha256 ?? this.sourceSha256,
    sourceMimeType: sourceMimeType ?? this.sourceMimeType,
    sourceDisplayName: sourceDisplayName ?? this.sourceDisplayName,
    messageKind: messageKind ?? this.messageKind,
    caption: caption.present ? caption.value : this.caption,
    replyTo: replyTo.present ? replyTo.value : this.replyTo,
    threadId: threadId.present ? threadId.value : this.threadId,
    threadTitle: threadTitle.present ? threadTitle.value : this.threadTitle,
    silent: silent ?? this.silent,
    enqueueSequence: enqueueSequence ?? this.enqueueSequence,
    normalUploadMaximumBytes:
        normalUploadMaximumBytes ?? this.normalUploadMaximumBytes,
    chunkSizeBytes: chunkSizeBytes ?? this.chunkSizeBytes,
    uploadSessionId: uploadSessionId.present
        ? uploadSessionId.value
        : this.uploadSessionId,
    phase: phase ?? this.phase,
    resumePhase: resumePhase.present ? resumePhase.value : this.resumePhase,
    remoteDraftFolder: remoteDraftFolder.present
        ? remoteDraftFolder.value
        : this.remoteDraftFolder,
    remoteTemporaryPath: remoteTemporaryPath.present
        ? remoteTemporaryPath.value
        : this.remoteTemporaryPath,
    chunkCollectionReady: chunkCollectionReady ?? this.chunkCollectionReady,
    chunkManifestLoaded: chunkManifestLoaded ?? this.chunkManifestLoaded,
    verifiedChunksJson: verifiedChunksJson ?? this.verifiedChunksJson,
    inFlightStep: inFlightStep.present ? inFlightStep.value : this.inFlightStep,
    inFlightRequestId: inFlightRequestId.present
        ? inFlightRequestId.value
        : this.inFlightRequestId,
    attemptCount: attemptCount ?? this.attemptCount,
    finalizationDispatched:
        finalizationDispatched ?? this.finalizationDispatched,
    cleanupChunkSession: cleanupChunkSession ?? this.cleanupChunkSession,
    cleanupDraftFile: cleanupDraftFile ?? this.cleanupDraftFile,
    messageIdsJson: messageIdsJson ?? this.messageIdsJson,
    errorClass: errorClass.present ? errorClass.value : this.errorClass,
    profileFederated: profileFederated ?? this.profileFederated,
    profileEnabled: profileEnabled ?? this.profileEnabled,
    profileCaption: profileCaption ?? this.profileCaption,
    profileVoice: profileVoice ?? this.profileVoice,
    profileReply: profileReply ?? this.profileReply,
    profileThreads: profileThreads ?? this.profileThreads,
    profileSilent: profileSilent ?? this.profileSilent,
    roomCanWrite: roomCanWrite ?? this.roomCanWrite,
    automaticRetryCount: automaticRetryCount ?? this.automaticRetryCount,
    nextAttemptAtMillis: nextAttemptAtMillis.present
        ? nextAttemptAtMillis.value
        : this.nextAttemptAtMillis,
    sourceReleased: sourceReleased ?? this.sourceReleased,
    localCleanupError: localCleanupError.present
        ? localCleanupError.value
        : this.localCleanupError,
    createdAtMillis: createdAtMillis ?? this.createdAtMillis,
    updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
  );
  StoredAttachmentJob copyWithCompanion(AttachmentJobsCompanion data) {
    return StoredAttachmentJob(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      jobId: data.jobId.present ? data.jobId.value : this.jobId,
      serverUrl: data.serverUrl.present ? data.serverUrl.value : this.serverUrl,
      capabilityGeneration: data.capabilityGeneration.present
          ? data.capabilityGeneration.value
          : this.capabilityGeneration,
      replayContractRevision: data.replayContractRevision.present
          ? data.replayContractRevision.value
          : this.replayContractRevision,
      davUserId: data.davUserId.present ? data.davUserId.value : this.davUserId,
      roomToken: data.roomToken.present ? data.roomToken.value : this.roomToken,
      referenceId: data.referenceId.present
          ? data.referenceId.value
          : this.referenceId,
      sourceHandle: data.sourceHandle.present
          ? data.sourceHandle.value
          : this.sourceHandle,
      sourceOwnership: data.sourceOwnership.present
          ? data.sourceOwnership.value
          : this.sourceOwnership,
      sourceByteLength: data.sourceByteLength.present
          ? data.sourceByteLength.value
          : this.sourceByteLength,
      sourceSha256: data.sourceSha256.present
          ? data.sourceSha256.value
          : this.sourceSha256,
      sourceMimeType: data.sourceMimeType.present
          ? data.sourceMimeType.value
          : this.sourceMimeType,
      sourceDisplayName: data.sourceDisplayName.present
          ? data.sourceDisplayName.value
          : this.sourceDisplayName,
      messageKind: data.messageKind.present
          ? data.messageKind.value
          : this.messageKind,
      caption: data.caption.present ? data.caption.value : this.caption,
      replyTo: data.replyTo.present ? data.replyTo.value : this.replyTo,
      threadId: data.threadId.present ? data.threadId.value : this.threadId,
      threadTitle: data.threadTitle.present
          ? data.threadTitle.value
          : this.threadTitle,
      silent: data.silent.present ? data.silent.value : this.silent,
      enqueueSequence: data.enqueueSequence.present
          ? data.enqueueSequence.value
          : this.enqueueSequence,
      normalUploadMaximumBytes: data.normalUploadMaximumBytes.present
          ? data.normalUploadMaximumBytes.value
          : this.normalUploadMaximumBytes,
      chunkSizeBytes: data.chunkSizeBytes.present
          ? data.chunkSizeBytes.value
          : this.chunkSizeBytes,
      uploadSessionId: data.uploadSessionId.present
          ? data.uploadSessionId.value
          : this.uploadSessionId,
      phase: data.phase.present ? data.phase.value : this.phase,
      resumePhase: data.resumePhase.present
          ? data.resumePhase.value
          : this.resumePhase,
      remoteDraftFolder: data.remoteDraftFolder.present
          ? data.remoteDraftFolder.value
          : this.remoteDraftFolder,
      remoteTemporaryPath: data.remoteTemporaryPath.present
          ? data.remoteTemporaryPath.value
          : this.remoteTemporaryPath,
      chunkCollectionReady: data.chunkCollectionReady.present
          ? data.chunkCollectionReady.value
          : this.chunkCollectionReady,
      chunkManifestLoaded: data.chunkManifestLoaded.present
          ? data.chunkManifestLoaded.value
          : this.chunkManifestLoaded,
      verifiedChunksJson: data.verifiedChunksJson.present
          ? data.verifiedChunksJson.value
          : this.verifiedChunksJson,
      inFlightStep: data.inFlightStep.present
          ? data.inFlightStep.value
          : this.inFlightStep,
      inFlightRequestId: data.inFlightRequestId.present
          ? data.inFlightRequestId.value
          : this.inFlightRequestId,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      finalizationDispatched: data.finalizationDispatched.present
          ? data.finalizationDispatched.value
          : this.finalizationDispatched,
      cleanupChunkSession: data.cleanupChunkSession.present
          ? data.cleanupChunkSession.value
          : this.cleanupChunkSession,
      cleanupDraftFile: data.cleanupDraftFile.present
          ? data.cleanupDraftFile.value
          : this.cleanupDraftFile,
      messageIdsJson: data.messageIdsJson.present
          ? data.messageIdsJson.value
          : this.messageIdsJson,
      errorClass: data.errorClass.present
          ? data.errorClass.value
          : this.errorClass,
      profileFederated: data.profileFederated.present
          ? data.profileFederated.value
          : this.profileFederated,
      profileEnabled: data.profileEnabled.present
          ? data.profileEnabled.value
          : this.profileEnabled,
      profileCaption: data.profileCaption.present
          ? data.profileCaption.value
          : this.profileCaption,
      profileVoice: data.profileVoice.present
          ? data.profileVoice.value
          : this.profileVoice,
      profileReply: data.profileReply.present
          ? data.profileReply.value
          : this.profileReply,
      profileThreads: data.profileThreads.present
          ? data.profileThreads.value
          : this.profileThreads,
      profileSilent: data.profileSilent.present
          ? data.profileSilent.value
          : this.profileSilent,
      roomCanWrite: data.roomCanWrite.present
          ? data.roomCanWrite.value
          : this.roomCanWrite,
      automaticRetryCount: data.automaticRetryCount.present
          ? data.automaticRetryCount.value
          : this.automaticRetryCount,
      nextAttemptAtMillis: data.nextAttemptAtMillis.present
          ? data.nextAttemptAtMillis.value
          : this.nextAttemptAtMillis,
      sourceReleased: data.sourceReleased.present
          ? data.sourceReleased.value
          : this.sourceReleased,
      localCleanupError: data.localCleanupError.present
          ? data.localCleanupError.value
          : this.localCleanupError,
      createdAtMillis: data.createdAtMillis.present
          ? data.createdAtMillis.value
          : this.createdAtMillis,
      updatedAtMillis: data.updatedAtMillis.present
          ? data.updatedAtMillis.value
          : this.updatedAtMillis,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredAttachmentJob(')
          ..write('accountId: $accountId, ')
          ..write('jobId: $jobId, ')
          ..write('serverUrl: $serverUrl, ')
          ..write('capabilityGeneration: $capabilityGeneration, ')
          ..write('replayContractRevision: $replayContractRevision, ')
          ..write('davUserId: $davUserId, ')
          ..write('roomToken: $roomToken, ')
          ..write('referenceId: $referenceId, ')
          ..write('sourceHandle: $sourceHandle, ')
          ..write('sourceOwnership: $sourceOwnership, ')
          ..write('sourceByteLength: $sourceByteLength, ')
          ..write('sourceSha256: $sourceSha256, ')
          ..write('sourceMimeType: $sourceMimeType, ')
          ..write('sourceDisplayName: $sourceDisplayName, ')
          ..write('messageKind: $messageKind, ')
          ..write('caption: $caption, ')
          ..write('replyTo: $replyTo, ')
          ..write('threadId: $threadId, ')
          ..write('threadTitle: $threadTitle, ')
          ..write('silent: $silent, ')
          ..write('enqueueSequence: $enqueueSequence, ')
          ..write('normalUploadMaximumBytes: $normalUploadMaximumBytes, ')
          ..write('chunkSizeBytes: $chunkSizeBytes, ')
          ..write('uploadSessionId: $uploadSessionId, ')
          ..write('phase: $phase, ')
          ..write('resumePhase: $resumePhase, ')
          ..write('remoteDraftFolder: $remoteDraftFolder, ')
          ..write('remoteTemporaryPath: $remoteTemporaryPath, ')
          ..write('chunkCollectionReady: $chunkCollectionReady, ')
          ..write('chunkManifestLoaded: $chunkManifestLoaded, ')
          ..write('verifiedChunksJson: $verifiedChunksJson, ')
          ..write('inFlightStep: $inFlightStep, ')
          ..write('inFlightRequestId: $inFlightRequestId, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('finalizationDispatched: $finalizationDispatched, ')
          ..write('cleanupChunkSession: $cleanupChunkSession, ')
          ..write('cleanupDraftFile: $cleanupDraftFile, ')
          ..write('messageIdsJson: $messageIdsJson, ')
          ..write('errorClass: $errorClass, ')
          ..write('profileFederated: $profileFederated, ')
          ..write('profileEnabled: $profileEnabled, ')
          ..write('profileCaption: $profileCaption, ')
          ..write('profileVoice: $profileVoice, ')
          ..write('profileReply: $profileReply, ')
          ..write('profileThreads: $profileThreads, ')
          ..write('profileSilent: $profileSilent, ')
          ..write('roomCanWrite: $roomCanWrite, ')
          ..write('automaticRetryCount: $automaticRetryCount, ')
          ..write('nextAttemptAtMillis: $nextAttemptAtMillis, ')
          ..write('sourceReleased: $sourceReleased, ')
          ..write('localCleanupError: $localCleanupError, ')
          ..write('createdAtMillis: $createdAtMillis, ')
          ..write('updatedAtMillis: $updatedAtMillis')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    accountId,
    jobId,
    serverUrl,
    capabilityGeneration,
    replayContractRevision,
    davUserId,
    roomToken,
    referenceId,
    sourceHandle,
    sourceOwnership,
    sourceByteLength,
    sourceSha256,
    sourceMimeType,
    sourceDisplayName,
    messageKind,
    caption,
    replyTo,
    threadId,
    threadTitle,
    silent,
    enqueueSequence,
    normalUploadMaximumBytes,
    chunkSizeBytes,
    uploadSessionId,
    phase,
    resumePhase,
    remoteDraftFolder,
    remoteTemporaryPath,
    chunkCollectionReady,
    chunkManifestLoaded,
    verifiedChunksJson,
    inFlightStep,
    inFlightRequestId,
    attemptCount,
    finalizationDispatched,
    cleanupChunkSession,
    cleanupDraftFile,
    messageIdsJson,
    errorClass,
    profileFederated,
    profileEnabled,
    profileCaption,
    profileVoice,
    profileReply,
    profileThreads,
    profileSilent,
    roomCanWrite,
    automaticRetryCount,
    nextAttemptAtMillis,
    sourceReleased,
    localCleanupError,
    createdAtMillis,
    updatedAtMillis,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredAttachmentJob &&
          other.accountId == this.accountId &&
          other.jobId == this.jobId &&
          other.serverUrl == this.serverUrl &&
          other.capabilityGeneration == this.capabilityGeneration &&
          other.replayContractRevision == this.replayContractRevision &&
          other.davUserId == this.davUserId &&
          other.roomToken == this.roomToken &&
          other.referenceId == this.referenceId &&
          other.sourceHandle == this.sourceHandle &&
          other.sourceOwnership == this.sourceOwnership &&
          other.sourceByteLength == this.sourceByteLength &&
          other.sourceSha256 == this.sourceSha256 &&
          other.sourceMimeType == this.sourceMimeType &&
          other.sourceDisplayName == this.sourceDisplayName &&
          other.messageKind == this.messageKind &&
          other.caption == this.caption &&
          other.replyTo == this.replyTo &&
          other.threadId == this.threadId &&
          other.threadTitle == this.threadTitle &&
          other.silent == this.silent &&
          other.enqueueSequence == this.enqueueSequence &&
          other.normalUploadMaximumBytes == this.normalUploadMaximumBytes &&
          other.chunkSizeBytes == this.chunkSizeBytes &&
          other.uploadSessionId == this.uploadSessionId &&
          other.phase == this.phase &&
          other.resumePhase == this.resumePhase &&
          other.remoteDraftFolder == this.remoteDraftFolder &&
          other.remoteTemporaryPath == this.remoteTemporaryPath &&
          other.chunkCollectionReady == this.chunkCollectionReady &&
          other.chunkManifestLoaded == this.chunkManifestLoaded &&
          other.verifiedChunksJson == this.verifiedChunksJson &&
          other.inFlightStep == this.inFlightStep &&
          other.inFlightRequestId == this.inFlightRequestId &&
          other.attemptCount == this.attemptCount &&
          other.finalizationDispatched == this.finalizationDispatched &&
          other.cleanupChunkSession == this.cleanupChunkSession &&
          other.cleanupDraftFile == this.cleanupDraftFile &&
          other.messageIdsJson == this.messageIdsJson &&
          other.errorClass == this.errorClass &&
          other.profileFederated == this.profileFederated &&
          other.profileEnabled == this.profileEnabled &&
          other.profileCaption == this.profileCaption &&
          other.profileVoice == this.profileVoice &&
          other.profileReply == this.profileReply &&
          other.profileThreads == this.profileThreads &&
          other.profileSilent == this.profileSilent &&
          other.roomCanWrite == this.roomCanWrite &&
          other.automaticRetryCount == this.automaticRetryCount &&
          other.nextAttemptAtMillis == this.nextAttemptAtMillis &&
          other.sourceReleased == this.sourceReleased &&
          other.localCleanupError == this.localCleanupError &&
          other.createdAtMillis == this.createdAtMillis &&
          other.updatedAtMillis == this.updatedAtMillis);
}

class AttachmentJobsCompanion extends UpdateCompanion<StoredAttachmentJob> {
  final Value<String> accountId;
  final Value<String> jobId;
  final Value<String> serverUrl;
  final Value<int> capabilityGeneration;
  final Value<String> replayContractRevision;
  final Value<String> davUserId;
  final Value<String> roomToken;
  final Value<String> referenceId;
  final Value<String> sourceHandle;
  final Value<String> sourceOwnership;
  final Value<int> sourceByteLength;
  final Value<String> sourceSha256;
  final Value<String> sourceMimeType;
  final Value<String> sourceDisplayName;
  final Value<String> messageKind;
  final Value<String?> caption;
  final Value<int?> replyTo;
  final Value<int?> threadId;
  final Value<String?> threadTitle;
  final Value<bool> silent;
  final Value<int> enqueueSequence;
  final Value<int> normalUploadMaximumBytes;
  final Value<int> chunkSizeBytes;
  final Value<String?> uploadSessionId;
  final Value<String> phase;
  final Value<String?> resumePhase;
  final Value<String?> remoteDraftFolder;
  final Value<String?> remoteTemporaryPath;
  final Value<bool> chunkCollectionReady;
  final Value<bool> chunkManifestLoaded;
  final Value<String> verifiedChunksJson;
  final Value<String?> inFlightStep;
  final Value<String?> inFlightRequestId;
  final Value<int> attemptCount;
  final Value<bool> finalizationDispatched;
  final Value<bool> cleanupChunkSession;
  final Value<bool> cleanupDraftFile;
  final Value<String> messageIdsJson;
  final Value<String?> errorClass;
  final Value<bool> profileFederated;
  final Value<bool> profileEnabled;
  final Value<bool> profileCaption;
  final Value<bool> profileVoice;
  final Value<bool> profileReply;
  final Value<bool> profileThreads;
  final Value<bool> profileSilent;
  final Value<bool> roomCanWrite;
  final Value<int> automaticRetryCount;
  final Value<int?> nextAttemptAtMillis;
  final Value<bool> sourceReleased;
  final Value<String?> localCleanupError;
  final Value<int> createdAtMillis;
  final Value<int> updatedAtMillis;
  final Value<int> rowid;
  const AttachmentJobsCompanion({
    this.accountId = const Value.absent(),
    this.jobId = const Value.absent(),
    this.serverUrl = const Value.absent(),
    this.capabilityGeneration = const Value.absent(),
    this.replayContractRevision = const Value.absent(),
    this.davUserId = const Value.absent(),
    this.roomToken = const Value.absent(),
    this.referenceId = const Value.absent(),
    this.sourceHandle = const Value.absent(),
    this.sourceOwnership = const Value.absent(),
    this.sourceByteLength = const Value.absent(),
    this.sourceSha256 = const Value.absent(),
    this.sourceMimeType = const Value.absent(),
    this.sourceDisplayName = const Value.absent(),
    this.messageKind = const Value.absent(),
    this.caption = const Value.absent(),
    this.replyTo = const Value.absent(),
    this.threadId = const Value.absent(),
    this.threadTitle = const Value.absent(),
    this.silent = const Value.absent(),
    this.enqueueSequence = const Value.absent(),
    this.normalUploadMaximumBytes = const Value.absent(),
    this.chunkSizeBytes = const Value.absent(),
    this.uploadSessionId = const Value.absent(),
    this.phase = const Value.absent(),
    this.resumePhase = const Value.absent(),
    this.remoteDraftFolder = const Value.absent(),
    this.remoteTemporaryPath = const Value.absent(),
    this.chunkCollectionReady = const Value.absent(),
    this.chunkManifestLoaded = const Value.absent(),
    this.verifiedChunksJson = const Value.absent(),
    this.inFlightStep = const Value.absent(),
    this.inFlightRequestId = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.finalizationDispatched = const Value.absent(),
    this.cleanupChunkSession = const Value.absent(),
    this.cleanupDraftFile = const Value.absent(),
    this.messageIdsJson = const Value.absent(),
    this.errorClass = const Value.absent(),
    this.profileFederated = const Value.absent(),
    this.profileEnabled = const Value.absent(),
    this.profileCaption = const Value.absent(),
    this.profileVoice = const Value.absent(),
    this.profileReply = const Value.absent(),
    this.profileThreads = const Value.absent(),
    this.profileSilent = const Value.absent(),
    this.roomCanWrite = const Value.absent(),
    this.automaticRetryCount = const Value.absent(),
    this.nextAttemptAtMillis = const Value.absent(),
    this.sourceReleased = const Value.absent(),
    this.localCleanupError = const Value.absent(),
    this.createdAtMillis = const Value.absent(),
    this.updatedAtMillis = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AttachmentJobsCompanion.insert({
    required String accountId,
    required String jobId,
    required String serverUrl,
    required int capabilityGeneration,
    required String replayContractRevision,
    required String davUserId,
    required String roomToken,
    required String referenceId,
    required String sourceHandle,
    required String sourceOwnership,
    required int sourceByteLength,
    required String sourceSha256,
    required String sourceMimeType,
    required String sourceDisplayName,
    required String messageKind,
    this.caption = const Value.absent(),
    this.replyTo = const Value.absent(),
    this.threadId = const Value.absent(),
    this.threadTitle = const Value.absent(),
    required bool silent,
    required int enqueueSequence,
    required int normalUploadMaximumBytes,
    required int chunkSizeBytes,
    this.uploadSessionId = const Value.absent(),
    required String phase,
    this.resumePhase = const Value.absent(),
    this.remoteDraftFolder = const Value.absent(),
    this.remoteTemporaryPath = const Value.absent(),
    required bool chunkCollectionReady,
    required bool chunkManifestLoaded,
    required String verifiedChunksJson,
    this.inFlightStep = const Value.absent(),
    this.inFlightRequestId = const Value.absent(),
    required int attemptCount,
    required bool finalizationDispatched,
    required bool cleanupChunkSession,
    required bool cleanupDraftFile,
    required String messageIdsJson,
    this.errorClass = const Value.absent(),
    required bool profileFederated,
    required bool profileEnabled,
    required bool profileCaption,
    required bool profileVoice,
    required bool profileReply,
    required bool profileThreads,
    required bool profileSilent,
    required bool roomCanWrite,
    this.automaticRetryCount = const Value.absent(),
    this.nextAttemptAtMillis = const Value.absent(),
    this.sourceReleased = const Value.absent(),
    this.localCleanupError = const Value.absent(),
    required int createdAtMillis,
    required int updatedAtMillis,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       jobId = Value(jobId),
       serverUrl = Value(serverUrl),
       capabilityGeneration = Value(capabilityGeneration),
       replayContractRevision = Value(replayContractRevision),
       davUserId = Value(davUserId),
       roomToken = Value(roomToken),
       referenceId = Value(referenceId),
       sourceHandle = Value(sourceHandle),
       sourceOwnership = Value(sourceOwnership),
       sourceByteLength = Value(sourceByteLength),
       sourceSha256 = Value(sourceSha256),
       sourceMimeType = Value(sourceMimeType),
       sourceDisplayName = Value(sourceDisplayName),
       messageKind = Value(messageKind),
       silent = Value(silent),
       enqueueSequence = Value(enqueueSequence),
       normalUploadMaximumBytes = Value(normalUploadMaximumBytes),
       chunkSizeBytes = Value(chunkSizeBytes),
       phase = Value(phase),
       chunkCollectionReady = Value(chunkCollectionReady),
       chunkManifestLoaded = Value(chunkManifestLoaded),
       verifiedChunksJson = Value(verifiedChunksJson),
       attemptCount = Value(attemptCount),
       finalizationDispatched = Value(finalizationDispatched),
       cleanupChunkSession = Value(cleanupChunkSession),
       cleanupDraftFile = Value(cleanupDraftFile),
       messageIdsJson = Value(messageIdsJson),
       profileFederated = Value(profileFederated),
       profileEnabled = Value(profileEnabled),
       profileCaption = Value(profileCaption),
       profileVoice = Value(profileVoice),
       profileReply = Value(profileReply),
       profileThreads = Value(profileThreads),
       profileSilent = Value(profileSilent),
       roomCanWrite = Value(roomCanWrite),
       createdAtMillis = Value(createdAtMillis),
       updatedAtMillis = Value(updatedAtMillis);
  static Insertable<StoredAttachmentJob> custom({
    Expression<String>? accountId,
    Expression<String>? jobId,
    Expression<String>? serverUrl,
    Expression<int>? capabilityGeneration,
    Expression<String>? replayContractRevision,
    Expression<String>? davUserId,
    Expression<String>? roomToken,
    Expression<String>? referenceId,
    Expression<String>? sourceHandle,
    Expression<String>? sourceOwnership,
    Expression<int>? sourceByteLength,
    Expression<String>? sourceSha256,
    Expression<String>? sourceMimeType,
    Expression<String>? sourceDisplayName,
    Expression<String>? messageKind,
    Expression<String>? caption,
    Expression<int>? replyTo,
    Expression<int>? threadId,
    Expression<String>? threadTitle,
    Expression<bool>? silent,
    Expression<int>? enqueueSequence,
    Expression<int>? normalUploadMaximumBytes,
    Expression<int>? chunkSizeBytes,
    Expression<String>? uploadSessionId,
    Expression<String>? phase,
    Expression<String>? resumePhase,
    Expression<String>? remoteDraftFolder,
    Expression<String>? remoteTemporaryPath,
    Expression<bool>? chunkCollectionReady,
    Expression<bool>? chunkManifestLoaded,
    Expression<String>? verifiedChunksJson,
    Expression<String>? inFlightStep,
    Expression<String>? inFlightRequestId,
    Expression<int>? attemptCount,
    Expression<bool>? finalizationDispatched,
    Expression<bool>? cleanupChunkSession,
    Expression<bool>? cleanupDraftFile,
    Expression<String>? messageIdsJson,
    Expression<String>? errorClass,
    Expression<bool>? profileFederated,
    Expression<bool>? profileEnabled,
    Expression<bool>? profileCaption,
    Expression<bool>? profileVoice,
    Expression<bool>? profileReply,
    Expression<bool>? profileThreads,
    Expression<bool>? profileSilent,
    Expression<bool>? roomCanWrite,
    Expression<int>? automaticRetryCount,
    Expression<int>? nextAttemptAtMillis,
    Expression<bool>? sourceReleased,
    Expression<String>? localCleanupError,
    Expression<int>? createdAtMillis,
    Expression<int>? updatedAtMillis,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (jobId != null) 'job_id': jobId,
      if (serverUrl != null) 'server_url': serverUrl,
      if (capabilityGeneration != null)
        'capability_generation': capabilityGeneration,
      if (replayContractRevision != null)
        'replay_contract_revision': replayContractRevision,
      if (davUserId != null) 'dav_user_id': davUserId,
      if (roomToken != null) 'room_token': roomToken,
      if (referenceId != null) 'reference_id': referenceId,
      if (sourceHandle != null) 'source_handle': sourceHandle,
      if (sourceOwnership != null) 'source_ownership': sourceOwnership,
      if (sourceByteLength != null) 'source_byte_length': sourceByteLength,
      if (sourceSha256 != null) 'source_sha256': sourceSha256,
      if (sourceMimeType != null) 'source_mime_type': sourceMimeType,
      if (sourceDisplayName != null) 'source_display_name': sourceDisplayName,
      if (messageKind != null) 'message_kind': messageKind,
      if (caption != null) 'caption': caption,
      if (replyTo != null) 'reply_to': replyTo,
      if (threadId != null) 'thread_id': threadId,
      if (threadTitle != null) 'thread_title': threadTitle,
      if (silent != null) 'silent': silent,
      if (enqueueSequence != null) 'enqueue_sequence': enqueueSequence,
      if (normalUploadMaximumBytes != null)
        'normal_upload_maximum_bytes': normalUploadMaximumBytes,
      if (chunkSizeBytes != null) 'chunk_size_bytes': chunkSizeBytes,
      if (uploadSessionId != null) 'upload_session_id': uploadSessionId,
      if (phase != null) 'phase': phase,
      if (resumePhase != null) 'resume_phase': resumePhase,
      if (remoteDraftFolder != null) 'remote_draft_folder': remoteDraftFolder,
      if (remoteTemporaryPath != null)
        'remote_temporary_path': remoteTemporaryPath,
      if (chunkCollectionReady != null)
        'chunk_collection_ready': chunkCollectionReady,
      if (chunkManifestLoaded != null)
        'chunk_manifest_loaded': chunkManifestLoaded,
      if (verifiedChunksJson != null)
        'verified_chunks_json': verifiedChunksJson,
      if (inFlightStep != null) 'in_flight_step': inFlightStep,
      if (inFlightRequestId != null) 'in_flight_request_id': inFlightRequestId,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (finalizationDispatched != null)
        'finalization_dispatched': finalizationDispatched,
      if (cleanupChunkSession != null)
        'cleanup_chunk_session': cleanupChunkSession,
      if (cleanupDraftFile != null) 'cleanup_draft_file': cleanupDraftFile,
      if (messageIdsJson != null) 'message_ids_json': messageIdsJson,
      if (errorClass != null) 'error_class': errorClass,
      if (profileFederated != null) 'profile_federated': profileFederated,
      if (profileEnabled != null) 'profile_enabled': profileEnabled,
      if (profileCaption != null) 'profile_caption': profileCaption,
      if (profileVoice != null) 'profile_voice': profileVoice,
      if (profileReply != null) 'profile_reply': profileReply,
      if (profileThreads != null) 'profile_threads': profileThreads,
      if (profileSilent != null) 'profile_silent': profileSilent,
      if (roomCanWrite != null) 'room_can_write': roomCanWrite,
      if (automaticRetryCount != null)
        'automatic_retry_count': automaticRetryCount,
      if (nextAttemptAtMillis != null)
        'next_attempt_at_millis': nextAttemptAtMillis,
      if (sourceReleased != null) 'source_released': sourceReleased,
      if (localCleanupError != null) 'local_cleanup_error': localCleanupError,
      if (createdAtMillis != null) 'created_at_millis': createdAtMillis,
      if (updatedAtMillis != null) 'updated_at_millis': updatedAtMillis,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AttachmentJobsCompanion copyWith({
    Value<String>? accountId,
    Value<String>? jobId,
    Value<String>? serverUrl,
    Value<int>? capabilityGeneration,
    Value<String>? replayContractRevision,
    Value<String>? davUserId,
    Value<String>? roomToken,
    Value<String>? referenceId,
    Value<String>? sourceHandle,
    Value<String>? sourceOwnership,
    Value<int>? sourceByteLength,
    Value<String>? sourceSha256,
    Value<String>? sourceMimeType,
    Value<String>? sourceDisplayName,
    Value<String>? messageKind,
    Value<String?>? caption,
    Value<int?>? replyTo,
    Value<int?>? threadId,
    Value<String?>? threadTitle,
    Value<bool>? silent,
    Value<int>? enqueueSequence,
    Value<int>? normalUploadMaximumBytes,
    Value<int>? chunkSizeBytes,
    Value<String?>? uploadSessionId,
    Value<String>? phase,
    Value<String?>? resumePhase,
    Value<String?>? remoteDraftFolder,
    Value<String?>? remoteTemporaryPath,
    Value<bool>? chunkCollectionReady,
    Value<bool>? chunkManifestLoaded,
    Value<String>? verifiedChunksJson,
    Value<String?>? inFlightStep,
    Value<String?>? inFlightRequestId,
    Value<int>? attemptCount,
    Value<bool>? finalizationDispatched,
    Value<bool>? cleanupChunkSession,
    Value<bool>? cleanupDraftFile,
    Value<String>? messageIdsJson,
    Value<String?>? errorClass,
    Value<bool>? profileFederated,
    Value<bool>? profileEnabled,
    Value<bool>? profileCaption,
    Value<bool>? profileVoice,
    Value<bool>? profileReply,
    Value<bool>? profileThreads,
    Value<bool>? profileSilent,
    Value<bool>? roomCanWrite,
    Value<int>? automaticRetryCount,
    Value<int?>? nextAttemptAtMillis,
    Value<bool>? sourceReleased,
    Value<String?>? localCleanupError,
    Value<int>? createdAtMillis,
    Value<int>? updatedAtMillis,
    Value<int>? rowid,
  }) {
    return AttachmentJobsCompanion(
      accountId: accountId ?? this.accountId,
      jobId: jobId ?? this.jobId,
      serverUrl: serverUrl ?? this.serverUrl,
      capabilityGeneration: capabilityGeneration ?? this.capabilityGeneration,
      replayContractRevision:
          replayContractRevision ?? this.replayContractRevision,
      davUserId: davUserId ?? this.davUserId,
      roomToken: roomToken ?? this.roomToken,
      referenceId: referenceId ?? this.referenceId,
      sourceHandle: sourceHandle ?? this.sourceHandle,
      sourceOwnership: sourceOwnership ?? this.sourceOwnership,
      sourceByteLength: sourceByteLength ?? this.sourceByteLength,
      sourceSha256: sourceSha256 ?? this.sourceSha256,
      sourceMimeType: sourceMimeType ?? this.sourceMimeType,
      sourceDisplayName: sourceDisplayName ?? this.sourceDisplayName,
      messageKind: messageKind ?? this.messageKind,
      caption: caption ?? this.caption,
      replyTo: replyTo ?? this.replyTo,
      threadId: threadId ?? this.threadId,
      threadTitle: threadTitle ?? this.threadTitle,
      silent: silent ?? this.silent,
      enqueueSequence: enqueueSequence ?? this.enqueueSequence,
      normalUploadMaximumBytes:
          normalUploadMaximumBytes ?? this.normalUploadMaximumBytes,
      chunkSizeBytes: chunkSizeBytes ?? this.chunkSizeBytes,
      uploadSessionId: uploadSessionId ?? this.uploadSessionId,
      phase: phase ?? this.phase,
      resumePhase: resumePhase ?? this.resumePhase,
      remoteDraftFolder: remoteDraftFolder ?? this.remoteDraftFolder,
      remoteTemporaryPath: remoteTemporaryPath ?? this.remoteTemporaryPath,
      chunkCollectionReady: chunkCollectionReady ?? this.chunkCollectionReady,
      chunkManifestLoaded: chunkManifestLoaded ?? this.chunkManifestLoaded,
      verifiedChunksJson: verifiedChunksJson ?? this.verifiedChunksJson,
      inFlightStep: inFlightStep ?? this.inFlightStep,
      inFlightRequestId: inFlightRequestId ?? this.inFlightRequestId,
      attemptCount: attemptCount ?? this.attemptCount,
      finalizationDispatched:
          finalizationDispatched ?? this.finalizationDispatched,
      cleanupChunkSession: cleanupChunkSession ?? this.cleanupChunkSession,
      cleanupDraftFile: cleanupDraftFile ?? this.cleanupDraftFile,
      messageIdsJson: messageIdsJson ?? this.messageIdsJson,
      errorClass: errorClass ?? this.errorClass,
      profileFederated: profileFederated ?? this.profileFederated,
      profileEnabled: profileEnabled ?? this.profileEnabled,
      profileCaption: profileCaption ?? this.profileCaption,
      profileVoice: profileVoice ?? this.profileVoice,
      profileReply: profileReply ?? this.profileReply,
      profileThreads: profileThreads ?? this.profileThreads,
      profileSilent: profileSilent ?? this.profileSilent,
      roomCanWrite: roomCanWrite ?? this.roomCanWrite,
      automaticRetryCount: automaticRetryCount ?? this.automaticRetryCount,
      nextAttemptAtMillis: nextAttemptAtMillis ?? this.nextAttemptAtMillis,
      sourceReleased: sourceReleased ?? this.sourceReleased,
      localCleanupError: localCleanupError ?? this.localCleanupError,
      createdAtMillis: createdAtMillis ?? this.createdAtMillis,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (jobId.present) {
      map['job_id'] = Variable<String>(jobId.value);
    }
    if (serverUrl.present) {
      map['server_url'] = Variable<String>(serverUrl.value);
    }
    if (capabilityGeneration.present) {
      map['capability_generation'] = Variable<int>(capabilityGeneration.value);
    }
    if (replayContractRevision.present) {
      map['replay_contract_revision'] = Variable<String>(
        replayContractRevision.value,
      );
    }
    if (davUserId.present) {
      map['dav_user_id'] = Variable<String>(davUserId.value);
    }
    if (roomToken.present) {
      map['room_token'] = Variable<String>(roomToken.value);
    }
    if (referenceId.present) {
      map['reference_id'] = Variable<String>(referenceId.value);
    }
    if (sourceHandle.present) {
      map['source_handle'] = Variable<String>(sourceHandle.value);
    }
    if (sourceOwnership.present) {
      map['source_ownership'] = Variable<String>(sourceOwnership.value);
    }
    if (sourceByteLength.present) {
      map['source_byte_length'] = Variable<int>(sourceByteLength.value);
    }
    if (sourceSha256.present) {
      map['source_sha256'] = Variable<String>(sourceSha256.value);
    }
    if (sourceMimeType.present) {
      map['source_mime_type'] = Variable<String>(sourceMimeType.value);
    }
    if (sourceDisplayName.present) {
      map['source_display_name'] = Variable<String>(sourceDisplayName.value);
    }
    if (messageKind.present) {
      map['message_kind'] = Variable<String>(messageKind.value);
    }
    if (caption.present) {
      map['caption'] = Variable<String>(caption.value);
    }
    if (replyTo.present) {
      map['reply_to'] = Variable<int>(replyTo.value);
    }
    if (threadId.present) {
      map['thread_id'] = Variable<int>(threadId.value);
    }
    if (threadTitle.present) {
      map['thread_title'] = Variable<String>(threadTitle.value);
    }
    if (silent.present) {
      map['silent'] = Variable<bool>(silent.value);
    }
    if (enqueueSequence.present) {
      map['enqueue_sequence'] = Variable<int>(enqueueSequence.value);
    }
    if (normalUploadMaximumBytes.present) {
      map['normal_upload_maximum_bytes'] = Variable<int>(
        normalUploadMaximumBytes.value,
      );
    }
    if (chunkSizeBytes.present) {
      map['chunk_size_bytes'] = Variable<int>(chunkSizeBytes.value);
    }
    if (uploadSessionId.present) {
      map['upload_session_id'] = Variable<String>(uploadSessionId.value);
    }
    if (phase.present) {
      map['phase'] = Variable<String>(phase.value);
    }
    if (resumePhase.present) {
      map['resume_phase'] = Variable<String>(resumePhase.value);
    }
    if (remoteDraftFolder.present) {
      map['remote_draft_folder'] = Variable<String>(remoteDraftFolder.value);
    }
    if (remoteTemporaryPath.present) {
      map['remote_temporary_path'] = Variable<String>(
        remoteTemporaryPath.value,
      );
    }
    if (chunkCollectionReady.present) {
      map['chunk_collection_ready'] = Variable<bool>(
        chunkCollectionReady.value,
      );
    }
    if (chunkManifestLoaded.present) {
      map['chunk_manifest_loaded'] = Variable<bool>(chunkManifestLoaded.value);
    }
    if (verifiedChunksJson.present) {
      map['verified_chunks_json'] = Variable<String>(verifiedChunksJson.value);
    }
    if (inFlightStep.present) {
      map['in_flight_step'] = Variable<String>(inFlightStep.value);
    }
    if (inFlightRequestId.present) {
      map['in_flight_request_id'] = Variable<String>(inFlightRequestId.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (finalizationDispatched.present) {
      map['finalization_dispatched'] = Variable<bool>(
        finalizationDispatched.value,
      );
    }
    if (cleanupChunkSession.present) {
      map['cleanup_chunk_session'] = Variable<bool>(cleanupChunkSession.value);
    }
    if (cleanupDraftFile.present) {
      map['cleanup_draft_file'] = Variable<bool>(cleanupDraftFile.value);
    }
    if (messageIdsJson.present) {
      map['message_ids_json'] = Variable<String>(messageIdsJson.value);
    }
    if (errorClass.present) {
      map['error_class'] = Variable<String>(errorClass.value);
    }
    if (profileFederated.present) {
      map['profile_federated'] = Variable<bool>(profileFederated.value);
    }
    if (profileEnabled.present) {
      map['profile_enabled'] = Variable<bool>(profileEnabled.value);
    }
    if (profileCaption.present) {
      map['profile_caption'] = Variable<bool>(profileCaption.value);
    }
    if (profileVoice.present) {
      map['profile_voice'] = Variable<bool>(profileVoice.value);
    }
    if (profileReply.present) {
      map['profile_reply'] = Variable<bool>(profileReply.value);
    }
    if (profileThreads.present) {
      map['profile_threads'] = Variable<bool>(profileThreads.value);
    }
    if (profileSilent.present) {
      map['profile_silent'] = Variable<bool>(profileSilent.value);
    }
    if (roomCanWrite.present) {
      map['room_can_write'] = Variable<bool>(roomCanWrite.value);
    }
    if (automaticRetryCount.present) {
      map['automatic_retry_count'] = Variable<int>(automaticRetryCount.value);
    }
    if (nextAttemptAtMillis.present) {
      map['next_attempt_at_millis'] = Variable<int>(nextAttemptAtMillis.value);
    }
    if (sourceReleased.present) {
      map['source_released'] = Variable<bool>(sourceReleased.value);
    }
    if (localCleanupError.present) {
      map['local_cleanup_error'] = Variable<String>(localCleanupError.value);
    }
    if (createdAtMillis.present) {
      map['created_at_millis'] = Variable<int>(createdAtMillis.value);
    }
    if (updatedAtMillis.present) {
      map['updated_at_millis'] = Variable<int>(updatedAtMillis.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AttachmentJobsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('jobId: $jobId, ')
          ..write('serverUrl: $serverUrl, ')
          ..write('capabilityGeneration: $capabilityGeneration, ')
          ..write('replayContractRevision: $replayContractRevision, ')
          ..write('davUserId: $davUserId, ')
          ..write('roomToken: $roomToken, ')
          ..write('referenceId: $referenceId, ')
          ..write('sourceHandle: $sourceHandle, ')
          ..write('sourceOwnership: $sourceOwnership, ')
          ..write('sourceByteLength: $sourceByteLength, ')
          ..write('sourceSha256: $sourceSha256, ')
          ..write('sourceMimeType: $sourceMimeType, ')
          ..write('sourceDisplayName: $sourceDisplayName, ')
          ..write('messageKind: $messageKind, ')
          ..write('caption: $caption, ')
          ..write('replyTo: $replyTo, ')
          ..write('threadId: $threadId, ')
          ..write('threadTitle: $threadTitle, ')
          ..write('silent: $silent, ')
          ..write('enqueueSequence: $enqueueSequence, ')
          ..write('normalUploadMaximumBytes: $normalUploadMaximumBytes, ')
          ..write('chunkSizeBytes: $chunkSizeBytes, ')
          ..write('uploadSessionId: $uploadSessionId, ')
          ..write('phase: $phase, ')
          ..write('resumePhase: $resumePhase, ')
          ..write('remoteDraftFolder: $remoteDraftFolder, ')
          ..write('remoteTemporaryPath: $remoteTemporaryPath, ')
          ..write('chunkCollectionReady: $chunkCollectionReady, ')
          ..write('chunkManifestLoaded: $chunkManifestLoaded, ')
          ..write('verifiedChunksJson: $verifiedChunksJson, ')
          ..write('inFlightStep: $inFlightStep, ')
          ..write('inFlightRequestId: $inFlightRequestId, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('finalizationDispatched: $finalizationDispatched, ')
          ..write('cleanupChunkSession: $cleanupChunkSession, ')
          ..write('cleanupDraftFile: $cleanupDraftFile, ')
          ..write('messageIdsJson: $messageIdsJson, ')
          ..write('errorClass: $errorClass, ')
          ..write('profileFederated: $profileFederated, ')
          ..write('profileEnabled: $profileEnabled, ')
          ..write('profileCaption: $profileCaption, ')
          ..write('profileVoice: $profileVoice, ')
          ..write('profileReply: $profileReply, ')
          ..write('profileThreads: $profileThreads, ')
          ..write('profileSilent: $profileSilent, ')
          ..write('roomCanWrite: $roomCanWrite, ')
          ..write('automaticRetryCount: $automaticRetryCount, ')
          ..write('nextAttemptAtMillis: $nextAttemptAtMillis, ')
          ..write('sourceReleased: $sourceReleased, ')
          ..write('localCleanupError: $localCleanupError, ')
          ..write('createdAtMillis: $createdAtMillis, ')
          ..write('updatedAtMillis: $updatedAtMillis, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $AccountsTable accounts = $AccountsTable(this);
  late final $CachedConversationsTable cachedConversations =
      $CachedConversationsTable(this);
  late final $ConversationAvatarsTable conversationAvatars =
      $ConversationAvatarsTable(this);
  late final $ChatCapabilitiesTable chatCapabilities = $ChatCapabilitiesTable(
    this,
  );
  late final $ChatScopesTable chatScopes = $ChatScopesTable(this);
  late final $CachedChatMessagesTable cachedChatMessages =
      $CachedChatMessagesTable(this);
  late final $TextSendOperationsTable textSendOperations =
      $TextSendOperationsTable(this);
  late final $ChatDraftsTable chatDrafts = $ChatDraftsTable(this);
  late final $AttachmentRuntimeAccountsTable attachmentRuntimeAccounts =
      $AttachmentRuntimeAccountsTable(this);
  late final $AttachmentJobsTable attachmentJobs = $AttachmentJobsTable(this);
  late final Index cachedChatMessagesAttachmentConfirmation = Index(
    'cached_chat_messages_attachment_confirmation',
    'CREATE INDEX cached_chat_messages_attachment_confirmation ON cached_chat_messages (account_id, room_token, reference_id, message_id)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    accounts,
    cachedConversations,
    conversationAvatars,
    chatCapabilities,
    chatScopes,
    cachedChatMessages,
    textSendOperations,
    chatDrafts,
    attachmentRuntimeAccounts,
    attachmentJobs,
    cachedChatMessagesAttachmentConfirmation,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('cached_conversations', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('conversation_avatars', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('chat_capabilities', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('chat_scopes', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('cached_chat_messages', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('text_send_operations', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('chat_drafts', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$AccountsTableCreateCompanionBuilder =
    AccountsCompanion Function({
      required String id,
      required String serverUrl,
      required String loginName,
      required String serverProductName,
      Value<String> talkFeaturesJson,
      Value<bool> selected,
      required int createdAtMillis,
      Value<String?> conversationCursor,
      Value<String?> conversationHash,
      Value<String?> emptyConfirmationRequestId,
      Value<int?> emptyConfirmationObservedAtMillis,
      Value<int?> lastSyncedAtMillis,
      Value<String?> lastSyncError,
      Value<int> rowid,
    });
typedef $$AccountsTableUpdateCompanionBuilder =
    AccountsCompanion Function({
      Value<String> id,
      Value<String> serverUrl,
      Value<String> loginName,
      Value<String> serverProductName,
      Value<String> talkFeaturesJson,
      Value<bool> selected,
      Value<int> createdAtMillis,
      Value<String?> conversationCursor,
      Value<String?> conversationHash,
      Value<String?> emptyConfirmationRequestId,
      Value<int?> emptyConfirmationObservedAtMillis,
      Value<int?> lastSyncedAtMillis,
      Value<String?> lastSyncError,
      Value<int> rowid,
    });

final class $$AccountsTableReferences
    extends BaseReferences<_$AppDatabase, $AccountsTable, StoredAccount> {
  $$AccountsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<
    $CachedConversationsTable,
    List<CachedConversation>
  >
  _cachedConversationsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.cachedConversations,
        aliasName: 'accounts__id__cached_conversations__account_id',
      );

  $$CachedConversationsTableProcessedTableManager get cachedConversationsRefs {
    final manager = $$CachedConversationsTableTableManager(
      $_db,
      $_db.cachedConversations,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _cachedConversationsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $ConversationAvatarsTable,
    List<StoredConversationAvatar>
  >
  _conversationAvatarsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.conversationAvatars,
        aliasName: 'accounts__id__conversation_avatars__account_id',
      );

  $$ConversationAvatarsTableProcessedTableManager get conversationAvatarsRefs {
    final manager = $$ConversationAvatarsTableTableManager(
      $_db,
      $_db.conversationAvatars,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _conversationAvatarsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ChatCapabilitiesTable, List<StoredChatCapability>>
  _chatCapabilitiesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.chatCapabilities,
    aliasName: 'accounts__id__chat_capabilities__account_id',
  );

  $$ChatCapabilitiesTableProcessedTableManager get chatCapabilitiesRefs {
    final manager = $$ChatCapabilitiesTableTableManager(
      $_db,
      $_db.chatCapabilities,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _chatCapabilitiesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ChatScopesTable, List<StoredChatScope>>
  _chatScopesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.chatScopes,
    aliasName: 'accounts__id__chat_scopes__account_id',
  );

  $$ChatScopesTableProcessedTableManager get chatScopesRefs {
    final manager = $$ChatScopesTableTableManager(
      $_db,
      $_db.chatScopes,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_chatScopesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$CachedChatMessagesTable, List<CachedChatMessage>>
  _cachedChatMessagesRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.cachedChatMessages,
        aliasName: 'accounts__id__cached_chat_messages__account_id',
      );

  $$CachedChatMessagesTableProcessedTableManager get cachedChatMessagesRefs {
    final manager = $$CachedChatMessagesTableTableManager(
      $_db,
      $_db.cachedChatMessages,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _cachedChatMessagesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $TextSendOperationsTable,
    List<StoredTextSendOperation>
  >
  _textSendOperationsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.textSendOperations,
        aliasName: 'accounts__id__text_send_operations__account_id',
      );

  $$TextSendOperationsTableProcessedTableManager get textSendOperationsRefs {
    final manager = $$TextSendOperationsTableTableManager(
      $_db,
      $_db.textSendOperations,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _textSendOperationsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ChatDraftsTable, List<StoredChatDraft>>
  _chatDraftsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.chatDrafts,
    aliasName: 'accounts__id__chat_drafts__account_id',
  );

  $$ChatDraftsTableProcessedTableManager get chatDraftsRefs {
    final manager = $$ChatDraftsTableTableManager(
      $_db,
      $_db.chatDrafts,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_chatDraftsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $AttachmentRuntimeAccountsTable,
    List<StoredAttachmentRuntimeAccount>
  >
  _attachmentRuntimeAccountsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.attachmentRuntimeAccounts,
        aliasName: 'accounts__id__attachment_runtime_accounts__account_id',
      );

  $$AttachmentRuntimeAccountsTableProcessedTableManager
  get attachmentRuntimeAccountsRefs {
    final manager = $$AttachmentRuntimeAccountsTableTableManager(
      $_db,
      $_db.attachmentRuntimeAccounts,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _attachmentRuntimeAccountsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$AccountsTableFilterComposer
    extends Composer<_$AppDatabase, $AccountsTable> {
  $$AccountsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverUrl => $composableBuilder(
    column: $table.serverUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get loginName => $composableBuilder(
    column: $table.loginName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverProductName => $composableBuilder(
    column: $table.serverProductName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get talkFeaturesJson => $composableBuilder(
    column: $table.talkFeaturesJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get selected => $composableBuilder(
    column: $table.selected,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtMillis => $composableBuilder(
    column: $table.createdAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationCursor => $composableBuilder(
    column: $table.conversationCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationHash => $composableBuilder(
    column: $table.conversationHash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get emptyConfirmationRequestId => $composableBuilder(
    column: $table.emptyConfirmationRequestId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get emptyConfirmationObservedAtMillis =>
      $composableBuilder(
        column: $table.emptyConfirmationObservedAtMillis,
        builder: (column) => ColumnFilters(column),
      );

  ColumnFilters<int> get lastSyncedAtMillis => $composableBuilder(
    column: $table.lastSyncedAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastSyncError => $composableBuilder(
    column: $table.lastSyncError,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> cachedConversationsRefs(
    Expression<bool> Function($$CachedConversationsTableFilterComposer f) f,
  ) {
    final $$CachedConversationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.cachedConversations,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedConversationsTableFilterComposer(
            $db: $db,
            $table: $db.cachedConversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> conversationAvatarsRefs(
    Expression<bool> Function($$ConversationAvatarsTableFilterComposer f) f,
  ) {
    final $$ConversationAvatarsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.conversationAvatars,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationAvatarsTableFilterComposer(
            $db: $db,
            $table: $db.conversationAvatars,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> chatCapabilitiesRefs(
    Expression<bool> Function($$ChatCapabilitiesTableFilterComposer f) f,
  ) {
    final $$ChatCapabilitiesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.chatCapabilities,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ChatCapabilitiesTableFilterComposer(
            $db: $db,
            $table: $db.chatCapabilities,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> chatScopesRefs(
    Expression<bool> Function($$ChatScopesTableFilterComposer f) f,
  ) {
    final $$ChatScopesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.chatScopes,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ChatScopesTableFilterComposer(
            $db: $db,
            $table: $db.chatScopes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> cachedChatMessagesRefs(
    Expression<bool> Function($$CachedChatMessagesTableFilterComposer f) f,
  ) {
    final $$CachedChatMessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.cachedChatMessages,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedChatMessagesTableFilterComposer(
            $db: $db,
            $table: $db.cachedChatMessages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> textSendOperationsRefs(
    Expression<bool> Function($$TextSendOperationsTableFilterComposer f) f,
  ) {
    final $$TextSendOperationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.textSendOperations,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TextSendOperationsTableFilterComposer(
            $db: $db,
            $table: $db.textSendOperations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> chatDraftsRefs(
    Expression<bool> Function($$ChatDraftsTableFilterComposer f) f,
  ) {
    final $$ChatDraftsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.chatDrafts,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ChatDraftsTableFilterComposer(
            $db: $db,
            $table: $db.chatDrafts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> attachmentRuntimeAccountsRefs(
    Expression<bool> Function($$AttachmentRuntimeAccountsTableFilterComposer f)
    f,
  ) {
    final $$AttachmentRuntimeAccountsTableFilterComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.attachmentRuntimeAccounts,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$AttachmentRuntimeAccountsTableFilterComposer(
                $db: $db,
                $table: $db.attachmentRuntimeAccounts,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$AccountsTableOrderingComposer
    extends Composer<_$AppDatabase, $AccountsTable> {
  $$AccountsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverUrl => $composableBuilder(
    column: $table.serverUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get loginName => $composableBuilder(
    column: $table.loginName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverProductName => $composableBuilder(
    column: $table.serverProductName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get talkFeaturesJson => $composableBuilder(
    column: $table.talkFeaturesJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get selected => $composableBuilder(
    column: $table.selected,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtMillis => $composableBuilder(
    column: $table.createdAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationCursor => $composableBuilder(
    column: $table.conversationCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationHash => $composableBuilder(
    column: $table.conversationHash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get emptyConfirmationRequestId => $composableBuilder(
    column: $table.emptyConfirmationRequestId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get emptyConfirmationObservedAtMillis =>
      $composableBuilder(
        column: $table.emptyConfirmationObservedAtMillis,
        builder: (column) => ColumnOrderings(column),
      );

  ColumnOrderings<int> get lastSyncedAtMillis => $composableBuilder(
    column: $table.lastSyncedAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastSyncError => $composableBuilder(
    column: $table.lastSyncError,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AccountsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AccountsTable> {
  $$AccountsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get serverUrl =>
      $composableBuilder(column: $table.serverUrl, builder: (column) => column);

  GeneratedColumn<String> get loginName =>
      $composableBuilder(column: $table.loginName, builder: (column) => column);

  GeneratedColumn<String> get serverProductName => $composableBuilder(
    column: $table.serverProductName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get talkFeaturesJson => $composableBuilder(
    column: $table.talkFeaturesJson,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get selected =>
      $composableBuilder(column: $table.selected, builder: (column) => column);

  GeneratedColumn<int> get createdAtMillis => $composableBuilder(
    column: $table.createdAtMillis,
    builder: (column) => column,
  );

  GeneratedColumn<String> get conversationCursor => $composableBuilder(
    column: $table.conversationCursor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get conversationHash => $composableBuilder(
    column: $table.conversationHash,
    builder: (column) => column,
  );

  GeneratedColumn<String> get emptyConfirmationRequestId => $composableBuilder(
    column: $table.emptyConfirmationRequestId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get emptyConfirmationObservedAtMillis =>
      $composableBuilder(
        column: $table.emptyConfirmationObservedAtMillis,
        builder: (column) => column,
      );

  GeneratedColumn<int> get lastSyncedAtMillis => $composableBuilder(
    column: $table.lastSyncedAtMillis,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastSyncError => $composableBuilder(
    column: $table.lastSyncError,
    builder: (column) => column,
  );

  Expression<T> cachedConversationsRefs<T extends Object>(
    Expression<T> Function($$CachedConversationsTableAnnotationComposer a) f,
  ) {
    final $$CachedConversationsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.cachedConversations,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CachedConversationsTableAnnotationComposer(
                $db: $db,
                $table: $db.cachedConversations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> conversationAvatarsRefs<T extends Object>(
    Expression<T> Function($$ConversationAvatarsTableAnnotationComposer a) f,
  ) {
    final $$ConversationAvatarsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.conversationAvatars,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ConversationAvatarsTableAnnotationComposer(
                $db: $db,
                $table: $db.conversationAvatars,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> chatCapabilitiesRefs<T extends Object>(
    Expression<T> Function($$ChatCapabilitiesTableAnnotationComposer a) f,
  ) {
    final $$ChatCapabilitiesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.chatCapabilities,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ChatCapabilitiesTableAnnotationComposer(
            $db: $db,
            $table: $db.chatCapabilities,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> chatScopesRefs<T extends Object>(
    Expression<T> Function($$ChatScopesTableAnnotationComposer a) f,
  ) {
    final $$ChatScopesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.chatScopes,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ChatScopesTableAnnotationComposer(
            $db: $db,
            $table: $db.chatScopes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> cachedChatMessagesRefs<T extends Object>(
    Expression<T> Function($$CachedChatMessagesTableAnnotationComposer a) f,
  ) {
    final $$CachedChatMessagesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.cachedChatMessages,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CachedChatMessagesTableAnnotationComposer(
                $db: $db,
                $table: $db.cachedChatMessages,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> textSendOperationsRefs<T extends Object>(
    Expression<T> Function($$TextSendOperationsTableAnnotationComposer a) f,
  ) {
    final $$TextSendOperationsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.textSendOperations,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$TextSendOperationsTableAnnotationComposer(
                $db: $db,
                $table: $db.textSendOperations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> chatDraftsRefs<T extends Object>(
    Expression<T> Function($$ChatDraftsTableAnnotationComposer a) f,
  ) {
    final $$ChatDraftsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.chatDrafts,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ChatDraftsTableAnnotationComposer(
            $db: $db,
            $table: $db.chatDrafts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> attachmentRuntimeAccountsRefs<T extends Object>(
    Expression<T> Function($$AttachmentRuntimeAccountsTableAnnotationComposer a)
    f,
  ) {
    final $$AttachmentRuntimeAccountsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.attachmentRuntimeAccounts,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$AttachmentRuntimeAccountsTableAnnotationComposer(
                $db: $db,
                $table: $db.attachmentRuntimeAccounts,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$AccountsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AccountsTable,
          StoredAccount,
          $$AccountsTableFilterComposer,
          $$AccountsTableOrderingComposer,
          $$AccountsTableAnnotationComposer,
          $$AccountsTableCreateCompanionBuilder,
          $$AccountsTableUpdateCompanionBuilder,
          (StoredAccount, $$AccountsTableReferences),
          StoredAccount,
          PrefetchHooks Function({
            bool cachedConversationsRefs,
            bool conversationAvatarsRefs,
            bool chatCapabilitiesRefs,
            bool chatScopesRefs,
            bool cachedChatMessagesRefs,
            bool textSendOperationsRefs,
            bool chatDraftsRefs,
            bool attachmentRuntimeAccountsRefs,
          })
        > {
  $$AccountsTableTableManager(_$AppDatabase db, $AccountsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AccountsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AccountsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AccountsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> serverUrl = const Value.absent(),
                Value<String> loginName = const Value.absent(),
                Value<String> serverProductName = const Value.absent(),
                Value<String> talkFeaturesJson = const Value.absent(),
                Value<bool> selected = const Value.absent(),
                Value<int> createdAtMillis = const Value.absent(),
                Value<String?> conversationCursor = const Value.absent(),
                Value<String?> conversationHash = const Value.absent(),
                Value<String?> emptyConfirmationRequestId =
                    const Value.absent(),
                Value<int?> emptyConfirmationObservedAtMillis =
                    const Value.absent(),
                Value<int?> lastSyncedAtMillis = const Value.absent(),
                Value<String?> lastSyncError = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AccountsCompanion(
                id: id,
                serverUrl: serverUrl,
                loginName: loginName,
                serverProductName: serverProductName,
                talkFeaturesJson: talkFeaturesJson,
                selected: selected,
                createdAtMillis: createdAtMillis,
                conversationCursor: conversationCursor,
                conversationHash: conversationHash,
                emptyConfirmationRequestId: emptyConfirmationRequestId,
                emptyConfirmationObservedAtMillis:
                    emptyConfirmationObservedAtMillis,
                lastSyncedAtMillis: lastSyncedAtMillis,
                lastSyncError: lastSyncError,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String serverUrl,
                required String loginName,
                required String serverProductName,
                Value<String> talkFeaturesJson = const Value.absent(),
                Value<bool> selected = const Value.absent(),
                required int createdAtMillis,
                Value<String?> conversationCursor = const Value.absent(),
                Value<String?> conversationHash = const Value.absent(),
                Value<String?> emptyConfirmationRequestId =
                    const Value.absent(),
                Value<int?> emptyConfirmationObservedAtMillis =
                    const Value.absent(),
                Value<int?> lastSyncedAtMillis = const Value.absent(),
                Value<String?> lastSyncError = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AccountsCompanion.insert(
                id: id,
                serverUrl: serverUrl,
                loginName: loginName,
                serverProductName: serverProductName,
                talkFeaturesJson: talkFeaturesJson,
                selected: selected,
                createdAtMillis: createdAtMillis,
                conversationCursor: conversationCursor,
                conversationHash: conversationHash,
                emptyConfirmationRequestId: emptyConfirmationRequestId,
                emptyConfirmationObservedAtMillis:
                    emptyConfirmationObservedAtMillis,
                lastSyncedAtMillis: lastSyncedAtMillis,
                lastSyncError: lastSyncError,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$AccountsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                cachedConversationsRefs = false,
                conversationAvatarsRefs = false,
                chatCapabilitiesRefs = false,
                chatScopesRefs = false,
                cachedChatMessagesRefs = false,
                textSendOperationsRefs = false,
                chatDraftsRefs = false,
                attachmentRuntimeAccountsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (cachedConversationsRefs) db.cachedConversations,
                    if (conversationAvatarsRefs) db.conversationAvatars,
                    if (chatCapabilitiesRefs) db.chatCapabilities,
                    if (chatScopesRefs) db.chatScopes,
                    if (cachedChatMessagesRefs) db.cachedChatMessages,
                    if (textSendOperationsRefs) db.textSendOperations,
                    if (chatDraftsRefs) db.chatDrafts,
                    if (attachmentRuntimeAccountsRefs)
                      db.attachmentRuntimeAccounts,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (cachedConversationsRefs)
                        await $_getPrefetchedData<
                          StoredAccount,
                          $AccountsTable,
                          CachedConversation
                        >(
                          currentTable: table,
                          referencedTable: $$AccountsTableReferences
                              ._cachedConversationsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).cachedConversationsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (conversationAvatarsRefs)
                        await $_getPrefetchedData<
                          StoredAccount,
                          $AccountsTable,
                          StoredConversationAvatar
                        >(
                          currentTable: table,
                          referencedTable: $$AccountsTableReferences
                              ._conversationAvatarsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).conversationAvatarsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (chatCapabilitiesRefs)
                        await $_getPrefetchedData<
                          StoredAccount,
                          $AccountsTable,
                          StoredChatCapability
                        >(
                          currentTable: table,
                          referencedTable: $$AccountsTableReferences
                              ._chatCapabilitiesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).chatCapabilitiesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (chatScopesRefs)
                        await $_getPrefetchedData<
                          StoredAccount,
                          $AccountsTable,
                          StoredChatScope
                        >(
                          currentTable: table,
                          referencedTable: $$AccountsTableReferences
                              ._chatScopesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).chatScopesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (cachedChatMessagesRefs)
                        await $_getPrefetchedData<
                          StoredAccount,
                          $AccountsTable,
                          CachedChatMessage
                        >(
                          currentTable: table,
                          referencedTable: $$AccountsTableReferences
                              ._cachedChatMessagesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).cachedChatMessagesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (textSendOperationsRefs)
                        await $_getPrefetchedData<
                          StoredAccount,
                          $AccountsTable,
                          StoredTextSendOperation
                        >(
                          currentTable: table,
                          referencedTable: $$AccountsTableReferences
                              ._textSendOperationsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).textSendOperationsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (chatDraftsRefs)
                        await $_getPrefetchedData<
                          StoredAccount,
                          $AccountsTable,
                          StoredChatDraft
                        >(
                          currentTable: table,
                          referencedTable: $$AccountsTableReferences
                              ._chatDraftsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).chatDraftsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (attachmentRuntimeAccountsRefs)
                        await $_getPrefetchedData<
                          StoredAccount,
                          $AccountsTable,
                          StoredAttachmentRuntimeAccount
                        >(
                          currentTable: table,
                          referencedTable: $$AccountsTableReferences
                              ._attachmentRuntimeAccountsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).attachmentRuntimeAccountsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$AccountsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AccountsTable,
      StoredAccount,
      $$AccountsTableFilterComposer,
      $$AccountsTableOrderingComposer,
      $$AccountsTableAnnotationComposer,
      $$AccountsTableCreateCompanionBuilder,
      $$AccountsTableUpdateCompanionBuilder,
      (StoredAccount, $$AccountsTableReferences),
      StoredAccount,
      PrefetchHooks Function({
        bool cachedConversationsRefs,
        bool conversationAvatarsRefs,
        bool chatCapabilitiesRefs,
        bool chatScopesRefs,
        bool cachedChatMessagesRefs,
        bool textSendOperationsRefs,
        bool chatDraftsRefs,
        bool attachmentRuntimeAccountsRefs,
      })
    >;
typedef $$CachedConversationsTableCreateCompanionBuilder =
    CachedConversationsCompanion Function({
      required String accountId,
      required String token,
      required String displayName,
      required String description,
      required int lastActivity,
      required int unreadMessages,
      required bool favorite,
      Value<bool> isArchived,
      Value<int> readOnly,
      Value<int> roomType,
      Value<String> roomName,
      Value<String> objectType,
      Value<String> avatarVersion,
      Value<bool> isCustomAvatar,
      Value<String?> peerStatus,
      Value<String?> peerStatusIcon,
      Value<String?> peerStatusMessage,
      Value<int?> peerStatusClearAt,
      Value<String?> lastMessageText,
      Value<int?> lastMessageTimestamp,
      required String rawJson,
      Value<int> rowid,
    });
typedef $$CachedConversationsTableUpdateCompanionBuilder =
    CachedConversationsCompanion Function({
      Value<String> accountId,
      Value<String> token,
      Value<String> displayName,
      Value<String> description,
      Value<int> lastActivity,
      Value<int> unreadMessages,
      Value<bool> favorite,
      Value<bool> isArchived,
      Value<int> readOnly,
      Value<int> roomType,
      Value<String> roomName,
      Value<String> objectType,
      Value<String> avatarVersion,
      Value<bool> isCustomAvatar,
      Value<String?> peerStatus,
      Value<String?> peerStatusIcon,
      Value<String?> peerStatusMessage,
      Value<int?> peerStatusClearAt,
      Value<String?> lastMessageText,
      Value<int?> lastMessageTimestamp,
      Value<String> rawJson,
      Value<int> rowid,
    });

final class $$CachedConversationsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $CachedConversationsTable,
          CachedConversation
        > {
  $$CachedConversationsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $AccountsTable _accountIdTable(_$AppDatabase db) =>
      db.accounts.createAlias('cached_conversations__account_id__accounts__id');

  $$AccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$AccountsTableTableManager(
      $_db,
      $_db.accounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CachedConversationsTableFilterComposer
    extends Composer<_$AppDatabase, $CachedConversationsTable> {
  $$CachedConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get token => $composableBuilder(
    column: $table.token,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastActivity => $composableBuilder(
    column: $table.lastActivity,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get unreadMessages => $composableBuilder(
    column: $table.unreadMessages,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get favorite => $composableBuilder(
    column: $table.favorite,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isArchived => $composableBuilder(
    column: $table.isArchived,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get readOnly => $composableBuilder(
    column: $table.readOnly,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get roomType => $composableBuilder(
    column: $table.roomType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roomName => $composableBuilder(
    column: $table.roomName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get objectType => $composableBuilder(
    column: $table.objectType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get avatarVersion => $composableBuilder(
    column: $table.avatarVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isCustomAvatar => $composableBuilder(
    column: $table.isCustomAvatar,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peerStatus => $composableBuilder(
    column: $table.peerStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peerStatusIcon => $composableBuilder(
    column: $table.peerStatusIcon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peerStatusMessage => $composableBuilder(
    column: $table.peerStatusMessage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get peerStatusClearAt => $composableBuilder(
    column: $table.peerStatusClearAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastMessageText => $composableBuilder(
    column: $table.lastMessageText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastMessageTimestamp => $composableBuilder(
    column: $table.lastMessageTimestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rawJson => $composableBuilder(
    column: $table.rawJson,
    builder: (column) => ColumnFilters(column),
  );

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableFilterComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedConversationsTableOrderingComposer
    extends Composer<_$AppDatabase, $CachedConversationsTable> {
  $$CachedConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get token => $composableBuilder(
    column: $table.token,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastActivity => $composableBuilder(
    column: $table.lastActivity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get unreadMessages => $composableBuilder(
    column: $table.unreadMessages,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get favorite => $composableBuilder(
    column: $table.favorite,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isArchived => $composableBuilder(
    column: $table.isArchived,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get readOnly => $composableBuilder(
    column: $table.readOnly,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get roomType => $composableBuilder(
    column: $table.roomType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roomName => $composableBuilder(
    column: $table.roomName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get objectType => $composableBuilder(
    column: $table.objectType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get avatarVersion => $composableBuilder(
    column: $table.avatarVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isCustomAvatar => $composableBuilder(
    column: $table.isCustomAvatar,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peerStatus => $composableBuilder(
    column: $table.peerStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peerStatusIcon => $composableBuilder(
    column: $table.peerStatusIcon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peerStatusMessage => $composableBuilder(
    column: $table.peerStatusMessage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get peerStatusClearAt => $composableBuilder(
    column: $table.peerStatusClearAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastMessageText => $composableBuilder(
    column: $table.lastMessageText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastMessageTimestamp => $composableBuilder(
    column: $table.lastMessageTimestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rawJson => $composableBuilder(
    column: $table.rawJson,
    builder: (column) => ColumnOrderings(column),
  );

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableOrderingComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedConversationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CachedConversationsTable> {
  $$CachedConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get token =>
      $composableBuilder(column: $table.token, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastActivity => $composableBuilder(
    column: $table.lastActivity,
    builder: (column) => column,
  );

  GeneratedColumn<int> get unreadMessages => $composableBuilder(
    column: $table.unreadMessages,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get favorite =>
      $composableBuilder(column: $table.favorite, builder: (column) => column);

  GeneratedColumn<bool> get isArchived => $composableBuilder(
    column: $table.isArchived,
    builder: (column) => column,
  );

  GeneratedColumn<int> get readOnly =>
      $composableBuilder(column: $table.readOnly, builder: (column) => column);

  GeneratedColumn<int> get roomType =>
      $composableBuilder(column: $table.roomType, builder: (column) => column);

  GeneratedColumn<String> get roomName =>
      $composableBuilder(column: $table.roomName, builder: (column) => column);

  GeneratedColumn<String> get objectType => $composableBuilder(
    column: $table.objectType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get avatarVersion => $composableBuilder(
    column: $table.avatarVersion,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isCustomAvatar => $composableBuilder(
    column: $table.isCustomAvatar,
    builder: (column) => column,
  );

  GeneratedColumn<String> get peerStatus => $composableBuilder(
    column: $table.peerStatus,
    builder: (column) => column,
  );

  GeneratedColumn<String> get peerStatusIcon => $composableBuilder(
    column: $table.peerStatusIcon,
    builder: (column) => column,
  );

  GeneratedColumn<String> get peerStatusMessage => $composableBuilder(
    column: $table.peerStatusMessage,
    builder: (column) => column,
  );

  GeneratedColumn<int> get peerStatusClearAt => $composableBuilder(
    column: $table.peerStatusClearAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastMessageText => $composableBuilder(
    column: $table.lastMessageText,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastMessageTimestamp => $composableBuilder(
    column: $table.lastMessageTimestamp,
    builder: (column) => column,
  );

  GeneratedColumn<String> get rawJson =>
      $composableBuilder(column: $table.rawJson, builder: (column) => column);

  $$AccountsTableAnnotationComposer get accountId {
    final $$AccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedConversationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CachedConversationsTable,
          CachedConversation,
          $$CachedConversationsTableFilterComposer,
          $$CachedConversationsTableOrderingComposer,
          $$CachedConversationsTableAnnotationComposer,
          $$CachedConversationsTableCreateCompanionBuilder,
          $$CachedConversationsTableUpdateCompanionBuilder,
          (CachedConversation, $$CachedConversationsTableReferences),
          CachedConversation,
          PrefetchHooks Function({bool accountId})
        > {
  $$CachedConversationsTableTableManager(
    _$AppDatabase db,
    $CachedConversationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedConversationsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$CachedConversationsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> token = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String> description = const Value.absent(),
                Value<int> lastActivity = const Value.absent(),
                Value<int> unreadMessages = const Value.absent(),
                Value<bool> favorite = const Value.absent(),
                Value<bool> isArchived = const Value.absent(),
                Value<int> readOnly = const Value.absent(),
                Value<int> roomType = const Value.absent(),
                Value<String> roomName = const Value.absent(),
                Value<String> objectType = const Value.absent(),
                Value<String> avatarVersion = const Value.absent(),
                Value<bool> isCustomAvatar = const Value.absent(),
                Value<String?> peerStatus = const Value.absent(),
                Value<String?> peerStatusIcon = const Value.absent(),
                Value<String?> peerStatusMessage = const Value.absent(),
                Value<int?> peerStatusClearAt = const Value.absent(),
                Value<String?> lastMessageText = const Value.absent(),
                Value<int?> lastMessageTimestamp = const Value.absent(),
                Value<String> rawJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedConversationsCompanion(
                accountId: accountId,
                token: token,
                displayName: displayName,
                description: description,
                lastActivity: lastActivity,
                unreadMessages: unreadMessages,
                favorite: favorite,
                isArchived: isArchived,
                readOnly: readOnly,
                roomType: roomType,
                roomName: roomName,
                objectType: objectType,
                avatarVersion: avatarVersion,
                isCustomAvatar: isCustomAvatar,
                peerStatus: peerStatus,
                peerStatusIcon: peerStatusIcon,
                peerStatusMessage: peerStatusMessage,
                peerStatusClearAt: peerStatusClearAt,
                lastMessageText: lastMessageText,
                lastMessageTimestamp: lastMessageTimestamp,
                rawJson: rawJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String token,
                required String displayName,
                required String description,
                required int lastActivity,
                required int unreadMessages,
                required bool favorite,
                Value<bool> isArchived = const Value.absent(),
                Value<int> readOnly = const Value.absent(),
                Value<int> roomType = const Value.absent(),
                Value<String> roomName = const Value.absent(),
                Value<String> objectType = const Value.absent(),
                Value<String> avatarVersion = const Value.absent(),
                Value<bool> isCustomAvatar = const Value.absent(),
                Value<String?> peerStatus = const Value.absent(),
                Value<String?> peerStatusIcon = const Value.absent(),
                Value<String?> peerStatusMessage = const Value.absent(),
                Value<int?> peerStatusClearAt = const Value.absent(),
                Value<String?> lastMessageText = const Value.absent(),
                Value<int?> lastMessageTimestamp = const Value.absent(),
                required String rawJson,
                Value<int> rowid = const Value.absent(),
              }) => CachedConversationsCompanion.insert(
                accountId: accountId,
                token: token,
                displayName: displayName,
                description: description,
                lastActivity: lastActivity,
                unreadMessages: unreadMessages,
                favorite: favorite,
                isArchived: isArchived,
                readOnly: readOnly,
                roomType: roomType,
                roomName: roomName,
                objectType: objectType,
                avatarVersion: avatarVersion,
                isCustomAvatar: isCustomAvatar,
                peerStatus: peerStatus,
                peerStatusIcon: peerStatusIcon,
                peerStatusMessage: peerStatusMessage,
                peerStatusClearAt: peerStatusClearAt,
                lastMessageText: lastMessageText,
                lastMessageTimestamp: lastMessageTimestamp,
                rawJson: rawJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CachedConversationsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable:
                                    $$CachedConversationsTableReferences
                                        ._accountIdTable(db),
                                referencedColumn:
                                    $$CachedConversationsTableReferences
                                        ._accountIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CachedConversationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CachedConversationsTable,
      CachedConversation,
      $$CachedConversationsTableFilterComposer,
      $$CachedConversationsTableOrderingComposer,
      $$CachedConversationsTableAnnotationComposer,
      $$CachedConversationsTableCreateCompanionBuilder,
      $$CachedConversationsTableUpdateCompanionBuilder,
      (CachedConversation, $$CachedConversationsTableReferences),
      CachedConversation,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$ConversationAvatarsTableCreateCompanionBuilder =
    ConversationAvatarsCompanion Function({
      required String accountId,
      required String cacheKey,
      required Uint8List body,
      required String contentType,
      Value<bool?> isCustomAvatar,
      Value<String?> etag,
      Value<String?> lastModified,
      required int expiresAtMillis,
      required int updatedAtMillis,
      Value<int> rowid,
    });
typedef $$ConversationAvatarsTableUpdateCompanionBuilder =
    ConversationAvatarsCompanion Function({
      Value<String> accountId,
      Value<String> cacheKey,
      Value<Uint8List> body,
      Value<String> contentType,
      Value<bool?> isCustomAvatar,
      Value<String?> etag,
      Value<String?> lastModified,
      Value<int> expiresAtMillis,
      Value<int> updatedAtMillis,
      Value<int> rowid,
    });

final class $$ConversationAvatarsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $ConversationAvatarsTable,
          StoredConversationAvatar
        > {
  $$ConversationAvatarsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $AccountsTable _accountIdTable(_$AppDatabase db) =>
      db.accounts.createAlias('conversation_avatars__account_id__accounts__id');

  $$AccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$AccountsTableTableManager(
      $_db,
      $_db.accounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ConversationAvatarsTableFilterComposer
    extends Composer<_$AppDatabase, $ConversationAvatarsTable> {
  $$ConversationAvatarsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get cacheKey => $composableBuilder(
    column: $table.cacheKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentType => $composableBuilder(
    column: $table.contentType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isCustomAvatar => $composableBuilder(
    column: $table.isCustomAvatar,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastModified => $composableBuilder(
    column: $table.lastModified,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get expiresAtMillis => $composableBuilder(
    column: $table.expiresAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableFilterComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ConversationAvatarsTableOrderingComposer
    extends Composer<_$AppDatabase, $ConversationAvatarsTable> {
  $$ConversationAvatarsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get cacheKey => $composableBuilder(
    column: $table.cacheKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentType => $composableBuilder(
    column: $table.contentType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isCustomAvatar => $composableBuilder(
    column: $table.isCustomAvatar,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastModified => $composableBuilder(
    column: $table.lastModified,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get expiresAtMillis => $composableBuilder(
    column: $table.expiresAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableOrderingComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ConversationAvatarsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConversationAvatarsTable> {
  $$ConversationAvatarsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get cacheKey =>
      $composableBuilder(column: $table.cacheKey, builder: (column) => column);

  GeneratedColumn<Uint8List> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get contentType => $composableBuilder(
    column: $table.contentType,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isCustomAvatar => $composableBuilder(
    column: $table.isCustomAvatar,
    builder: (column) => column,
  );

  GeneratedColumn<String> get etag =>
      $composableBuilder(column: $table.etag, builder: (column) => column);

  GeneratedColumn<String> get lastModified => $composableBuilder(
    column: $table.lastModified,
    builder: (column) => column,
  );

  GeneratedColumn<int> get expiresAtMillis => $composableBuilder(
    column: $table.expiresAtMillis,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => column,
  );

  $$AccountsTableAnnotationComposer get accountId {
    final $$AccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ConversationAvatarsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ConversationAvatarsTable,
          StoredConversationAvatar,
          $$ConversationAvatarsTableFilterComposer,
          $$ConversationAvatarsTableOrderingComposer,
          $$ConversationAvatarsTableAnnotationComposer,
          $$ConversationAvatarsTableCreateCompanionBuilder,
          $$ConversationAvatarsTableUpdateCompanionBuilder,
          (StoredConversationAvatar, $$ConversationAvatarsTableReferences),
          StoredConversationAvatar,
          PrefetchHooks Function({bool accountId})
        > {
  $$ConversationAvatarsTableTableManager(
    _$AppDatabase db,
    $ConversationAvatarsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationAvatarsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationAvatarsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ConversationAvatarsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> cacheKey = const Value.absent(),
                Value<Uint8List> body = const Value.absent(),
                Value<String> contentType = const Value.absent(),
                Value<bool?> isCustomAvatar = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<String?> lastModified = const Value.absent(),
                Value<int> expiresAtMillis = const Value.absent(),
                Value<int> updatedAtMillis = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationAvatarsCompanion(
                accountId: accountId,
                cacheKey: cacheKey,
                body: body,
                contentType: contentType,
                isCustomAvatar: isCustomAvatar,
                etag: etag,
                lastModified: lastModified,
                expiresAtMillis: expiresAtMillis,
                updatedAtMillis: updatedAtMillis,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String cacheKey,
                required Uint8List body,
                required String contentType,
                Value<bool?> isCustomAvatar = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<String?> lastModified = const Value.absent(),
                required int expiresAtMillis,
                required int updatedAtMillis,
                Value<int> rowid = const Value.absent(),
              }) => ConversationAvatarsCompanion.insert(
                accountId: accountId,
                cacheKey: cacheKey,
                body: body,
                contentType: contentType,
                isCustomAvatar: isCustomAvatar,
                etag: etag,
                lastModified: lastModified,
                expiresAtMillis: expiresAtMillis,
                updatedAtMillis: updatedAtMillis,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ConversationAvatarsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable:
                                    $$ConversationAvatarsTableReferences
                                        ._accountIdTable(db),
                                referencedColumn:
                                    $$ConversationAvatarsTableReferences
                                        ._accountIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ConversationAvatarsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ConversationAvatarsTable,
      StoredConversationAvatar,
      $$ConversationAvatarsTableFilterComposer,
      $$ConversationAvatarsTableOrderingComposer,
      $$ConversationAvatarsTableAnnotationComposer,
      $$ConversationAvatarsTableCreateCompanionBuilder,
      $$ConversationAvatarsTableUpdateCompanionBuilder,
      (StoredConversationAvatar, $$ConversationAvatarsTableReferences),
      StoredConversationAvatar,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$ChatCapabilitiesTableCreateCompanionBuilder =
    ChatCapabilitiesCompanion Function({
      required String accountId,
      required String fingerprint,
      Value<int> generation,
      Value<int> credentialGeneration,
      Value<String> lane,
      required int updatedAtMillis,
      Value<int> rowid,
    });
typedef $$ChatCapabilitiesTableUpdateCompanionBuilder =
    ChatCapabilitiesCompanion Function({
      Value<String> accountId,
      Value<String> fingerprint,
      Value<int> generation,
      Value<int> credentialGeneration,
      Value<String> lane,
      Value<int> updatedAtMillis,
      Value<int> rowid,
    });

final class $$ChatCapabilitiesTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $ChatCapabilitiesTable,
          StoredChatCapability
        > {
  $$ChatCapabilitiesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $AccountsTable _accountIdTable(_$AppDatabase db) =>
      db.accounts.createAlias('chat_capabilities__account_id__accounts__id');

  $$AccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$AccountsTableTableManager(
      $_db,
      $_db.accounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ChatCapabilitiesTableFilterComposer
    extends Composer<_$AppDatabase, $ChatCapabilitiesTable> {
  $$ChatCapabilitiesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get credentialGeneration => $composableBuilder(
    column: $table.credentialGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lane => $composableBuilder(
    column: $table.lane,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableFilterComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ChatCapabilitiesTableOrderingComposer
    extends Composer<_$AppDatabase, $ChatCapabilitiesTable> {
  $$ChatCapabilitiesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get credentialGeneration => $composableBuilder(
    column: $table.credentialGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lane => $composableBuilder(
    column: $table.lane,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableOrderingComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ChatCapabilitiesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ChatCapabilitiesTable> {
  $$ChatCapabilitiesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<int> get credentialGeneration => $composableBuilder(
    column: $table.credentialGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lane =>
      $composableBuilder(column: $table.lane, builder: (column) => column);

  GeneratedColumn<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => column,
  );

  $$AccountsTableAnnotationComposer get accountId {
    final $$AccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ChatCapabilitiesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ChatCapabilitiesTable,
          StoredChatCapability,
          $$ChatCapabilitiesTableFilterComposer,
          $$ChatCapabilitiesTableOrderingComposer,
          $$ChatCapabilitiesTableAnnotationComposer,
          $$ChatCapabilitiesTableCreateCompanionBuilder,
          $$ChatCapabilitiesTableUpdateCompanionBuilder,
          (StoredChatCapability, $$ChatCapabilitiesTableReferences),
          StoredChatCapability,
          PrefetchHooks Function({bool accountId})
        > {
  $$ChatCapabilitiesTableTableManager(
    _$AppDatabase db,
    $ChatCapabilitiesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatCapabilitiesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatCapabilitiesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatCapabilitiesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> fingerprint = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<int> credentialGeneration = const Value.absent(),
                Value<String> lane = const Value.absent(),
                Value<int> updatedAtMillis = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChatCapabilitiesCompanion(
                accountId: accountId,
                fingerprint: fingerprint,
                generation: generation,
                credentialGeneration: credentialGeneration,
                lane: lane,
                updatedAtMillis: updatedAtMillis,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String fingerprint,
                Value<int> generation = const Value.absent(),
                Value<int> credentialGeneration = const Value.absent(),
                Value<String> lane = const Value.absent(),
                required int updatedAtMillis,
                Value<int> rowid = const Value.absent(),
              }) => ChatCapabilitiesCompanion.insert(
                accountId: accountId,
                fingerprint: fingerprint,
                generation: generation,
                credentialGeneration: credentialGeneration,
                lane: lane,
                updatedAtMillis: updatedAtMillis,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ChatCapabilitiesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable:
                                    $$ChatCapabilitiesTableReferences
                                        ._accountIdTable(db),
                                referencedColumn:
                                    $$ChatCapabilitiesTableReferences
                                        ._accountIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ChatCapabilitiesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ChatCapabilitiesTable,
      StoredChatCapability,
      $$ChatCapabilitiesTableFilterComposer,
      $$ChatCapabilitiesTableOrderingComposer,
      $$ChatCapabilitiesTableAnnotationComposer,
      $$ChatCapabilitiesTableCreateCompanionBuilder,
      $$ChatCapabilitiesTableUpdateCompanionBuilder,
      (StoredChatCapability, $$ChatCapabilitiesTableReferences),
      StoredChatCapability,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$ChatScopesTableCreateCompanionBuilder =
    ChatScopesCompanion Function({
      required String accountId,
      required String roomToken,
      required String scopeKey,
      Value<int?> threadId,
      required String historyCursor,
      required String futureCursor,
      required String lastCommonRead,
      required int lastReadMessage,
      required int unreadMessages,
      required bool hasHistory,
      required bool futureConverged,
      required String blocksJson,
      Value<int?> lastSyncedAtMillis,
      Value<String?> lastSyncError,
      Value<int> rowid,
    });
typedef $$ChatScopesTableUpdateCompanionBuilder =
    ChatScopesCompanion Function({
      Value<String> accountId,
      Value<String> roomToken,
      Value<String> scopeKey,
      Value<int?> threadId,
      Value<String> historyCursor,
      Value<String> futureCursor,
      Value<String> lastCommonRead,
      Value<int> lastReadMessage,
      Value<int> unreadMessages,
      Value<bool> hasHistory,
      Value<bool> futureConverged,
      Value<String> blocksJson,
      Value<int?> lastSyncedAtMillis,
      Value<String?> lastSyncError,
      Value<int> rowid,
    });

final class $$ChatScopesTableReferences
    extends BaseReferences<_$AppDatabase, $ChatScopesTable, StoredChatScope> {
  $$ChatScopesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $AccountsTable _accountIdTable(_$AppDatabase db) =>
      db.accounts.createAlias('chat_scopes__account_id__accounts__id');

  $$AccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$AccountsTableTableManager(
      $_db,
      $_db.accounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ChatScopesTableFilterComposer
    extends Composer<_$AppDatabase, $ChatScopesTable> {
  $$ChatScopesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get roomToken => $composableBuilder(
    column: $table.roomToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scopeKey => $composableBuilder(
    column: $table.scopeKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get threadId => $composableBuilder(
    column: $table.threadId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get historyCursor => $composableBuilder(
    column: $table.historyCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get futureCursor => $composableBuilder(
    column: $table.futureCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastCommonRead => $composableBuilder(
    column: $table.lastCommonRead,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastReadMessage => $composableBuilder(
    column: $table.lastReadMessage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get unreadMessages => $composableBuilder(
    column: $table.unreadMessages,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hasHistory => $composableBuilder(
    column: $table.hasHistory,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get futureConverged => $composableBuilder(
    column: $table.futureConverged,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get blocksJson => $composableBuilder(
    column: $table.blocksJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSyncedAtMillis => $composableBuilder(
    column: $table.lastSyncedAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastSyncError => $composableBuilder(
    column: $table.lastSyncError,
    builder: (column) => ColumnFilters(column),
  );

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableFilterComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ChatScopesTableOrderingComposer
    extends Composer<_$AppDatabase, $ChatScopesTable> {
  $$ChatScopesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get roomToken => $composableBuilder(
    column: $table.roomToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scopeKey => $composableBuilder(
    column: $table.scopeKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get threadId => $composableBuilder(
    column: $table.threadId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get historyCursor => $composableBuilder(
    column: $table.historyCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get futureCursor => $composableBuilder(
    column: $table.futureCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastCommonRead => $composableBuilder(
    column: $table.lastCommonRead,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastReadMessage => $composableBuilder(
    column: $table.lastReadMessage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get unreadMessages => $composableBuilder(
    column: $table.unreadMessages,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hasHistory => $composableBuilder(
    column: $table.hasHistory,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get futureConverged => $composableBuilder(
    column: $table.futureConverged,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get blocksJson => $composableBuilder(
    column: $table.blocksJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSyncedAtMillis => $composableBuilder(
    column: $table.lastSyncedAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastSyncError => $composableBuilder(
    column: $table.lastSyncError,
    builder: (column) => ColumnOrderings(column),
  );

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableOrderingComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ChatScopesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ChatScopesTable> {
  $$ChatScopesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get roomToken =>
      $composableBuilder(column: $table.roomToken, builder: (column) => column);

  GeneratedColumn<String> get scopeKey =>
      $composableBuilder(column: $table.scopeKey, builder: (column) => column);

  GeneratedColumn<int> get threadId =>
      $composableBuilder(column: $table.threadId, builder: (column) => column);

  GeneratedColumn<String> get historyCursor => $composableBuilder(
    column: $table.historyCursor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get futureCursor => $composableBuilder(
    column: $table.futureCursor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastCommonRead => $composableBuilder(
    column: $table.lastCommonRead,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastReadMessage => $composableBuilder(
    column: $table.lastReadMessage,
    builder: (column) => column,
  );

  GeneratedColumn<int> get unreadMessages => $composableBuilder(
    column: $table.unreadMessages,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get hasHistory => $composableBuilder(
    column: $table.hasHistory,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get futureConverged => $composableBuilder(
    column: $table.futureConverged,
    builder: (column) => column,
  );

  GeneratedColumn<String> get blocksJson => $composableBuilder(
    column: $table.blocksJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastSyncedAtMillis => $composableBuilder(
    column: $table.lastSyncedAtMillis,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastSyncError => $composableBuilder(
    column: $table.lastSyncError,
    builder: (column) => column,
  );

  $$AccountsTableAnnotationComposer get accountId {
    final $$AccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ChatScopesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ChatScopesTable,
          StoredChatScope,
          $$ChatScopesTableFilterComposer,
          $$ChatScopesTableOrderingComposer,
          $$ChatScopesTableAnnotationComposer,
          $$ChatScopesTableCreateCompanionBuilder,
          $$ChatScopesTableUpdateCompanionBuilder,
          (StoredChatScope, $$ChatScopesTableReferences),
          StoredChatScope,
          PrefetchHooks Function({bool accountId})
        > {
  $$ChatScopesTableTableManager(_$AppDatabase db, $ChatScopesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatScopesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatScopesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatScopesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> roomToken = const Value.absent(),
                Value<String> scopeKey = const Value.absent(),
                Value<int?> threadId = const Value.absent(),
                Value<String> historyCursor = const Value.absent(),
                Value<String> futureCursor = const Value.absent(),
                Value<String> lastCommonRead = const Value.absent(),
                Value<int> lastReadMessage = const Value.absent(),
                Value<int> unreadMessages = const Value.absent(),
                Value<bool> hasHistory = const Value.absent(),
                Value<bool> futureConverged = const Value.absent(),
                Value<String> blocksJson = const Value.absent(),
                Value<int?> lastSyncedAtMillis = const Value.absent(),
                Value<String?> lastSyncError = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChatScopesCompanion(
                accountId: accountId,
                roomToken: roomToken,
                scopeKey: scopeKey,
                threadId: threadId,
                historyCursor: historyCursor,
                futureCursor: futureCursor,
                lastCommonRead: lastCommonRead,
                lastReadMessage: lastReadMessage,
                unreadMessages: unreadMessages,
                hasHistory: hasHistory,
                futureConverged: futureConverged,
                blocksJson: blocksJson,
                lastSyncedAtMillis: lastSyncedAtMillis,
                lastSyncError: lastSyncError,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String roomToken,
                required String scopeKey,
                Value<int?> threadId = const Value.absent(),
                required String historyCursor,
                required String futureCursor,
                required String lastCommonRead,
                required int lastReadMessage,
                required int unreadMessages,
                required bool hasHistory,
                required bool futureConverged,
                required String blocksJson,
                Value<int?> lastSyncedAtMillis = const Value.absent(),
                Value<String?> lastSyncError = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChatScopesCompanion.insert(
                accountId: accountId,
                roomToken: roomToken,
                scopeKey: scopeKey,
                threadId: threadId,
                historyCursor: historyCursor,
                futureCursor: futureCursor,
                lastCommonRead: lastCommonRead,
                lastReadMessage: lastReadMessage,
                unreadMessages: unreadMessages,
                hasHistory: hasHistory,
                futureConverged: futureConverged,
                blocksJson: blocksJson,
                lastSyncedAtMillis: lastSyncedAtMillis,
                lastSyncError: lastSyncError,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ChatScopesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable: $$ChatScopesTableReferences
                                    ._accountIdTable(db),
                                referencedColumn: $$ChatScopesTableReferences
                                    ._accountIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ChatScopesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ChatScopesTable,
      StoredChatScope,
      $$ChatScopesTableFilterComposer,
      $$ChatScopesTableOrderingComposer,
      $$ChatScopesTableAnnotationComposer,
      $$ChatScopesTableCreateCompanionBuilder,
      $$ChatScopesTableUpdateCompanionBuilder,
      (StoredChatScope, $$ChatScopesTableReferences),
      StoredChatScope,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$CachedChatMessagesTableCreateCompanionBuilder =
    CachedChatMessagesCompanion Function({
      required String accountId,
      required String roomToken,
      required int messageId,
      required String actorType,
      required String actorId,
      required String actorDisplayName,
      required int timestamp,
      required String systemMessage,
      required String messageType,
      required String referenceId,
      required String displayText,
      required bool deleted,
      Value<int?> threadId,
      required String rawJson,
      Value<int> rowid,
    });
typedef $$CachedChatMessagesTableUpdateCompanionBuilder =
    CachedChatMessagesCompanion Function({
      Value<String> accountId,
      Value<String> roomToken,
      Value<int> messageId,
      Value<String> actorType,
      Value<String> actorId,
      Value<String> actorDisplayName,
      Value<int> timestamp,
      Value<String> systemMessage,
      Value<String> messageType,
      Value<String> referenceId,
      Value<String> displayText,
      Value<bool> deleted,
      Value<int?> threadId,
      Value<String> rawJson,
      Value<int> rowid,
    });

final class $$CachedChatMessagesTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $CachedChatMessagesTable,
          CachedChatMessage
        > {
  $$CachedChatMessagesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $AccountsTable _accountIdTable(_$AppDatabase db) =>
      db.accounts.createAlias('cached_chat_messages__account_id__accounts__id');

  $$AccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$AccountsTableTableManager(
      $_db,
      $_db.accounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CachedChatMessagesTableFilterComposer
    extends Composer<_$AppDatabase, $CachedChatMessagesTable> {
  $$CachedChatMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get roomToken => $composableBuilder(
    column: $table.roomToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get actorType => $composableBuilder(
    column: $table.actorType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get actorId => $composableBuilder(
    column: $table.actorId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get actorDisplayName => $composableBuilder(
    column: $table.actorDisplayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get systemMessage => $composableBuilder(
    column: $table.systemMessage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageType => $composableBuilder(
    column: $table.messageType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get referenceId => $composableBuilder(
    column: $table.referenceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayText => $composableBuilder(
    column: $table.displayText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get threadId => $composableBuilder(
    column: $table.threadId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rawJson => $composableBuilder(
    column: $table.rawJson,
    builder: (column) => ColumnFilters(column),
  );

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableFilterComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedChatMessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $CachedChatMessagesTable> {
  $$CachedChatMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get roomToken => $composableBuilder(
    column: $table.roomToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get actorType => $composableBuilder(
    column: $table.actorType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get actorId => $composableBuilder(
    column: $table.actorId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get actorDisplayName => $composableBuilder(
    column: $table.actorDisplayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get systemMessage => $composableBuilder(
    column: $table.systemMessage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageType => $composableBuilder(
    column: $table.messageType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get referenceId => $composableBuilder(
    column: $table.referenceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayText => $composableBuilder(
    column: $table.displayText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get threadId => $composableBuilder(
    column: $table.threadId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rawJson => $composableBuilder(
    column: $table.rawJson,
    builder: (column) => ColumnOrderings(column),
  );

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableOrderingComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedChatMessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CachedChatMessagesTable> {
  $$CachedChatMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get roomToken =>
      $composableBuilder(column: $table.roomToken, builder: (column) => column);

  GeneratedColumn<int> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<String> get actorType =>
      $composableBuilder(column: $table.actorType, builder: (column) => column);

  GeneratedColumn<String> get actorId =>
      $composableBuilder(column: $table.actorId, builder: (column) => column);

  GeneratedColumn<String> get actorDisplayName => $composableBuilder(
    column: $table.actorDisplayName,
    builder: (column) => column,
  );

  GeneratedColumn<int> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<String> get systemMessage => $composableBuilder(
    column: $table.systemMessage,
    builder: (column) => column,
  );

  GeneratedColumn<String> get messageType => $composableBuilder(
    column: $table.messageType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get referenceId => $composableBuilder(
    column: $table.referenceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get displayText => $composableBuilder(
    column: $table.displayText,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);

  GeneratedColumn<int> get threadId =>
      $composableBuilder(column: $table.threadId, builder: (column) => column);

  GeneratedColumn<String> get rawJson =>
      $composableBuilder(column: $table.rawJson, builder: (column) => column);

  $$AccountsTableAnnotationComposer get accountId {
    final $$AccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedChatMessagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CachedChatMessagesTable,
          CachedChatMessage,
          $$CachedChatMessagesTableFilterComposer,
          $$CachedChatMessagesTableOrderingComposer,
          $$CachedChatMessagesTableAnnotationComposer,
          $$CachedChatMessagesTableCreateCompanionBuilder,
          $$CachedChatMessagesTableUpdateCompanionBuilder,
          (CachedChatMessage, $$CachedChatMessagesTableReferences),
          CachedChatMessage,
          PrefetchHooks Function({bool accountId})
        > {
  $$CachedChatMessagesTableTableManager(
    _$AppDatabase db,
    $CachedChatMessagesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedChatMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedChatMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedChatMessagesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> roomToken = const Value.absent(),
                Value<int> messageId = const Value.absent(),
                Value<String> actorType = const Value.absent(),
                Value<String> actorId = const Value.absent(),
                Value<String> actorDisplayName = const Value.absent(),
                Value<int> timestamp = const Value.absent(),
                Value<String> systemMessage = const Value.absent(),
                Value<String> messageType = const Value.absent(),
                Value<String> referenceId = const Value.absent(),
                Value<String> displayText = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<int?> threadId = const Value.absent(),
                Value<String> rawJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedChatMessagesCompanion(
                accountId: accountId,
                roomToken: roomToken,
                messageId: messageId,
                actorType: actorType,
                actorId: actorId,
                actorDisplayName: actorDisplayName,
                timestamp: timestamp,
                systemMessage: systemMessage,
                messageType: messageType,
                referenceId: referenceId,
                displayText: displayText,
                deleted: deleted,
                threadId: threadId,
                rawJson: rawJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String roomToken,
                required int messageId,
                required String actorType,
                required String actorId,
                required String actorDisplayName,
                required int timestamp,
                required String systemMessage,
                required String messageType,
                required String referenceId,
                required String displayText,
                required bool deleted,
                Value<int?> threadId = const Value.absent(),
                required String rawJson,
                Value<int> rowid = const Value.absent(),
              }) => CachedChatMessagesCompanion.insert(
                accountId: accountId,
                roomToken: roomToken,
                messageId: messageId,
                actorType: actorType,
                actorId: actorId,
                actorDisplayName: actorDisplayName,
                timestamp: timestamp,
                systemMessage: systemMessage,
                messageType: messageType,
                referenceId: referenceId,
                displayText: displayText,
                deleted: deleted,
                threadId: threadId,
                rawJson: rawJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CachedChatMessagesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable:
                                    $$CachedChatMessagesTableReferences
                                        ._accountIdTable(db),
                                referencedColumn:
                                    $$CachedChatMessagesTableReferences
                                        ._accountIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CachedChatMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CachedChatMessagesTable,
      CachedChatMessage,
      $$CachedChatMessagesTableFilterComposer,
      $$CachedChatMessagesTableOrderingComposer,
      $$CachedChatMessagesTableAnnotationComposer,
      $$CachedChatMessagesTableCreateCompanionBuilder,
      $$CachedChatMessagesTableUpdateCompanionBuilder,
      (CachedChatMessage, $$CachedChatMessagesTableReferences),
      CachedChatMessage,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$TextSendOperationsTableCreateCompanionBuilder =
    TextSendOperationsCompanion Function({
      required String accountId,
      required String operationId,
      required String roomToken,
      required String referenceId,
      required String message,
      required String replayContractRevision,
      required int enqueueSequence,
      required String outboxState,
      required int attemptCount,
      required String messageIdsJson,
      required bool duplicateRiskAcknowledged,
      Value<String?> errorClass,
      Value<int?> nextAttemptAt,
      Value<int?> replyTo,
      Value<int?> threadId,
      Value<String?> replyToToken,
      Value<String?> parentRoomToken,
      required int createdAtMillis,
      required int updatedAtMillis,
      Value<int> rowid,
    });
typedef $$TextSendOperationsTableUpdateCompanionBuilder =
    TextSendOperationsCompanion Function({
      Value<String> accountId,
      Value<String> operationId,
      Value<String> roomToken,
      Value<String> referenceId,
      Value<String> message,
      Value<String> replayContractRevision,
      Value<int> enqueueSequence,
      Value<String> outboxState,
      Value<int> attemptCount,
      Value<String> messageIdsJson,
      Value<bool> duplicateRiskAcknowledged,
      Value<String?> errorClass,
      Value<int?> nextAttemptAt,
      Value<int?> replyTo,
      Value<int?> threadId,
      Value<String?> replyToToken,
      Value<String?> parentRoomToken,
      Value<int> createdAtMillis,
      Value<int> updatedAtMillis,
      Value<int> rowid,
    });

final class $$TextSendOperationsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $TextSendOperationsTable,
          StoredTextSendOperation
        > {
  $$TextSendOperationsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $AccountsTable _accountIdTable(_$AppDatabase db) =>
      db.accounts.createAlias('text_send_operations__account_id__accounts__id');

  $$AccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$AccountsTableTableManager(
      $_db,
      $_db.accounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$TextSendOperationsTableFilterComposer
    extends Composer<_$AppDatabase, $TextSendOperationsTable> {
  $$TextSendOperationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roomToken => $composableBuilder(
    column: $table.roomToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get referenceId => $composableBuilder(
    column: $table.referenceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get message => $composableBuilder(
    column: $table.message,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replayContractRevision => $composableBuilder(
    column: $table.replayContractRevision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get enqueueSequence => $composableBuilder(
    column: $table.enqueueSequence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get outboxState => $composableBuilder(
    column: $table.outboxState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageIdsJson => $composableBuilder(
    column: $table.messageIdsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get duplicateRiskAcknowledged => $composableBuilder(
    column: $table.duplicateRiskAcknowledged,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorClass => $composableBuilder(
    column: $table.errorClass,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get replyTo => $composableBuilder(
    column: $table.replyTo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get threadId => $composableBuilder(
    column: $table.threadId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replyToToken => $composableBuilder(
    column: $table.replyToToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentRoomToken => $composableBuilder(
    column: $table.parentRoomToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtMillis => $composableBuilder(
    column: $table.createdAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableFilterComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TextSendOperationsTableOrderingComposer
    extends Composer<_$AppDatabase, $TextSendOperationsTable> {
  $$TextSendOperationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roomToken => $composableBuilder(
    column: $table.roomToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get referenceId => $composableBuilder(
    column: $table.referenceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get message => $composableBuilder(
    column: $table.message,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replayContractRevision => $composableBuilder(
    column: $table.replayContractRevision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get enqueueSequence => $composableBuilder(
    column: $table.enqueueSequence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get outboxState => $composableBuilder(
    column: $table.outboxState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageIdsJson => $composableBuilder(
    column: $table.messageIdsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get duplicateRiskAcknowledged => $composableBuilder(
    column: $table.duplicateRiskAcknowledged,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorClass => $composableBuilder(
    column: $table.errorClass,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get replyTo => $composableBuilder(
    column: $table.replyTo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get threadId => $composableBuilder(
    column: $table.threadId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replyToToken => $composableBuilder(
    column: $table.replyToToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentRoomToken => $composableBuilder(
    column: $table.parentRoomToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtMillis => $composableBuilder(
    column: $table.createdAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableOrderingComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TextSendOperationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TextSendOperationsTable> {
  $$TextSendOperationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get roomToken =>
      $composableBuilder(column: $table.roomToken, builder: (column) => column);

  GeneratedColumn<String> get referenceId => $composableBuilder(
    column: $table.referenceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get message =>
      $composableBuilder(column: $table.message, builder: (column) => column);

  GeneratedColumn<String> get replayContractRevision => $composableBuilder(
    column: $table.replayContractRevision,
    builder: (column) => column,
  );

  GeneratedColumn<int> get enqueueSequence => $composableBuilder(
    column: $table.enqueueSequence,
    builder: (column) => column,
  );

  GeneratedColumn<String> get outboxState => $composableBuilder(
    column: $table.outboxState,
    builder: (column) => column,
  );

  GeneratedColumn<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get messageIdsJson => $composableBuilder(
    column: $table.messageIdsJson,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get duplicateRiskAcknowledged => $composableBuilder(
    column: $table.duplicateRiskAcknowledged,
    builder: (column) => column,
  );

  GeneratedColumn<String> get errorClass => $composableBuilder(
    column: $table.errorClass,
    builder: (column) => column,
  );

  GeneratedColumn<int> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get replyTo =>
      $composableBuilder(column: $table.replyTo, builder: (column) => column);

  GeneratedColumn<int> get threadId =>
      $composableBuilder(column: $table.threadId, builder: (column) => column);

  GeneratedColumn<String> get replyToToken => $composableBuilder(
    column: $table.replyToToken,
    builder: (column) => column,
  );

  GeneratedColumn<String> get parentRoomToken => $composableBuilder(
    column: $table.parentRoomToken,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAtMillis => $composableBuilder(
    column: $table.createdAtMillis,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => column,
  );

  $$AccountsTableAnnotationComposer get accountId {
    final $$AccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TextSendOperationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TextSendOperationsTable,
          StoredTextSendOperation,
          $$TextSendOperationsTableFilterComposer,
          $$TextSendOperationsTableOrderingComposer,
          $$TextSendOperationsTableAnnotationComposer,
          $$TextSendOperationsTableCreateCompanionBuilder,
          $$TextSendOperationsTableUpdateCompanionBuilder,
          (StoredTextSendOperation, $$TextSendOperationsTableReferences),
          StoredTextSendOperation,
          PrefetchHooks Function({bool accountId})
        > {
  $$TextSendOperationsTableTableManager(
    _$AppDatabase db,
    $TextSendOperationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TextSendOperationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TextSendOperationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TextSendOperationsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> operationId = const Value.absent(),
                Value<String> roomToken = const Value.absent(),
                Value<String> referenceId = const Value.absent(),
                Value<String> message = const Value.absent(),
                Value<String> replayContractRevision = const Value.absent(),
                Value<int> enqueueSequence = const Value.absent(),
                Value<String> outboxState = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<String> messageIdsJson = const Value.absent(),
                Value<bool> duplicateRiskAcknowledged = const Value.absent(),
                Value<String?> errorClass = const Value.absent(),
                Value<int?> nextAttemptAt = const Value.absent(),
                Value<int?> replyTo = const Value.absent(),
                Value<int?> threadId = const Value.absent(),
                Value<String?> replyToToken = const Value.absent(),
                Value<String?> parentRoomToken = const Value.absent(),
                Value<int> createdAtMillis = const Value.absent(),
                Value<int> updatedAtMillis = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TextSendOperationsCompanion(
                accountId: accountId,
                operationId: operationId,
                roomToken: roomToken,
                referenceId: referenceId,
                message: message,
                replayContractRevision: replayContractRevision,
                enqueueSequence: enqueueSequence,
                outboxState: outboxState,
                attemptCount: attemptCount,
                messageIdsJson: messageIdsJson,
                duplicateRiskAcknowledged: duplicateRiskAcknowledged,
                errorClass: errorClass,
                nextAttemptAt: nextAttemptAt,
                replyTo: replyTo,
                threadId: threadId,
                replyToToken: replyToToken,
                parentRoomToken: parentRoomToken,
                createdAtMillis: createdAtMillis,
                updatedAtMillis: updatedAtMillis,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String operationId,
                required String roomToken,
                required String referenceId,
                required String message,
                required String replayContractRevision,
                required int enqueueSequence,
                required String outboxState,
                required int attemptCount,
                required String messageIdsJson,
                required bool duplicateRiskAcknowledged,
                Value<String?> errorClass = const Value.absent(),
                Value<int?> nextAttemptAt = const Value.absent(),
                Value<int?> replyTo = const Value.absent(),
                Value<int?> threadId = const Value.absent(),
                Value<String?> replyToToken = const Value.absent(),
                Value<String?> parentRoomToken = const Value.absent(),
                required int createdAtMillis,
                required int updatedAtMillis,
                Value<int> rowid = const Value.absent(),
              }) => TextSendOperationsCompanion.insert(
                accountId: accountId,
                operationId: operationId,
                roomToken: roomToken,
                referenceId: referenceId,
                message: message,
                replayContractRevision: replayContractRevision,
                enqueueSequence: enqueueSequence,
                outboxState: outboxState,
                attemptCount: attemptCount,
                messageIdsJson: messageIdsJson,
                duplicateRiskAcknowledged: duplicateRiskAcknowledged,
                errorClass: errorClass,
                nextAttemptAt: nextAttemptAt,
                replyTo: replyTo,
                threadId: threadId,
                replyToToken: replyToToken,
                parentRoomToken: parentRoomToken,
                createdAtMillis: createdAtMillis,
                updatedAtMillis: updatedAtMillis,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$TextSendOperationsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable:
                                    $$TextSendOperationsTableReferences
                                        ._accountIdTable(db),
                                referencedColumn:
                                    $$TextSendOperationsTableReferences
                                        ._accountIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$TextSendOperationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TextSendOperationsTable,
      StoredTextSendOperation,
      $$TextSendOperationsTableFilterComposer,
      $$TextSendOperationsTableOrderingComposer,
      $$TextSendOperationsTableAnnotationComposer,
      $$TextSendOperationsTableCreateCompanionBuilder,
      $$TextSendOperationsTableUpdateCompanionBuilder,
      (StoredTextSendOperation, $$TextSendOperationsTableReferences),
      StoredTextSendOperation,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$ChatDraftsTableCreateCompanionBuilder =
    ChatDraftsCompanion Function({
      required String accountId,
      required String roomToken,
      required String scopeKey,
      required String draftText,
      required int updatedAtMillis,
      Value<int> rowid,
    });
typedef $$ChatDraftsTableUpdateCompanionBuilder =
    ChatDraftsCompanion Function({
      Value<String> accountId,
      Value<String> roomToken,
      Value<String> scopeKey,
      Value<String> draftText,
      Value<int> updatedAtMillis,
      Value<int> rowid,
    });

final class $$ChatDraftsTableReferences
    extends BaseReferences<_$AppDatabase, $ChatDraftsTable, StoredChatDraft> {
  $$ChatDraftsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $AccountsTable _accountIdTable(_$AppDatabase db) =>
      db.accounts.createAlias('chat_drafts__account_id__accounts__id');

  $$AccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$AccountsTableTableManager(
      $_db,
      $_db.accounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ChatDraftsTableFilterComposer
    extends Composer<_$AppDatabase, $ChatDraftsTable> {
  $$ChatDraftsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get roomToken => $composableBuilder(
    column: $table.roomToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scopeKey => $composableBuilder(
    column: $table.scopeKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get draftText => $composableBuilder(
    column: $table.draftText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableFilterComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ChatDraftsTableOrderingComposer
    extends Composer<_$AppDatabase, $ChatDraftsTable> {
  $$ChatDraftsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get roomToken => $composableBuilder(
    column: $table.roomToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scopeKey => $composableBuilder(
    column: $table.scopeKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get draftText => $composableBuilder(
    column: $table.draftText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableOrderingComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ChatDraftsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ChatDraftsTable> {
  $$ChatDraftsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get roomToken =>
      $composableBuilder(column: $table.roomToken, builder: (column) => column);

  GeneratedColumn<String> get scopeKey =>
      $composableBuilder(column: $table.scopeKey, builder: (column) => column);

  GeneratedColumn<String> get draftText =>
      $composableBuilder(column: $table.draftText, builder: (column) => column);

  GeneratedColumn<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => column,
  );

  $$AccountsTableAnnotationComposer get accountId {
    final $$AccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ChatDraftsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ChatDraftsTable,
          StoredChatDraft,
          $$ChatDraftsTableFilterComposer,
          $$ChatDraftsTableOrderingComposer,
          $$ChatDraftsTableAnnotationComposer,
          $$ChatDraftsTableCreateCompanionBuilder,
          $$ChatDraftsTableUpdateCompanionBuilder,
          (StoredChatDraft, $$ChatDraftsTableReferences),
          StoredChatDraft,
          PrefetchHooks Function({bool accountId})
        > {
  $$ChatDraftsTableTableManager(_$AppDatabase db, $ChatDraftsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatDraftsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatDraftsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatDraftsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> roomToken = const Value.absent(),
                Value<String> scopeKey = const Value.absent(),
                Value<String> draftText = const Value.absent(),
                Value<int> updatedAtMillis = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChatDraftsCompanion(
                accountId: accountId,
                roomToken: roomToken,
                scopeKey: scopeKey,
                draftText: draftText,
                updatedAtMillis: updatedAtMillis,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String roomToken,
                required String scopeKey,
                required String draftText,
                required int updatedAtMillis,
                Value<int> rowid = const Value.absent(),
              }) => ChatDraftsCompanion.insert(
                accountId: accountId,
                roomToken: roomToken,
                scopeKey: scopeKey,
                draftText: draftText,
                updatedAtMillis: updatedAtMillis,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ChatDraftsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable: $$ChatDraftsTableReferences
                                    ._accountIdTable(db),
                                referencedColumn: $$ChatDraftsTableReferences
                                    ._accountIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ChatDraftsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ChatDraftsTable,
      StoredChatDraft,
      $$ChatDraftsTableFilterComposer,
      $$ChatDraftsTableOrderingComposer,
      $$ChatDraftsTableAnnotationComposer,
      $$ChatDraftsTableCreateCompanionBuilder,
      $$ChatDraftsTableUpdateCompanionBuilder,
      (StoredChatDraft, $$ChatDraftsTableReferences),
      StoredChatDraft,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$AttachmentRuntimeAccountsTableCreateCompanionBuilder =
    AttachmentRuntimeAccountsCompanion Function({
      required String accountId,
      required String serverUrl,
      required String lane,
      required int credentialGeneration,
      required int capabilityGeneration,
      required int updatedAtMillis,
      Value<int> rowid,
    });
typedef $$AttachmentRuntimeAccountsTableUpdateCompanionBuilder =
    AttachmentRuntimeAccountsCompanion Function({
      Value<String> accountId,
      Value<String> serverUrl,
      Value<String> lane,
      Value<int> credentialGeneration,
      Value<int> capabilityGeneration,
      Value<int> updatedAtMillis,
      Value<int> rowid,
    });

final class $$AttachmentRuntimeAccountsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $AttachmentRuntimeAccountsTable,
          StoredAttachmentRuntimeAccount
        > {
  $$AttachmentRuntimeAccountsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $AccountsTable _accountIdTable(_$AppDatabase db) => db.accounts
      .createAlias('attachment_runtime_accounts__account_id__accounts__id');

  $$AccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<String>('account_id')!;

    final manager = $$AccountsTableTableManager(
      $_db,
      $_db.accounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$AttachmentRuntimeAccountsTableFilterComposer
    extends Composer<_$AppDatabase, $AttachmentRuntimeAccountsTable> {
  $$AttachmentRuntimeAccountsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get serverUrl => $composableBuilder(
    column: $table.serverUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lane => $composableBuilder(
    column: $table.lane,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get credentialGeneration => $composableBuilder(
    column: $table.credentialGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get capabilityGeneration => $composableBuilder(
    column: $table.capabilityGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableFilterComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AttachmentRuntimeAccountsTableOrderingComposer
    extends Composer<_$AppDatabase, $AttachmentRuntimeAccountsTable> {
  $$AttachmentRuntimeAccountsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get serverUrl => $composableBuilder(
    column: $table.serverUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lane => $composableBuilder(
    column: $table.lane,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get credentialGeneration => $composableBuilder(
    column: $table.credentialGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get capabilityGeneration => $composableBuilder(
    column: $table.capabilityGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableOrderingComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AttachmentRuntimeAccountsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AttachmentRuntimeAccountsTable> {
  $$AttachmentRuntimeAccountsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get serverUrl =>
      $composableBuilder(column: $table.serverUrl, builder: (column) => column);

  GeneratedColumn<String> get lane =>
      $composableBuilder(column: $table.lane, builder: (column) => column);

  GeneratedColumn<int> get credentialGeneration => $composableBuilder(
    column: $table.credentialGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<int> get capabilityGeneration => $composableBuilder(
    column: $table.capabilityGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => column,
  );

  $$AccountsTableAnnotationComposer get accountId {
    final $$AccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AttachmentRuntimeAccountsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AttachmentRuntimeAccountsTable,
          StoredAttachmentRuntimeAccount,
          $$AttachmentRuntimeAccountsTableFilterComposer,
          $$AttachmentRuntimeAccountsTableOrderingComposer,
          $$AttachmentRuntimeAccountsTableAnnotationComposer,
          $$AttachmentRuntimeAccountsTableCreateCompanionBuilder,
          $$AttachmentRuntimeAccountsTableUpdateCompanionBuilder,
          (
            StoredAttachmentRuntimeAccount,
            $$AttachmentRuntimeAccountsTableReferences,
          ),
          StoredAttachmentRuntimeAccount,
          PrefetchHooks Function({bool accountId})
        > {
  $$AttachmentRuntimeAccountsTableTableManager(
    _$AppDatabase db,
    $AttachmentRuntimeAccountsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AttachmentRuntimeAccountsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$AttachmentRuntimeAccountsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$AttachmentRuntimeAccountsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> serverUrl = const Value.absent(),
                Value<String> lane = const Value.absent(),
                Value<int> credentialGeneration = const Value.absent(),
                Value<int> capabilityGeneration = const Value.absent(),
                Value<int> updatedAtMillis = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AttachmentRuntimeAccountsCompanion(
                accountId: accountId,
                serverUrl: serverUrl,
                lane: lane,
                credentialGeneration: credentialGeneration,
                capabilityGeneration: capabilityGeneration,
                updatedAtMillis: updatedAtMillis,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String serverUrl,
                required String lane,
                required int credentialGeneration,
                required int capabilityGeneration,
                required int updatedAtMillis,
                Value<int> rowid = const Value.absent(),
              }) => AttachmentRuntimeAccountsCompanion.insert(
                accountId: accountId,
                serverUrl: serverUrl,
                lane: lane,
                credentialGeneration: credentialGeneration,
                capabilityGeneration: capabilityGeneration,
                updatedAtMillis: updatedAtMillis,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$AttachmentRuntimeAccountsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable:
                                    $$AttachmentRuntimeAccountsTableReferences
                                        ._accountIdTable(db),
                                referencedColumn:
                                    $$AttachmentRuntimeAccountsTableReferences
                                        ._accountIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$AttachmentRuntimeAccountsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AttachmentRuntimeAccountsTable,
      StoredAttachmentRuntimeAccount,
      $$AttachmentRuntimeAccountsTableFilterComposer,
      $$AttachmentRuntimeAccountsTableOrderingComposer,
      $$AttachmentRuntimeAccountsTableAnnotationComposer,
      $$AttachmentRuntimeAccountsTableCreateCompanionBuilder,
      $$AttachmentRuntimeAccountsTableUpdateCompanionBuilder,
      (
        StoredAttachmentRuntimeAccount,
        $$AttachmentRuntimeAccountsTableReferences,
      ),
      StoredAttachmentRuntimeAccount,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$AttachmentJobsTableCreateCompanionBuilder =
    AttachmentJobsCompanion Function({
      required String accountId,
      required String jobId,
      required String serverUrl,
      required int capabilityGeneration,
      required String replayContractRevision,
      required String davUserId,
      required String roomToken,
      required String referenceId,
      required String sourceHandle,
      required String sourceOwnership,
      required int sourceByteLength,
      required String sourceSha256,
      required String sourceMimeType,
      required String sourceDisplayName,
      required String messageKind,
      Value<String?> caption,
      Value<int?> replyTo,
      Value<int?> threadId,
      Value<String?> threadTitle,
      required bool silent,
      required int enqueueSequence,
      required int normalUploadMaximumBytes,
      required int chunkSizeBytes,
      Value<String?> uploadSessionId,
      required String phase,
      Value<String?> resumePhase,
      Value<String?> remoteDraftFolder,
      Value<String?> remoteTemporaryPath,
      required bool chunkCollectionReady,
      required bool chunkManifestLoaded,
      required String verifiedChunksJson,
      Value<String?> inFlightStep,
      Value<String?> inFlightRequestId,
      required int attemptCount,
      required bool finalizationDispatched,
      required bool cleanupChunkSession,
      required bool cleanupDraftFile,
      required String messageIdsJson,
      Value<String?> errorClass,
      required bool profileFederated,
      required bool profileEnabled,
      required bool profileCaption,
      required bool profileVoice,
      required bool profileReply,
      required bool profileThreads,
      required bool profileSilent,
      required bool roomCanWrite,
      Value<int> automaticRetryCount,
      Value<int?> nextAttemptAtMillis,
      Value<bool> sourceReleased,
      Value<String?> localCleanupError,
      required int createdAtMillis,
      required int updatedAtMillis,
      Value<int> rowid,
    });
typedef $$AttachmentJobsTableUpdateCompanionBuilder =
    AttachmentJobsCompanion Function({
      Value<String> accountId,
      Value<String> jobId,
      Value<String> serverUrl,
      Value<int> capabilityGeneration,
      Value<String> replayContractRevision,
      Value<String> davUserId,
      Value<String> roomToken,
      Value<String> referenceId,
      Value<String> sourceHandle,
      Value<String> sourceOwnership,
      Value<int> sourceByteLength,
      Value<String> sourceSha256,
      Value<String> sourceMimeType,
      Value<String> sourceDisplayName,
      Value<String> messageKind,
      Value<String?> caption,
      Value<int?> replyTo,
      Value<int?> threadId,
      Value<String?> threadTitle,
      Value<bool> silent,
      Value<int> enqueueSequence,
      Value<int> normalUploadMaximumBytes,
      Value<int> chunkSizeBytes,
      Value<String?> uploadSessionId,
      Value<String> phase,
      Value<String?> resumePhase,
      Value<String?> remoteDraftFolder,
      Value<String?> remoteTemporaryPath,
      Value<bool> chunkCollectionReady,
      Value<bool> chunkManifestLoaded,
      Value<String> verifiedChunksJson,
      Value<String?> inFlightStep,
      Value<String?> inFlightRequestId,
      Value<int> attemptCount,
      Value<bool> finalizationDispatched,
      Value<bool> cleanupChunkSession,
      Value<bool> cleanupDraftFile,
      Value<String> messageIdsJson,
      Value<String?> errorClass,
      Value<bool> profileFederated,
      Value<bool> profileEnabled,
      Value<bool> profileCaption,
      Value<bool> profileVoice,
      Value<bool> profileReply,
      Value<bool> profileThreads,
      Value<bool> profileSilent,
      Value<bool> roomCanWrite,
      Value<int> automaticRetryCount,
      Value<int?> nextAttemptAtMillis,
      Value<bool> sourceReleased,
      Value<String?> localCleanupError,
      Value<int> createdAtMillis,
      Value<int> updatedAtMillis,
      Value<int> rowid,
    });

class $$AttachmentJobsTableFilterComposer
    extends Composer<_$AppDatabase, $AttachmentJobsTable> {
  $$AttachmentJobsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get jobId => $composableBuilder(
    column: $table.jobId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverUrl => $composableBuilder(
    column: $table.serverUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get capabilityGeneration => $composableBuilder(
    column: $table.capabilityGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replayContractRevision => $composableBuilder(
    column: $table.replayContractRevision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get davUserId => $composableBuilder(
    column: $table.davUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roomToken => $composableBuilder(
    column: $table.roomToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get referenceId => $composableBuilder(
    column: $table.referenceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceHandle => $composableBuilder(
    column: $table.sourceHandle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceOwnership => $composableBuilder(
    column: $table.sourceOwnership,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sourceByteLength => $composableBuilder(
    column: $table.sourceByteLength,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceSha256 => $composableBuilder(
    column: $table.sourceSha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceMimeType => $composableBuilder(
    column: $table.sourceMimeType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceDisplayName => $composableBuilder(
    column: $table.sourceDisplayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageKind => $composableBuilder(
    column: $table.messageKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get caption => $composableBuilder(
    column: $table.caption,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get replyTo => $composableBuilder(
    column: $table.replyTo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get threadId => $composableBuilder(
    column: $table.threadId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get threadTitle => $composableBuilder(
    column: $table.threadTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get silent => $composableBuilder(
    column: $table.silent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get enqueueSequence => $composableBuilder(
    column: $table.enqueueSequence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get normalUploadMaximumBytes => $composableBuilder(
    column: $table.normalUploadMaximumBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get chunkSizeBytes => $composableBuilder(
    column: $table.chunkSizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get uploadSessionId => $composableBuilder(
    column: $table.uploadSessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get phase => $composableBuilder(
    column: $table.phase,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resumePhase => $composableBuilder(
    column: $table.resumePhase,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteDraftFolder => $composableBuilder(
    column: $table.remoteDraftFolder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteTemporaryPath => $composableBuilder(
    column: $table.remoteTemporaryPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get chunkCollectionReady => $composableBuilder(
    column: $table.chunkCollectionReady,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get chunkManifestLoaded => $composableBuilder(
    column: $table.chunkManifestLoaded,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get verifiedChunksJson => $composableBuilder(
    column: $table.verifiedChunksJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get inFlightStep => $composableBuilder(
    column: $table.inFlightStep,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get inFlightRequestId => $composableBuilder(
    column: $table.inFlightRequestId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get finalizationDispatched => $composableBuilder(
    column: $table.finalizationDispatched,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get cleanupChunkSession => $composableBuilder(
    column: $table.cleanupChunkSession,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get cleanupDraftFile => $composableBuilder(
    column: $table.cleanupDraftFile,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageIdsJson => $composableBuilder(
    column: $table.messageIdsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorClass => $composableBuilder(
    column: $table.errorClass,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get profileFederated => $composableBuilder(
    column: $table.profileFederated,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get profileEnabled => $composableBuilder(
    column: $table.profileEnabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get profileCaption => $composableBuilder(
    column: $table.profileCaption,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get profileVoice => $composableBuilder(
    column: $table.profileVoice,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get profileReply => $composableBuilder(
    column: $table.profileReply,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get profileThreads => $composableBuilder(
    column: $table.profileThreads,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get profileSilent => $composableBuilder(
    column: $table.profileSilent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get roomCanWrite => $composableBuilder(
    column: $table.roomCanWrite,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get automaticRetryCount => $composableBuilder(
    column: $table.automaticRetryCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextAttemptAtMillis => $composableBuilder(
    column: $table.nextAttemptAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get sourceReleased => $composableBuilder(
    column: $table.sourceReleased,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localCleanupError => $composableBuilder(
    column: $table.localCleanupError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtMillis => $composableBuilder(
    column: $table.createdAtMillis,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AttachmentJobsTableOrderingComposer
    extends Composer<_$AppDatabase, $AttachmentJobsTable> {
  $$AttachmentJobsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get jobId => $composableBuilder(
    column: $table.jobId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverUrl => $composableBuilder(
    column: $table.serverUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get capabilityGeneration => $composableBuilder(
    column: $table.capabilityGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replayContractRevision => $composableBuilder(
    column: $table.replayContractRevision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get davUserId => $composableBuilder(
    column: $table.davUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roomToken => $composableBuilder(
    column: $table.roomToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get referenceId => $composableBuilder(
    column: $table.referenceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceHandle => $composableBuilder(
    column: $table.sourceHandle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceOwnership => $composableBuilder(
    column: $table.sourceOwnership,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sourceByteLength => $composableBuilder(
    column: $table.sourceByteLength,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceSha256 => $composableBuilder(
    column: $table.sourceSha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceMimeType => $composableBuilder(
    column: $table.sourceMimeType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceDisplayName => $composableBuilder(
    column: $table.sourceDisplayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageKind => $composableBuilder(
    column: $table.messageKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get caption => $composableBuilder(
    column: $table.caption,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get replyTo => $composableBuilder(
    column: $table.replyTo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get threadId => $composableBuilder(
    column: $table.threadId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get threadTitle => $composableBuilder(
    column: $table.threadTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get silent => $composableBuilder(
    column: $table.silent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get enqueueSequence => $composableBuilder(
    column: $table.enqueueSequence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get normalUploadMaximumBytes => $composableBuilder(
    column: $table.normalUploadMaximumBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get chunkSizeBytes => $composableBuilder(
    column: $table.chunkSizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get uploadSessionId => $composableBuilder(
    column: $table.uploadSessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get phase => $composableBuilder(
    column: $table.phase,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resumePhase => $composableBuilder(
    column: $table.resumePhase,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteDraftFolder => $composableBuilder(
    column: $table.remoteDraftFolder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteTemporaryPath => $composableBuilder(
    column: $table.remoteTemporaryPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get chunkCollectionReady => $composableBuilder(
    column: $table.chunkCollectionReady,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get chunkManifestLoaded => $composableBuilder(
    column: $table.chunkManifestLoaded,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get verifiedChunksJson => $composableBuilder(
    column: $table.verifiedChunksJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get inFlightStep => $composableBuilder(
    column: $table.inFlightStep,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get inFlightRequestId => $composableBuilder(
    column: $table.inFlightRequestId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get finalizationDispatched => $composableBuilder(
    column: $table.finalizationDispatched,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get cleanupChunkSession => $composableBuilder(
    column: $table.cleanupChunkSession,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get cleanupDraftFile => $composableBuilder(
    column: $table.cleanupDraftFile,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageIdsJson => $composableBuilder(
    column: $table.messageIdsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorClass => $composableBuilder(
    column: $table.errorClass,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get profileFederated => $composableBuilder(
    column: $table.profileFederated,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get profileEnabled => $composableBuilder(
    column: $table.profileEnabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get profileCaption => $composableBuilder(
    column: $table.profileCaption,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get profileVoice => $composableBuilder(
    column: $table.profileVoice,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get profileReply => $composableBuilder(
    column: $table.profileReply,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get profileThreads => $composableBuilder(
    column: $table.profileThreads,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get profileSilent => $composableBuilder(
    column: $table.profileSilent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get roomCanWrite => $composableBuilder(
    column: $table.roomCanWrite,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get automaticRetryCount => $composableBuilder(
    column: $table.automaticRetryCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextAttemptAtMillis => $composableBuilder(
    column: $table.nextAttemptAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get sourceReleased => $composableBuilder(
    column: $table.sourceReleased,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localCleanupError => $composableBuilder(
    column: $table.localCleanupError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtMillis => $composableBuilder(
    column: $table.createdAtMillis,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AttachmentJobsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AttachmentJobsTable> {
  $$AttachmentJobsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get jobId =>
      $composableBuilder(column: $table.jobId, builder: (column) => column);

  GeneratedColumn<String> get serverUrl =>
      $composableBuilder(column: $table.serverUrl, builder: (column) => column);

  GeneratedColumn<int> get capabilityGeneration => $composableBuilder(
    column: $table.capabilityGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get replayContractRevision => $composableBuilder(
    column: $table.replayContractRevision,
    builder: (column) => column,
  );

  GeneratedColumn<String> get davUserId =>
      $composableBuilder(column: $table.davUserId, builder: (column) => column);

  GeneratedColumn<String> get roomToken =>
      $composableBuilder(column: $table.roomToken, builder: (column) => column);

  GeneratedColumn<String> get referenceId => $composableBuilder(
    column: $table.referenceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceHandle => $composableBuilder(
    column: $table.sourceHandle,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceOwnership => $composableBuilder(
    column: $table.sourceOwnership,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sourceByteLength => $composableBuilder(
    column: $table.sourceByteLength,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceSha256 => $composableBuilder(
    column: $table.sourceSha256,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceMimeType => $composableBuilder(
    column: $table.sourceMimeType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceDisplayName => $composableBuilder(
    column: $table.sourceDisplayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get messageKind => $composableBuilder(
    column: $table.messageKind,
    builder: (column) => column,
  );

  GeneratedColumn<String> get caption =>
      $composableBuilder(column: $table.caption, builder: (column) => column);

  GeneratedColumn<int> get replyTo =>
      $composableBuilder(column: $table.replyTo, builder: (column) => column);

  GeneratedColumn<int> get threadId =>
      $composableBuilder(column: $table.threadId, builder: (column) => column);

  GeneratedColumn<String> get threadTitle => $composableBuilder(
    column: $table.threadTitle,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get silent =>
      $composableBuilder(column: $table.silent, builder: (column) => column);

  GeneratedColumn<int> get enqueueSequence => $composableBuilder(
    column: $table.enqueueSequence,
    builder: (column) => column,
  );

  GeneratedColumn<int> get normalUploadMaximumBytes => $composableBuilder(
    column: $table.normalUploadMaximumBytes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get chunkSizeBytes => $composableBuilder(
    column: $table.chunkSizeBytes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get uploadSessionId => $composableBuilder(
    column: $table.uploadSessionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get phase =>
      $composableBuilder(column: $table.phase, builder: (column) => column);

  GeneratedColumn<String> get resumePhase => $composableBuilder(
    column: $table.resumePhase,
    builder: (column) => column,
  );

  GeneratedColumn<String> get remoteDraftFolder => $composableBuilder(
    column: $table.remoteDraftFolder,
    builder: (column) => column,
  );

  GeneratedColumn<String> get remoteTemporaryPath => $composableBuilder(
    column: $table.remoteTemporaryPath,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get chunkCollectionReady => $composableBuilder(
    column: $table.chunkCollectionReady,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get chunkManifestLoaded => $composableBuilder(
    column: $table.chunkManifestLoaded,
    builder: (column) => column,
  );

  GeneratedColumn<String> get verifiedChunksJson => $composableBuilder(
    column: $table.verifiedChunksJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get inFlightStep => $composableBuilder(
    column: $table.inFlightStep,
    builder: (column) => column,
  );

  GeneratedColumn<String> get inFlightRequestId => $composableBuilder(
    column: $table.inFlightRequestId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get finalizationDispatched => $composableBuilder(
    column: $table.finalizationDispatched,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get cleanupChunkSession => $composableBuilder(
    column: $table.cleanupChunkSession,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get cleanupDraftFile => $composableBuilder(
    column: $table.cleanupDraftFile,
    builder: (column) => column,
  );

  GeneratedColumn<String> get messageIdsJson => $composableBuilder(
    column: $table.messageIdsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get errorClass => $composableBuilder(
    column: $table.errorClass,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get profileFederated => $composableBuilder(
    column: $table.profileFederated,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get profileEnabled => $composableBuilder(
    column: $table.profileEnabled,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get profileCaption => $composableBuilder(
    column: $table.profileCaption,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get profileVoice => $composableBuilder(
    column: $table.profileVoice,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get profileReply => $composableBuilder(
    column: $table.profileReply,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get profileThreads => $composableBuilder(
    column: $table.profileThreads,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get profileSilent => $composableBuilder(
    column: $table.profileSilent,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get roomCanWrite => $composableBuilder(
    column: $table.roomCanWrite,
    builder: (column) => column,
  );

  GeneratedColumn<int> get automaticRetryCount => $composableBuilder(
    column: $table.automaticRetryCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get nextAttemptAtMillis => $composableBuilder(
    column: $table.nextAttemptAtMillis,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get sourceReleased => $composableBuilder(
    column: $table.sourceReleased,
    builder: (column) => column,
  );

  GeneratedColumn<String> get localCleanupError => $composableBuilder(
    column: $table.localCleanupError,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAtMillis => $composableBuilder(
    column: $table.createdAtMillis,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtMillis => $composableBuilder(
    column: $table.updatedAtMillis,
    builder: (column) => column,
  );
}

class $$AttachmentJobsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AttachmentJobsTable,
          StoredAttachmentJob,
          $$AttachmentJobsTableFilterComposer,
          $$AttachmentJobsTableOrderingComposer,
          $$AttachmentJobsTableAnnotationComposer,
          $$AttachmentJobsTableCreateCompanionBuilder,
          $$AttachmentJobsTableUpdateCompanionBuilder,
          (
            StoredAttachmentJob,
            BaseReferences<
              _$AppDatabase,
              $AttachmentJobsTable,
              StoredAttachmentJob
            >,
          ),
          StoredAttachmentJob,
          PrefetchHooks Function()
        > {
  $$AttachmentJobsTableTableManager(
    _$AppDatabase db,
    $AttachmentJobsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AttachmentJobsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AttachmentJobsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AttachmentJobsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> jobId = const Value.absent(),
                Value<String> serverUrl = const Value.absent(),
                Value<int> capabilityGeneration = const Value.absent(),
                Value<String> replayContractRevision = const Value.absent(),
                Value<String> davUserId = const Value.absent(),
                Value<String> roomToken = const Value.absent(),
                Value<String> referenceId = const Value.absent(),
                Value<String> sourceHandle = const Value.absent(),
                Value<String> sourceOwnership = const Value.absent(),
                Value<int> sourceByteLength = const Value.absent(),
                Value<String> sourceSha256 = const Value.absent(),
                Value<String> sourceMimeType = const Value.absent(),
                Value<String> sourceDisplayName = const Value.absent(),
                Value<String> messageKind = const Value.absent(),
                Value<String?> caption = const Value.absent(),
                Value<int?> replyTo = const Value.absent(),
                Value<int?> threadId = const Value.absent(),
                Value<String?> threadTitle = const Value.absent(),
                Value<bool> silent = const Value.absent(),
                Value<int> enqueueSequence = const Value.absent(),
                Value<int> normalUploadMaximumBytes = const Value.absent(),
                Value<int> chunkSizeBytes = const Value.absent(),
                Value<String?> uploadSessionId = const Value.absent(),
                Value<String> phase = const Value.absent(),
                Value<String?> resumePhase = const Value.absent(),
                Value<String?> remoteDraftFolder = const Value.absent(),
                Value<String?> remoteTemporaryPath = const Value.absent(),
                Value<bool> chunkCollectionReady = const Value.absent(),
                Value<bool> chunkManifestLoaded = const Value.absent(),
                Value<String> verifiedChunksJson = const Value.absent(),
                Value<String?> inFlightStep = const Value.absent(),
                Value<String?> inFlightRequestId = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<bool> finalizationDispatched = const Value.absent(),
                Value<bool> cleanupChunkSession = const Value.absent(),
                Value<bool> cleanupDraftFile = const Value.absent(),
                Value<String> messageIdsJson = const Value.absent(),
                Value<String?> errorClass = const Value.absent(),
                Value<bool> profileFederated = const Value.absent(),
                Value<bool> profileEnabled = const Value.absent(),
                Value<bool> profileCaption = const Value.absent(),
                Value<bool> profileVoice = const Value.absent(),
                Value<bool> profileReply = const Value.absent(),
                Value<bool> profileThreads = const Value.absent(),
                Value<bool> profileSilent = const Value.absent(),
                Value<bool> roomCanWrite = const Value.absent(),
                Value<int> automaticRetryCount = const Value.absent(),
                Value<int?> nextAttemptAtMillis = const Value.absent(),
                Value<bool> sourceReleased = const Value.absent(),
                Value<String?> localCleanupError = const Value.absent(),
                Value<int> createdAtMillis = const Value.absent(),
                Value<int> updatedAtMillis = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AttachmentJobsCompanion(
                accountId: accountId,
                jobId: jobId,
                serverUrl: serverUrl,
                capabilityGeneration: capabilityGeneration,
                replayContractRevision: replayContractRevision,
                davUserId: davUserId,
                roomToken: roomToken,
                referenceId: referenceId,
                sourceHandle: sourceHandle,
                sourceOwnership: sourceOwnership,
                sourceByteLength: sourceByteLength,
                sourceSha256: sourceSha256,
                sourceMimeType: sourceMimeType,
                sourceDisplayName: sourceDisplayName,
                messageKind: messageKind,
                caption: caption,
                replyTo: replyTo,
                threadId: threadId,
                threadTitle: threadTitle,
                silent: silent,
                enqueueSequence: enqueueSequence,
                normalUploadMaximumBytes: normalUploadMaximumBytes,
                chunkSizeBytes: chunkSizeBytes,
                uploadSessionId: uploadSessionId,
                phase: phase,
                resumePhase: resumePhase,
                remoteDraftFolder: remoteDraftFolder,
                remoteTemporaryPath: remoteTemporaryPath,
                chunkCollectionReady: chunkCollectionReady,
                chunkManifestLoaded: chunkManifestLoaded,
                verifiedChunksJson: verifiedChunksJson,
                inFlightStep: inFlightStep,
                inFlightRequestId: inFlightRequestId,
                attemptCount: attemptCount,
                finalizationDispatched: finalizationDispatched,
                cleanupChunkSession: cleanupChunkSession,
                cleanupDraftFile: cleanupDraftFile,
                messageIdsJson: messageIdsJson,
                errorClass: errorClass,
                profileFederated: profileFederated,
                profileEnabled: profileEnabled,
                profileCaption: profileCaption,
                profileVoice: profileVoice,
                profileReply: profileReply,
                profileThreads: profileThreads,
                profileSilent: profileSilent,
                roomCanWrite: roomCanWrite,
                automaticRetryCount: automaticRetryCount,
                nextAttemptAtMillis: nextAttemptAtMillis,
                sourceReleased: sourceReleased,
                localCleanupError: localCleanupError,
                createdAtMillis: createdAtMillis,
                updatedAtMillis: updatedAtMillis,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String jobId,
                required String serverUrl,
                required int capabilityGeneration,
                required String replayContractRevision,
                required String davUserId,
                required String roomToken,
                required String referenceId,
                required String sourceHandle,
                required String sourceOwnership,
                required int sourceByteLength,
                required String sourceSha256,
                required String sourceMimeType,
                required String sourceDisplayName,
                required String messageKind,
                Value<String?> caption = const Value.absent(),
                Value<int?> replyTo = const Value.absent(),
                Value<int?> threadId = const Value.absent(),
                Value<String?> threadTitle = const Value.absent(),
                required bool silent,
                required int enqueueSequence,
                required int normalUploadMaximumBytes,
                required int chunkSizeBytes,
                Value<String?> uploadSessionId = const Value.absent(),
                required String phase,
                Value<String?> resumePhase = const Value.absent(),
                Value<String?> remoteDraftFolder = const Value.absent(),
                Value<String?> remoteTemporaryPath = const Value.absent(),
                required bool chunkCollectionReady,
                required bool chunkManifestLoaded,
                required String verifiedChunksJson,
                Value<String?> inFlightStep = const Value.absent(),
                Value<String?> inFlightRequestId = const Value.absent(),
                required int attemptCount,
                required bool finalizationDispatched,
                required bool cleanupChunkSession,
                required bool cleanupDraftFile,
                required String messageIdsJson,
                Value<String?> errorClass = const Value.absent(),
                required bool profileFederated,
                required bool profileEnabled,
                required bool profileCaption,
                required bool profileVoice,
                required bool profileReply,
                required bool profileThreads,
                required bool profileSilent,
                required bool roomCanWrite,
                Value<int> automaticRetryCount = const Value.absent(),
                Value<int?> nextAttemptAtMillis = const Value.absent(),
                Value<bool> sourceReleased = const Value.absent(),
                Value<String?> localCleanupError = const Value.absent(),
                required int createdAtMillis,
                required int updatedAtMillis,
                Value<int> rowid = const Value.absent(),
              }) => AttachmentJobsCompanion.insert(
                accountId: accountId,
                jobId: jobId,
                serverUrl: serverUrl,
                capabilityGeneration: capabilityGeneration,
                replayContractRevision: replayContractRevision,
                davUserId: davUserId,
                roomToken: roomToken,
                referenceId: referenceId,
                sourceHandle: sourceHandle,
                sourceOwnership: sourceOwnership,
                sourceByteLength: sourceByteLength,
                sourceSha256: sourceSha256,
                sourceMimeType: sourceMimeType,
                sourceDisplayName: sourceDisplayName,
                messageKind: messageKind,
                caption: caption,
                replyTo: replyTo,
                threadId: threadId,
                threadTitle: threadTitle,
                silent: silent,
                enqueueSequence: enqueueSequence,
                normalUploadMaximumBytes: normalUploadMaximumBytes,
                chunkSizeBytes: chunkSizeBytes,
                uploadSessionId: uploadSessionId,
                phase: phase,
                resumePhase: resumePhase,
                remoteDraftFolder: remoteDraftFolder,
                remoteTemporaryPath: remoteTemporaryPath,
                chunkCollectionReady: chunkCollectionReady,
                chunkManifestLoaded: chunkManifestLoaded,
                verifiedChunksJson: verifiedChunksJson,
                inFlightStep: inFlightStep,
                inFlightRequestId: inFlightRequestId,
                attemptCount: attemptCount,
                finalizationDispatched: finalizationDispatched,
                cleanupChunkSession: cleanupChunkSession,
                cleanupDraftFile: cleanupDraftFile,
                messageIdsJson: messageIdsJson,
                errorClass: errorClass,
                profileFederated: profileFederated,
                profileEnabled: profileEnabled,
                profileCaption: profileCaption,
                profileVoice: profileVoice,
                profileReply: profileReply,
                profileThreads: profileThreads,
                profileSilent: profileSilent,
                roomCanWrite: roomCanWrite,
                automaticRetryCount: automaticRetryCount,
                nextAttemptAtMillis: nextAttemptAtMillis,
                sourceReleased: sourceReleased,
                localCleanupError: localCleanupError,
                createdAtMillis: createdAtMillis,
                updatedAtMillis: updatedAtMillis,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AttachmentJobsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AttachmentJobsTable,
      StoredAttachmentJob,
      $$AttachmentJobsTableFilterComposer,
      $$AttachmentJobsTableOrderingComposer,
      $$AttachmentJobsTableAnnotationComposer,
      $$AttachmentJobsTableCreateCompanionBuilder,
      $$AttachmentJobsTableUpdateCompanionBuilder,
      (
        StoredAttachmentJob,
        BaseReferences<
          _$AppDatabase,
          $AttachmentJobsTable,
          StoredAttachmentJob
        >,
      ),
      StoredAttachmentJob,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$AccountsTableTableManager get accounts =>
      $$AccountsTableTableManager(_db, _db.accounts);
  $$CachedConversationsTableTableManager get cachedConversations =>
      $$CachedConversationsTableTableManager(_db, _db.cachedConversations);
  $$ConversationAvatarsTableTableManager get conversationAvatars =>
      $$ConversationAvatarsTableTableManager(_db, _db.conversationAvatars);
  $$ChatCapabilitiesTableTableManager get chatCapabilities =>
      $$ChatCapabilitiesTableTableManager(_db, _db.chatCapabilities);
  $$ChatScopesTableTableManager get chatScopes =>
      $$ChatScopesTableTableManager(_db, _db.chatScopes);
  $$CachedChatMessagesTableTableManager get cachedChatMessages =>
      $$CachedChatMessagesTableTableManager(_db, _db.cachedChatMessages);
  $$TextSendOperationsTableTableManager get textSendOperations =>
      $$TextSendOperationsTableTableManager(_db, _db.textSendOperations);
  $$ChatDraftsTableTableManager get chatDrafts =>
      $$ChatDraftsTableTableManager(_db, _db.chatDrafts);
  $$AttachmentRuntimeAccountsTableTableManager get attachmentRuntimeAccounts =>
      $$AttachmentRuntimeAccountsTableTableManager(
        _db,
        _db.attachmentRuntimeAccounts,
      );
  $$AttachmentJobsTableTableManager get attachmentJobs =>
      $$AttachmentJobsTableTableManager(_db, _db.attachmentJobs);
}
