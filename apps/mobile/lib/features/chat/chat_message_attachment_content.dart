part of 'chat_message_content.dart';

final class _ChatAttachment extends ConsumerWidget {
  const _ChatAttachment({
    super.key,
    required this.account,
    required this.parameter,
    required this.roomToken,
    required this.messageId,
    required this.index,
    this.onOpenImage,
    this.compact = false,
  });

  final StoredAccount account;
  final ChatRichObjectParameter parameter;
  final String roomToken;
  final int messageId;
  final int index;
  final VoidCallback? onOpenImage;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = (parameter.name ?? '').trim().isEmpty
        ? strings.attachment
        : parameter.name!.trim();
    final mimeType = _mimeType(parameter);
    final attachment = _davAttachment(account, parameter);
    final contact = _isContactAttachment(
      attachment?.vCardPath ?? false,
      mimeType,
    );
    final originalUri = attachment?.uri;
    final voiceUri = mimeType?.startsWith('audio/') == true
        ? originalUri
        : null;
    final previewUri = _previewUri(account, parameter, mimeType);
    final previewProvider = previewUri == null
        ? null
        : chatMediaProvider(
            ChatMediaProviderKey(
              account: account,
              uri: previewUri,
              originalUri: originalUri,
              originalContentType: mimeType,
            ),
          );
    var image = previewProvider == null ? null : ref.watch(previewProvider);
    if (image?.isLoading == true) {
      final cached = ref
          .read(chatMediaCacheProvider)
          .read(ChatMediaCache.keyOf(accountId: account.id, uri: previewUri!));
      if (cached != null) image = AsyncData(cached);
    }
    final fullScreenPreviewUri = previewUri == null
        ? null
        : _fullScreenPreviewUri(previewUri);
    final openFile = _attachmentOpenFile(
      context,
      ref,
      account: account,
      parameter: parameter,
      roomToken: roomToken,
      messageId: messageId,
      index: index,
    );
    final Future<void> Function()? openImage =
        fullScreenPreviewUri == null || originalUri == null || mimeType == null
        ? null
        : () => showAuthenticatedImageViewer(
            context,
            account: account,
            previewUri: fullScreenPreviewUri,
            smallerPreviewUri: previewUri,
            originalUri: originalUri,
            originalContentType: mimeType,
            imageName: name,
            repository: ref.read(chatMediaRepositoryProvider),
            openAppSettings: () => ref.read(appSettingsOpenerProvider).open(),
            onOpenFile: openFile == null ? null : () => unawaited(openFile()),
            onForward: _forwardFileAction(context, parameter),
          );
    final providedOpenImage = onOpenImage;
    final Future<void> Function()? openAttachment = onOpenImage != null
        ? () async => providedOpenImage!()
        : openImage ?? openFile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (voiceUri != null)
          _VoiceAttachment(
            // Keyed by the message it belongs to. Without it Flutter reuses
            // the state — player, position and duration — for whatever
            // message lands in the same slot, so scrolling a list of voice
            // messages showed one recording's timeline while another one
            // played. The chat timeline is keyed already; the shared-items
            // list is where this was seen.
            key: ValueKey('${account.id}-$messageId-voice'),
            account: account,
            uri: voiceUri,
            roomToken: roomToken,
            messageId: messageId,
            index: index,
            name: name,
          ),
        if (previewProvider != null)
          _InlineChatImagePreview(
            key: ValueKey('${account.id}\u0000$previewUri'),
            parameter: parameter,
            image: image!,
            name: name,
            messageId: messageId,
            index: index,
            compact: compact,
            onOpen:
                onOpenImage ??
                (openImage == null ? null : () => unawaited(openImage())),
            onOpenFile: openFile == null ? null : () => unawaited(openFile()),
            onCopy:
                fullScreenPreviewUri == null ||
                    originalUri == null ||
                    mimeType == null ||
                    !imageClipboardSupported
                ? null
                : () => unawaited(
                    copyChatImage(
                      messageContext: context,
                      account: account,
                      image: ChatGalleryImage(
                        previewUri: fullScreenPreviewUri,
                        originalUri: originalUri,
                        contentType: mimeType,
                        name: name,
                      ),
                      repository: ref.read(chatMediaRepositoryProvider),
                      exporter: ref.read(chatImageExporterProvider),
                    ),
                  ),
            onSave: originalUri == null || mimeType == null
                ? null
                : () => unawaited(
                    _exportDownloadedAttachment(
                      context,
                      ref,
                      action: _ChatAttachmentMenuAction.save,
                      account: account,
                      uri: originalUri,
                      fileName: name,
                      contentType: mimeType,
                      expectedBytes: _attachmentExpectedBytes(parameter),
                    ),
                  ),
            onRetry: () async {
              final cache = ref.read(chatMediaCacheProvider);
              final disk = ref.read(chatMediaDiskCacheProvider);
              final key = ChatMediaCache.keyOf(
                accountId: account.id,
                uri: previewUri!,
              );
              await cache.withEntry(key, () async {
                cache.evict(key);
                await disk.evict(accountId: account.id, uri: previewUri);
              });
              if (context.mounted) ref.invalidate(previewProvider);
            },
          ),
        if (previewProvider == null &&
            voiceUri == null &&
            openAttachment != null)
          Material(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        contact
                            ? Icons.contact_page_outlined
                            : mimeType?.startsWith('image/') == true
                            ? Icons.image_rounded
                            : Icons.insert_drive_file_rounded,
                        color: scheme.primary,
                      ),
                      if (contact) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            strings.contactAttachment,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.primary),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  _ChatAttachmentActions(
                    key: ValueKey('${account.id}-$messageId-$index-actions'),
                    messageId: messageId,
                    index: index,
                    contact: contact,
                    name: name,
                    openLabel: strings.openAttachment,
                    saveLabel: strings.saveAttachment,
                    shareLabel: strings.shareAttachment,
                    openSemanticsLabel: contact
                        ? strings.openContact(name)
                        : '${strings.openAttachment}: $name',
                    open: openAttachment,
                    save: () => _exportDownloadedAttachment(
                      context,
                      ref,
                      action: _ChatAttachmentMenuAction.save,
                      account: account,
                      uri: originalUri!,
                      fileName: name,
                      contentType: mimeType!,
                      expectedBytes: _attachmentExpectedBytes(parameter),
                    ),
                    share: () => _exportDownloadedAttachment(
                      context,
                      ref,
                      action: _ChatAttachmentMenuAction.share,
                      account: account,
                      uri: originalUri!,
                      fileName: name,
                      contentType: mimeType!,
                      expectedBytes: _attachmentExpectedBytes(parameter),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

enum _ChatAttachmentMenuAction { save, share }

final class _ChatAttachmentActions extends StatefulWidget {
  const _ChatAttachmentActions({
    super.key,
    required this.messageId,
    required this.index,
    required this.contact,
    required this.name,
    required this.openLabel,
    required this.saveLabel,
    required this.shareLabel,
    required this.openSemanticsLabel,
    required this.open,
    required this.save,
    required this.share,
  });

  final int messageId;
  final int index;
  final bool contact;
  final String name;
  final String openLabel;
  final String saveLabel;
  final String shareLabel;
  final String openSemanticsLabel;
  final Future<void> Function() open;
  final Future<void> Function() save;
  final Future<void> Function() share;

  @override
  State<_ChatAttachmentActions> createState() => _ChatAttachmentActionsState();
}

final class _ChatAttachmentActionsState extends State<_ChatAttachmentActions> {
  bool _running = false;

  void _run(Future<void> Function() action) {
    if (_running) return;
    setState(() => _running = true);
    unawaited(_finish(action));
  }

  Future<void> _finish(Future<void> Function() action) async {
    try {
      await action();
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    VoidCallback? run(Future<void> Function() action) =>
        _running ? null : () => _run(action);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _attachmentAction(
          key: Key(
            'chat-attachment-open-action-${widget.messageId}-${widget.index}',
          ),
          semanticsKey: Key(
            widget.contact
                ? 'chat-open-contact-${widget.messageId}-${widget.index}'
                : 'chat-open-attachment-${widget.messageId}-${widget.index}',
          ),
          icon: Icons.open_in_new_rounded,
          label: widget.openLabel,
          semanticsLabel: widget.openSemanticsLabel,
          onTap: run(widget.open),
        ),
        _attachmentAction(
          key: Key(
            'chat-attachment-save-action-${widget.messageId}-${widget.index}',
          ),
          icon: Icons.save_alt_rounded,
          label: widget.saveLabel,
          semanticsLabel: '${widget.saveLabel}: ${widget.name}',
          onTap: run(widget.save),
        ),
        _attachmentAction(
          key: Key(
            'chat-attachment-share-action-${widget.messageId}-${widget.index}',
          ),
          icon: Icons.share_rounded,
          label: widget.shareLabel,
          semanticsLabel: '${widget.shareLabel}: ${widget.name}',
          onTap: run(widget.share),
        ),
      ],
    );
  }
}

Widget _attachmentAction({
  required Key key,
  Key? semanticsKey,
  required IconData icon,
  required String label,
  required String semanticsLabel,
  required VoidCallback? onTap,
}) {
  return SizedBox.square(
    key: key,
    dimension: 48,
    child: Tooltip(
      message: label,
      child: Semantics(
        key: semanticsKey,
        button: true,
        enabled: onTap != null,
        label: semanticsLabel,
        onTap: onTap,
        child: ExcludeSemantics(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Center(child: Icon(icon, size: 20)),
          ),
        ),
      ),
    ),
  );
}

