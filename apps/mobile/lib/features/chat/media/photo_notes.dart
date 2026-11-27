import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/app_database.dart';
import '../../../data/chat_media_repository.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../owntalk_extensions/owntalk_extensions_service.dart';

part 'photo_notes_canvas.dart';

typedef PhotoNoteTarget = ({String room, int message, int file});
const _feature = 'chat.photoNotes';
final _support = FutureProvider.autoDispose.family<bool, String>(
  (ref, account) =>
      ref.watch(ownTalkExtensionsServiceProvider).supports(account, _feature),
);

class PhotoNotesButton extends ConsumerWidget {
  const PhotoNotesButton({
    super.key,
    required this.account,
    required this.target,
    required this.repository,
    required this.uri,
    required this.contentType,
    required this.name,
  });
  final StoredAccount account;
  final PhotoNoteTarget target;
  final ChatMediaRepository repository;
  final Uri uri;
  final String contentType, name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(_support(account.id)).valueOrNull != true) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: const Key('open-photo-notes'),
      color: Colors.white,
      tooltip: AppLocalizations.of(context).photoNotes,
      icon: const Icon(Icons.add_location_alt_outlined),
      onPressed: () => Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/chat/image/notes'),
          builder: (_) => _PhotoNotesScreen(button: this),
        ),
      ),
    );
  }
}

class _PhotoEntry {
  const _PhotoEntry(this.id, this.author, this.body);
  final String id, author, body;
  factory _PhotoEntry.fromJson(Map data) => _PhotoEntry(
    data['id'] as String,
    data['author'] as String,
    data['body'] as String,
  );
}

class _Pin {
  const _Pin(this.entry, this.point, this.replies);
  final _PhotoEntry entry;
  final Offset point;
  final List<_PhotoEntry> replies;
  factory _Pin.fromJson(Map data) {
    double coordinate(String key) {
      final value = (data[key] as num).toDouble();
      if (!value.isFinite || value < 0 || value > 1) {
        throw const FormatException();
      }
      return value;
    }

    return _Pin(
      _PhotoEntry.fromJson(data),
      Offset(coordinate('x'), coordinate('y')),
      [
        for (final reply in data['replies'] as List)
          _PhotoEntry.fromJson(reply as Map),
      ],
    );
  }
}

class _PhotoNotesScreen extends ConsumerStatefulWidget {
  const _PhotoNotesScreen({required this.button});
  final PhotoNotesButton button;
  @override
  ConsumerState<_PhotoNotesScreen> createState() => _PhotoNotesScreenState();
}

