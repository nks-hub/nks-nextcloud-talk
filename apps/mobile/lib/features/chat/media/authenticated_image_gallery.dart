import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/app_database.dart';
import '../../../data/chat_media_repository.dart';
import 'authenticated_image_viewer.dart';
import 'chat_image_exporter.dart';

final class ChatGalleryImage {
  const ChatGalleryImage({
    required this.previewUri,
    required this.originalUri,
    required this.contentType,
    required this.name,
    this.smallerPreviewUri,
  });

  final Uri previewUri;
  final Uri? smallerPreviewUri;
  final Uri originalUri;
  final String contentType;
  final String name;
}

Future<void> showAuthenticatedImageGallery(
  BuildContext context, {
  required StoredAccount account,
  required List<ChatGalleryImage> images,
  required int initialIndex,
  required ChatMediaRepository repository,
  Future<bool> Function()? openAppSettings,
  ValueChanged<int>? onImageActions,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/chat/gallery'),
    fullscreenDialog: true,
    builder: (_) => AuthenticatedImageGallery(
      account: account,
      images: images,
      initialIndex: initialIndex,
      repository: repository,
      openAppSettings: openAppSettings,
      onImageActions: onImageActions,
    ),
  ),
);

final class AuthenticatedImageGallery extends StatefulWidget {
  AuthenticatedImageGallery({
    super.key,
    required this.account,
    required List<ChatGalleryImage> images,
    required this.initialIndex,
    required this.repository,
    this.exporter = const PlatformChatImageExporter(),
    this.openAppSettings,
    this.onImageActions,
  }) : images = List.unmodifiable(images) {
    RangeError.checkValidIndex(initialIndex, images, 'initialIndex');
  }

  final StoredAccount account;
  final List<ChatGalleryImage> images;
  final int initialIndex;
  final ChatMediaRepository repository;
  final ChatImageExporter exporter;
  final Future<bool> Function()? openAppSettings;
  final ValueChanged<int>? onImageActions;

  @override
  State<AuthenticatedImageGallery> createState() =>
      _AuthenticatedImageGalleryState();
}

final class _AuthenticatedImageGalleryState
    extends State<AuthenticatedImageGallery> {
  late final PageController _pages;
  late int _index;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= widget.images.length) return;
    unawaited(
      _pages.animateToPage(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = MaterialLocalizations.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(Navigator.of(context).maybePop()),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(1),
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          textDirection: TextDirection.ltr,
          children: [
            PageView.builder(
              key: const Key('chat-gallery-pages'),
              controller: _pages,
              physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
              itemCount: widget.images.length,
              onPageChanged: (index) => setState(() {
                _index = index;
                _zoomed = false;
              }),
              itemBuilder: (context, index) {
                final image = widget.images[index];
                return AuthenticatedImageViewer(
                  autofocus: false,
                  key: ValueKey(image.originalUri),
                  account: widget.account,
                  previewUri: image.previewUri,
                  smallerPreviewUri: image.smallerPreviewUri,
                  originalUri: image.originalUri,
                  originalContentType: image.contentType,
                  imageName: image.name,
                  repository: widget.repository,
                  exporter: widget.exporter,
                  openAppSettings: widget.openAppSettings,
                  onZoomChanged: (zoomed) {
                    if (index == _index && _zoomed != zoomed) {
                      setState(() => _zoomed = zoomed);
                    }
                  },
                );
              },
            ),
            SafeArea(
              minimum: const EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.topLeft,
                child: Material(
                  color: const Color(0xcc000000),
                  borderRadius: BorderRadius.circular(28),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onImageActions != null)
                        IconButton(
                          key: const Key('chat-gallery-actions'),
                          tooltip: strings.showMenuTooltip,
                          color: Colors.white,
                          onPressed: () => widget.onImageActions!(_index),
                          icon: const Icon(Icons.more_vert),
                        ),
                      IconButton(
                        key: const Key('chat-gallery-previous'),
                        tooltip: strings.previousPageTooltip,
                        color: Colors.white,
                        disabledColor: Colors.white38,
                        onPressed: _index == 0 ? null : () => _move(-1),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text(
                        '${_index + 1} / ${widget.images.length}',
                        key: const Key('chat-gallery-position'),
                        style: const TextStyle(color: Colors.white),
                      ),
                      IconButton(
                        key: const Key('chat-gallery-next'),
                        tooltip: strings.nextPageTooltip,
                        color: Colors.white,
                        disabledColor: Colors.white38,
                        onPressed: _index == widget.images.length - 1
                            ? null
                            : () => _move(1),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