/// Files web page and would answer with HTML, so it must not be downloaded.
final class _DavAttachment {
  const _DavAttachment({required this.uri, required this.vCardPath});

  final Uri uri;
  final bool vCardPath;
}

_DavAttachment? _davAttachment(
  StoredAccount account,
  ChatRichObjectParameter parameter,
) {
  final raw = parameter.wire['path'];
  if (raw is! String) {
    return null;
  }
  final DavRelativePath path;
  final DavUserId user;
  try {
    path = DavRelativePath.parse(raw);
    user = DavUserId.parse(account.loginName);
  } on TalkProtocolException {
    return null;
  }
  final server = ServerBase.parse(account.serverUrl);
  return _DavAttachment(
    uri: server.uri.replace(
      pathSegments: [
        ...server.uri.pathSegments.where((segment) => segment.isNotEmpty),
        'remote.php',
        'dav',
        'files',
        user.value,
        ...path.segments,
      ],
    ),
    vCardPath: path.segments.last.toLowerCase().endsWith('.vcf'),
  );
}

/// Bounds every inline image bubble fits into.
const Size _imageBoxBound = Size(420, 320);
const double _imageBoxMinEdge = 48;

/// Box for pictures whose dimensions Talk did not send.
const Size _imageBoxFallback = Size(240, 180);