class _PhotoNotesScreenState extends ConsumerState<_PhotoNotesScreen>
    with WidgetsBindingObserver {
  final _editor = TextEditingController();
  final _focus = FocusNode();
  final _positionFocus = FocusNode();
  final _transform = TransformationController();
  ui.Image? _image;
  String? _version, _selected, _requestId;
  List<_Pin> _pins = const [];
  Offset? _draft;
  bool _placing = false, _busy = false, _canEdit = false;
  int? _error;
  Timer? _timer;
  _Pin? get _pin => _pins.where((p) => p.entry.id == _selected).firstOrNull;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_error == null &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _version != null) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _image?.dispose();
    _editor.dispose();
    _focus.dispose();
    _positionFocus.dispose();
    _transform.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _canEdit = false;
    });
    try {
      final button = widget.button;
      final file = await button.repository.loadOriginalFile(
        account: button.account,
        uri: button.uri,
        expectedContentType: button.contentType,
      );
      var version = file.etag?.trim();
      if (version == null || version.isEmpty || version.startsWith('W/')) {
        throw const FormatException();
      }
      if (version.length >= 2 &&
          version.startsWith('"') &&
          version.endsWith('"')) {
        version = version.substring(1, version.length - 1);
      }
      if (version.isEmpty) throw const FormatException();
      final codec = await ui.instantiateImageCodecWithSize(
        await ui.ImmutableBuffer.fromUint8List(file.body),
        getTargetSize: (w, h) {
          const maximum = 2048;
          if (w <= maximum && h <= maximum) {
            return ui.TargetImageSize(width: w, height: h);
          }
          return w >= h
              ? ui.TargetImageSize(width: maximum)
              : ui.TargetImageSize(height: maximum);
        },
      );
      late final ui.Image image;
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      if (!mounted) {
        image.dispose();
        return;
      }
      final previous = _image;
      _image = image;
      previous?.dispose();
      _version = version;
      _resetSelection();
      _transform.value = Matrix4.identity();
      await _fetch();
    } catch (e) {
      _recordFailure(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _recordFailure(Object e) {
    if (!mounted) return;
    final failure = e is OwnTalkExtensionsException ? e : null;
    final code = failure?.statusCode;
    final lostSession = switch (failure?.code) {
      OwnTalkExtensionsError.accountMissing ||
      OwnTalkExtensionsError.credentialMissing ||
      OwnTalkExtensionsError.reauthenticationRequired ||
      OwnTalkExtensionsError.unavailable => true,
      _ => false,
    };
    if (lostSession) ref.invalidate(_support(widget.button.account.id));
    final accessLost = lostSession || code == 401 || code == 403 || code == 404;
    setState(() {
      _error = accessLost ? 404 : code ?? 0;
      _canEdit = false;
      if (accessLost || code == 409) {
        _version = null;
        _pins = [];
        _resetSelection();
        _image?.dispose();
        _image = null;
      }
    });
  }

  Future<void> _fetch({String? replyTo, Map<String, Object?>? write}) async {
    final b = widget.button;
    final target = b.target;
    final response = await ref
        .read(ownTalkExtensionsServiceProvider)
        .featureRequest(
          accountId: b.account.id,
          feature: _feature,
          path: [
            'room',
            target.room,
            'photo',
            '${target.message}',
            '${target.file}',
            'notes',
            if (replyTo != null) ...[replyTo, 'replies'],
          ],
          method: write == null ? 'GET' : 'POST',
          query: write == null ? {'version': _version!} : null,
          values: write == null ? null : {...write, 'version': _version},
        );
    if (!mounted) return;
    if (response['version'] != _version) {
      throw const OwnTalkExtensionsException(
        OwnTalkExtensionsError.invalidResponse,
        statusCode: 409,
      );
    }
    final pins = [
      for (final p in response['notes'] as List) _Pin.fromJson(p as Map),
    ];
    final canEdit = response['canEdit'] as bool;
    setState(() {
      _pins = pins;
      _canEdit = canEdit;
      _error = null;
    });
  }

  Future<void> _refresh() async {
    if (_busy || _version == null) return;
    _busy = true;
    try {
      await _fetch();
    } catch (e) {
      _recordFailure(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _resetSelection([String? id]) {
    _placing = false;
    _draft = null;
    _selected = id;
    _editor.clear();
    _requestId = null;
  }

  void _select(String id) {
    if (_busy || _placing || _draft != null || _editor.text.isNotEmpty) {
      return;
    }
    setState(() => _resetSelection(id));
  }

  void _position(Offset point) {
    if (!_placing || _busy) return;
    setState(() {
      _draft = point;
      _placing = false;
      _requestId = null;
    });
    _focus.requestFocus();
  }

  Future<void> _save() async {
    final body = _editor.text.trim(), draft = _draft;
    if (!_canEdit ||
        _busy ||
        body.isEmpty ||
        (draft == null && _selected == null)) {
      return;
    }
    final id = _requestId ??= const Uuid().v4();
    setState(() => _busy = true);
    try {
      await _fetch(
        replyTo: draft == null ? _selected : null,
        write: {
          'requestId': id,
          'body': body,
          if (draft != null) ...{'x': draft.dx, 'y': draft.dy},
        },
      );
      if (mounted) {
        setState(() => _resetSelection(draft == null ? _selected : id));
      }
    } catch (e) {
      _recordFailure(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final image = _image, pin = _pin;
    final editorOpen = _draft != null || pin != null;
    final error = _error;
    final controls = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (error != null) ...[
          Text(
            error == 409
                ? s.photoChanged
                : error == 404
                ? s.photoNoAccess
                : error == 422
                ? s.photoNotesFull
                : s.roomToolLoadFailure,
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _busy
                  ? null
                  : _version == null
                  ? _load
                  : _refresh,
              icon: const Icon(Icons.refresh),
              label: Text(s.photoLoadAgain),
            ),
          ),
        ],
        if (image != null && error == null && !editorOpen && !_placing) ...[
          if (_canEdit)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () {
                        setState(() {
                          _resetSelection();
                          _placing = true;
                        });
                        _positionFocus.requestFocus();
                      },
                icon: const Icon(Icons.add_location_alt_outlined),
                label: Text(s.photoAddPin),
              ),
            ),
          const SizedBox(height: 12),
          Text(_pins.isEmpty ? s.photoNoPins : s.photoChoosePin),
          for (var i = 0; i < _pins.length; i++)
            ListTile(
              leading: Text('${i + 1}'),
              title: Text(_pins[i].entry.body),
              subtitle: Text(_pins[i].entry.author),
              onTap: () => _select(_pins[i].entry.id),
            ),
        ],
        if (_placing)
          Text(
            s.photoPickPoint,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        if (pin != null) ...[
          Text(
            '${s.photoPin} ${_pins.indexOf(pin) + 1}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          for (final entry in [pin.entry, ...pin.replies])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.author,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  SelectableText(entry.body),
                ],
              ),
            ),
        ],
        if (editorOpen && (_canEdit || _editor.text.isNotEmpty))
          TextField(
            controller: _editor,
            readOnly: _busy || !_canEdit,
            focusNode: _focus,
            maxLength: 2000,
            minLines: 1,
            maxLines: 4,
            onChanged: (_) => setState(() => _requestId = null),
            decoration: InputDecoration(
              labelText: _draft == null ? s.photoReplyText : s.photoNoteText,
            ),
          ),
        if (_placing || editorOpen)
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: _busy ? null : () => setState(_resetSelection),
                child: Text(
                  editorOpen && _editor.text.isEmpty && _draft == null
                      ? s.close
                      : s.cancel,
                ),
              ),
              if (editorOpen && _canEdit)
                FilledButton.icon(
                  key: Key(
                    _draft == null ? 'photo-send-reply' : 'photo-save-pin',
                  ),
                  onPressed: _busy || _editor.text.trim().isEmpty
                      ? null
                      : _save,
                  icon: const Icon(Icons.send_rounded),
                  label: Text(
                    _draft == null ? s.photoReplyText : s.photoAddPin,
                  ),
                ),
            ],
          ),
      ],
    );
    final canvas = image == null
        ? Center(
            child: _busy
                ? const CircularProgressIndicator()
                : const Icon(Icons.image_not_supported_outlined),
          )
        : _PhotoCanvas(
            image: image,
            pins: _pins,
            selected: _selected,
            draft: _draft,
            placing: _placing,
            focusNode: _positionFocus,
            transform: _transform,
            onPick: _position,
            onSelect: _select,
          );
    return Scaffold(
      appBar: AppBar(
        title: Tooltip(message: widget.button.name, child: Text(s.photoNotes)),
        actions: [
          if (_version != null)
            IconButton(
              onPressed: _busy ? null : _refresh,
              tooltip: s.refresh,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth >= 700) {
              return Row(
                children: [
                  Expanded(child: canvas),
                  const VerticalDivider(width: 1),
                  SizedBox(width: 310, child: controls),
                ],
              );
            }
            return Column(
              children: [
                Expanded(flex: 6, child: canvas),
                const Divider(height: 1),
                Expanded(flex: 4, child: controls),
              ],
            );
          },
        ),
      ),
    );
  }
}