/// Fits metadata or decoded dimensions into the available width and 320px cap.
Size _reservedImageBox(
  ChatRichObjectParameter parameter, {
  Size? decoded,
  double maxWidth = 420,
}) {
  final width = _dimension(parameter.wire['width']);
  final height = _dimension(parameter.wire['height']);
  final source =
      decoded ??
      (width != null && height != null
          ? Size(width, height)
          : _imageBoxFallback);
  final availableWidth = math.min(_imageBoxBound.width, maxWidth);
  if (availableWidth <= 0) return Size.zero;
  final scale = math.min(
    1.0,
    math.min(
      availableWidth / source.width,
      _imageBoxBound.height / source.height,
    ),
  );
  return Size(
    math.min(availableWidth, math.max(_imageBoxMinEdge, source.width * scale)),
    math.max(_imageBoxMinEdge, source.height * scale),
  );
}

double? _dimension(Object? value) {
  final parsed = switch (value) {
    int() => value.toDouble(),
    double() => value,
    String() => double.tryParse(value),
    _ => null,
  };
  return parsed != null && parsed.isFinite && parsed > 0 ? parsed : null;
}

/// Declared size of the shared file, when Talk sent one. Only a fallback for
/// the progress bar when the download response carries no length.
int? _attachmentExpectedBytes(ChatRichObjectParameter parameter) {
  final value = parameter.wire['size'];
  final size = switch (value) {
    int() => value,
    String() => int.tryParse(value),
    _ => null,
  };
  return size != null && size > 0 ? size : null;
}

String? _mimeType(ChatRichObjectParameter parameter) {
  final value = parameter.wire['mimetype'] ?? parameter.wire['mimeType'];
  return value is String ? value.trim().toLowerCase() : null;
}

bool _isContactAttachment(bool vCardPath, String? mimeType) {
  if (const <String>{
    'text/vcard',
    'text/x-vcard',
    'text/directory',
  }.contains(mimeType)) {
    return true;
  }
  if (!vCardPath) {
    return false;
  }
  return const <String>{
    'application/octet-stream',
    'binary/octet-stream',
  }.contains(mimeType);
}

Uri? _previewUri(
  StoredAccount account,
  ChatRichObjectParameter parameter,
  String? mimeType,
) {
  if (mimeType?.startsWith('image/') != true) {
    return null;
  }
  final available = parameter.wire['preview-available'];
  if (available == false || available == 0 || available == 'no') {
    return null;
  }
  final fileId = int.tryParse(parameter.id ?? '');
  if (fileId == null || fileId < 1) {
    return null;
  }
  final server = ServerBase.parse(account.serverUrl);
  // `a` is Nextcloud's "preserve the aspect ratio" flag (see
  // core/Controller/PreviewController.php). With `a=0` the server crops the
  // image to exactly x by y, so a wide photo came back as a square cut out of
  // its middle instead of the whole picture. The box below is a bound, not a
  // target shape.
  return server.uri.replace(
    pathSegments: [...server.uri.pathSegments, 'index.php', 'core', 'preview'],
    queryParameters: {
      'fileId': '$fileId',
      'x': '1024',
      'y': '1024',
      'a': '1',
      if (parameter.wire['etag'] case final String etag when etag.isNotEmpty)
        'c': etag,
    },
  );
}

Uri _fullScreenPreviewUri(Uri previewUri) {
  return previewUri.replace(
    queryParameters: <String, String>{
      ...previewUri.queryParameters,
      'x': '2048',
      'y': '2048',
    },
  );
}

/// A download over a slow link can run for many seconds. Without an immediate
/// indicator the bubble stays silent and the listener cannot tell a slow
/// download from a button that did nothing, so the notice goes up before the
/// request starts and comes down however the request ends. The server does not
/// always declare a length, so the bar falls back to indeterminate rather than
/// inventing a percentage.
///
/// An overlay entry rather than a snack bar: the messenger queues snack bars
/// behind whatever is still animating out, and closing one that is not at the
/// head of that queue is an assertion failure.
Future<T> _withDownloadNotice<T>(
  BuildContext context,
  Future<T> Function(ChatDownloadProgress onProgress) run, {
  int? expectedBytes,
}) async {
  final overlay = Overlay.of(context);
  final progress = ValueNotifier<({int received, int? total})>((
    received: 0,
    total: null,
  ));
  final notice = OverlayEntry(
    builder: (_) => _AttachmentDownloadNotice(progress: progress),
  );
  overlay.insert(notice);
  try {
    return await run((received, total) {
      progress.value = (received: received, total: total ?? expectedBytes);
    });
  } finally {
    notice
      ..remove()
      ..dispose();
    progress.dispose();
  }
}

final class _AttachmentDownloadNotice extends StatelessWidget {
  const _AttachmentDownloadNotice({required this.progress});

  final ValueListenable<({int received, int? total})> progress;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Material(
              key: const Key('chat-attachment-downloading'),
              color: scheme.inverseSurface,
              elevation: 6,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: ValueListenableBuilder<({int received, int? total})>(
                  valueListenable: progress,
                  builder: (context, value, _) {
                    final total = value.total;
                    final fraction = total != null && total > 0
                        ? (value.received / total).clamp(0.0, 1.0)
                        : null;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fraction == null
                              ? strings.attachmentDownloading
                              : strings.attachmentDownloadingPercent(
                                  (fraction * 100).round(),
                                ),
                          key: const Key('chat-attachment-downloading-label'),
                          style: TextStyle(color: scheme.onInverseSurface),
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          key: const Key('chat-attachment-downloading-bar'),
                          value: fraction,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Re-reads the message behind a download that failed and returns the
/// attachment's corrected address, or `null` when nothing changed.
///
/// A download can fail because the cached message carries a path the server
/// does not know. That is what the HPB relay wrote until build 63: it renders
/// a file the way the SHARE sees it, so an attachment sent from this account
/// keeps a path every download answers with 404, and nothing re-reads a
/// message the cache already holds. The message is asked for once, and the
/// address it then yields is returned so the download can be repeated.
Future<Uri?> _repairedAttachmentUri(
  WidgetRef ref, {
  required StoredAccount account,
  required String roomToken,
  required int messageId,
  required int index,
  required Uri failedUri,
}) => ref.read(attachmentUriRepairProvider)(
  account: account,
  roomToken: roomToken,
  messageId: messageId,
  index: index,
  failedUri: failedUri,
);

/// The repair itself, behind [attachmentUriRepairProvider] so a widget test
/// can render a bubble without it reaching a database.
Future<Uri?> repairAttachmentUri(
  Ref ref, {
  required StoredAccount account,
  required String roomToken,
  required int messageId,
  required int index,
  required Uri failedUri,
}) async {
  try {
    final refreshed = await ref
        .read(chatServiceProvider)
        .refreshMessage(
          accountId: account.id,
          roomToken: roomToken,
          messageId: messageId,
        );
    if (!refreshed) {
      return null;
    }
    final row = await ref
        .read(chatRepositoryProvider)
        .getMessage(
          accountId: account.id,
          roomToken: roomToken,
          messageId: messageId,
        );
    if (row == null) {
      return null;
    }
    final message = ChatMessage.fromJson(jsonDecode(row.rawJson));
    final files = message.messageParameters.entries
        .where((entry) => entry.value.type == 'file')
        .toList(growable: false);
    if (index >= files.length) {
      return null;
    }
    final uri = _davAttachment(account, files[index].value)?.uri;
    return uri == null || uri == failedUri ? null : uri;
  } on Object catch (error) {
    debugPrint('[attachments] re-reading message $messageId failed: $error');
    return null;
  }
}

Future<void> _openDownloadedAttachment(
  BuildContext context,
  WidgetRef ref, {
  required StoredAccount account,
  required Uri uri,
  required String fileName,
  required String contentType,
  int? expectedBytes,
  Future<Uri?> Function()? repairUri,
}) async {
  final opener = ref.read(chatAttachmentOpenActionFactoryProvider)(
    ref.read(chatMediaRepositoryProvider),
  );
  Future<ChatAttachmentOpenResult> open(Uri target) => _withDownloadNotice(
    context,
    expectedBytes: expectedBytes,
    (onProgress) => opener.open(
      account: account,
      uri: target,
      fileName: fileName,
      expectedContentType: contentType,
      onProgress: onProgress,
    ),
  );
  var result = await open(uri);
  // A download that failed can mean the cached message still names a path the
  // server does not know. The message is re-read once, and only then is the
  // failure reported.
  if (result == ChatAttachmentOpenResult.downloadFailed &&
      repairUri != null &&
      context.mounted) {
    final repaired = await repairUri();
    if (repaired != null && context.mounted) {
      result = await open(repaired);
    }
  }
  if (result == ChatAttachmentOpenResult.opened || !context.mounted) {
    return;
  }
  final strings = AppLocalizations.of(context);
  final message = switch (result) {
    ChatAttachmentOpenResult.opened => strings.conversationActionErrorGeneric,
    ChatAttachmentOpenResult.reauthenticationRequired =>
      strings.attachmentReauthenticationRequired,
    ChatAttachmentOpenResult.tooLarge => strings.attachmentTooLarge,
    ChatAttachmentOpenResult.invalid => strings.attachmentInvalid,
    ChatAttachmentOpenResult.downloadFailed => strings.attachmentDownloadFailed,
    ChatAttachmentOpenResult.storageFailed => strings.attachmentStorageFailed,
    ChatAttachmentOpenResult.openFailed =>
      strings.conversationActionErrorGeneric,
  };
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}

Future<void> _exportDownloadedAttachment(
  BuildContext context,
  WidgetRef ref, {
  required _ChatAttachmentMenuAction action,
  required StoredAccount account,
  required Uri uri,
  required String fileName,
  required String contentType,
  int? expectedBytes,
}) async {
  final exporter = ref.read(chatAttachmentExportActionFactoryProvider)(
    ref.read(chatMediaRepositoryProvider),
  );
  final strings = AppLocalizations.of(context);
  final String? message;
  switch (action) {
    case _ChatAttachmentMenuAction.save:
      final result = await _withDownloadNotice(
        context,
        expectedBytes: expectedBytes,
        (onProgress) => exporter.save(
          account: account,
          uri: uri,
          fileName: fileName,
          expectedContentType: contentType,
          onProgress: onProgress,
        ),
      );
      message = switch (result) {
        ChatAttachmentSaveResult.saved => strings.attachmentSaved,
        ChatAttachmentSaveResult.cancelled => strings.attachmentSaveCancelled,
        ChatAttachmentSaveResult.reauthenticationRequired =>
          strings.attachmentReauthenticationRequired,
        ChatAttachmentSaveResult.tooLarge => strings.attachmentTooLarge,
        ChatAttachmentSaveResult.invalid => strings.attachmentInvalid,
        ChatAttachmentSaveResult.downloadFailed =>
          strings.attachmentDownloadFailed,
        ChatAttachmentSaveResult.permissionDenied =>
          strings.attachmentPermissionDenied,
        ChatAttachmentSaveResult.storageFailed =>
          strings.attachmentStorageFailed,
      };
    case _ChatAttachmentMenuAction.share:
      final result = await _withDownloadNotice(
        context,
        expectedBytes: expectedBytes,
        (onProgress) => exporter.share(
          account: account,
          uri: uri,
          fileName: fileName,
          expectedContentType: contentType,
          onProgress: onProgress,
        ),
      );
      message = switch (result) {
        ChatAttachmentShareResult.shared ||
        ChatAttachmentShareResult.offered ||
        ChatAttachmentShareResult.cancelled => null,
        ChatAttachmentShareResult.reauthenticationRequired =>
          strings.attachmentReauthenticationRequired,
        ChatAttachmentShareResult.tooLarge => strings.attachmentTooLarge,
        ChatAttachmentShareResult.invalid => strings.attachmentInvalid,
        ChatAttachmentShareResult.downloadFailed =>
          strings.attachmentDownloadFailed,
        ChatAttachmentShareResult.permissionDenied =>
          strings.attachmentPermissionDenied,
        ChatAttachmentShareResult.shareFailed => strings.attachmentShareFailed,
      };
  }
  if (!context.mounted || message == null) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}

/// What opening the file behind [parameter] does, or null when there is
/// nothing to open: a voice message plays in place and a file without an
/// address cannot be fetched.
///
/// Text and Markdown are read in place; everything else still goes to the
/// platform's own handler, which is also what a device without a text app
/// used to fall back to and no longer needs to.
Future<void> Function()? _attachmentOpenFile(
  BuildContext context,
  WidgetRef ref, {
  required StoredAccount account,
  required ChatRichObjectParameter parameter,
  required String roomToken,
  required int messageId,
  required int index,
}) {
  final name = (parameter.name ?? '').trim().isEmpty
      ? AppLocalizations.of(context).attachment
      : parameter.name!.trim();
  final mimeType = _mimeType(parameter);
  final originalUri = _davAttachment(account, parameter)?.uri;
  if (originalUri == null ||
      mimeType == null ||
      mimeType.startsWith('audio/')) {
    return null;
  }
  Future<void> openExternally() => _openDownloadedAttachment(
    context,
    ref,
    account: account,
    uri: originalUri,
    fileName: name,
    contentType: mimeType,
    expectedBytes: _attachmentExpectedBytes(parameter),
    repairUri: () => _repairedAttachmentUri(
      ref,
      account: account,
      roomToken: roomToken,
      messageId: messageId,
      index: index,
      failedUri: originalUri,
    ),
  );
  return isReadableText(mimeType)
      ? () => showTextAttachmentViewer(
          context,
          account: account,
          uri: originalUri,
          fileName: name,
          contentType: mimeType,
          repository: ref.read(chatMediaRepositoryProvider),
          onOpenExternally: () => unawaited(openExternally()),
        )
      : openExternally;
}

/// Forwards the file behind [parameter] into another conversation, when the
/// room offers it and Talk gave the file's own path.
VoidCallback? _forwardFileAction(
  BuildContext context,
  ChatRichObjectParameter parameter,
) {
  final forward = ChatContextMenuScope.forwardFileOf(context);
  final path = parameter.wire['path'];
  if (forward == null || path is! String || path.isEmpty) return null;
  return () => forward(path);
}
