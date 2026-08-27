import 'package:flutter/material.dart';

import '../../../data/app_database.dart';
import '../../../data/chat_media_repository.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'chat_image_exporter.dart';

const double _minimumScale = 1;
const double _maximumScale = 6;

Future<void> showAuthenticatedImageViewer(
  BuildContext context, {
  required StoredAccount account,
  required Uri previewUri,
  required Uri originalUri,
  required String originalContentType,
  required String imageName,
  required ChatMediaRepository repository,
  ChatImageExporter exporter = const PlatformChatImageExporter(),
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/chat/image'),
      fullscreenDialog: true,
      builder: (_) => AuthenticatedImageViewer(
        account: account,
        previewUri: previewUri,
        originalUri: originalUri,
        originalContentType: originalContentType,
        imageName: imageName,
        repository: repository,
        exporter: exporter,
      ),
    ),
  );
}

final class AuthenticatedImageViewer extends StatefulWidget {
  const AuthenticatedImageViewer({
    super.key,
    required this.account,
    required this.previewUri,
    required this.originalUri,
    required this.originalContentType,
    required this.imageName,
    required this.repository,
    this.exporter = const PlatformChatImageExporter(),
  });

  final StoredAccount account;
  final Uri previewUri;
  final Uri originalUri;
  final String originalContentType;
  final String imageName;
  final ChatMediaRepository repository;
  final ChatImageExporter exporter;

  @override
  State<AuthenticatedImageViewer> createState() =>
      _AuthenticatedImageViewerState();
}

final class _AuthenticatedImageViewerState
    extends State<AuthenticatedImageViewer> {
  final TransformationController _transformation = TransformationController();
  late Future<ChatMediaImage?> _image;
  double _scale = _minimumScale;
  Size? _viewport;

  /// Kept outside the [FutureBuilder] because the save and share buttons live
  /// in a sibling of it and have to enable themselves when the bytes arrive.
  ChatMediaImage? _loaded;
  ChatMediaFile? _original;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _image = _load();
  }

  @override
  void didUpdateWidget(covariant AuthenticatedImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id ||
        oldWidget.previewUri != widget.previewUri ||
        oldWidget.originalUri != widget.originalUri ||
        oldWidget.originalContentType != widget.originalContentType ||
        !identical(oldWidget.repository, widget.repository)) {
      _resetTransformation();
      _original = null;
      _image = _load();
    }
  }

  @override
  void dispose() {
    _transformation.dispose();
    super.dispose();
  }

  Future<ChatMediaImage?> _load() async {
    ChatMediaImage? image;
    try {
      image = await widget.repository.loadPreview(
        account: widget.account,
        uri: widget.previewUri,
      );
      return image;
    } finally {
      if (mounted) {
        setState(() {
          _loaded = image;
        });
      }
    }
  }

  void _retry() {
    setState(() {
      _loaded = null;
      _image = _load();
    });
  }

  Future<void> _saveToGallery() async {
    await _export((image, strings) async {
      final result = await widget.exporter.saveToGallery(
        bytes: image.body,
        fileName: chatImageBaseName(widget.imageName),
        contentType: image.contentType,
      );
      return switch (result) {
        ChatImageSaveResult.saved => strings.imageSavedToGallery,
        // A refusal must be spoken out, never swallowed: the picture simply
        // not appearing in the gallery reads as a broken app.
        ChatImageSaveResult.permissionDenied =>
          strings.imageSavePermissionDenied,
        ChatImageSaveResult.outOfSpace => strings.imageSaveOutOfSpace,
        ChatImageSaveResult.failed => strings.imageSaveFailed,
      };
    }, failureMessage: (strings) => strings.imageSaveFailed);
  }

  Future<void> _share() async {
    await _export((image, strings) async {
      final offered = await widget.exporter.share(
        bytes: image.body,
        fileName: chatImageBaseName(widget.imageName),
        contentType: image.contentType,
      );
      return offered ? null : strings.imageShareFailed;
    }, failureMessage: (strings) => strings.imageShareFailed);
  }

  Future<void> _export(
    Future<String?> Function(ChatMediaFile image, AppLocalizations strings)
    run, {
    required String Function(AppLocalizations strings) failureMessage,
  }) async {
    if (_loaded == null || _exporting) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _exporting = true;
    });
    String? message;
    try {
      final image = _original ??= await widget.repository.loadOriginalFile(
        account: widget.account,
        uri: widget.originalUri,
        expectedContentType: widget.originalContentType,
      );
      message = await run(image, strings);
    } on Object {
      message = failureMessage(strings);
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
        });
      }
    }
    if (message != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  void _zoomBy(double factor) {
    final current = _transformation.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(_minimumScale, _maximumScale);
    if ((target - current).abs() < 0.001) {
      return;
    }
    final ratio = target / current;
    // Scaling the matrix on its own zooms around the child origin, which walks
    // the picture out of the viewport. The button zoom has no pointer, so the
    // viewport centre is the anchor.
    final viewport = _viewport;
    final anchorX = (viewport?.width ?? 0) / 2;
    final anchorY = (viewport?.height ?? 0) / 2;
    final zoom = Matrix4.identity()
      ..translateByDouble(anchorX, anchorY, 0, 1)
      ..scaleByDouble(ratio, ratio, 1, 1)
      ..translateByDouble(-anchorX, -anchorY, 0, 1);
    _transformation.value = zoom * _transformation.value;
    setState(() {
      _scale = target;
    });
  }

  void _resetTransformation() {
    final matrix = _transformation.value.clone()..setIdentity();
    _transformation.value = matrix;
    _scale = _minimumScale;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: const Key('authenticated-image-viewer'),
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<ChatMediaImage?>(
            future: _image,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return Semantics(
                  liveRegion: true,
                  label: strings.loadingImage,
                  child: const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                );
              }
              final image = snapshot.data;
              if (snapshot.hasError || image == null) {
                return _ImageLoadFailure(onRetry: _retry);
              }
              return Semantics(
                image: true,
                label: widget.imageName,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _viewport = constraints.biggest;
                    return InteractiveViewer(
                      key: const Key('authenticated-image-interactive-viewer'),
                      transformationController: _transformation,
                      minScale: _minimumScale,
                      maxScale: _maximumScale,
                      onInteractionUpdate: (_) {
                        final next = _transformation.value.getMaxScaleOnAxis();
                        if ((next - _scale).abs() >= 0.01 && mounted) {
                          setState(() {
                            _scale = next;
                          });
                        }
                      },
                      child: SizedBox.expand(
                        child: Center(
                          child: Image.memory(
                            image.body,
                            key: const Key('authenticated-image-fullscreen'),
                            cacheWidth: 2048,
                            cacheHeight: 2048,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) =>
                                _ImageLoadFailure(onRetry: _retry),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
          SafeArea(
            minimum: const EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.topRight,
              child: _ViewerIconButton(
                key: const Key('authenticated-image-close'),
                tooltip: strings.close,
                icon: Icons.close_rounded,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Material(
                color: const Color(0xcc000000),
                borderRadius: BorderRadius.circular(28),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    _ViewerIconButton(
                      key: const Key('authenticated-image-zoom-out'),
                      tooltip: strings.zoomOut,
                      icon: Icons.remove_rounded,
                      onPressed: _scale <= _minimumScale + 0.001
                          ? null
                          : () => _zoomBy(0.8),
                    ),
                    _ViewerIconButton(
                      key: const Key('authenticated-image-reset-zoom'),
                      tooltip: strings.resetZoom,
                      icon: Icons.center_focus_strong_rounded,
                      onPressed: _scale <= _minimumScale + 0.001
                          ? null
                          : () {
                              setState(_resetTransformation);
                            },
                    ),
                    _ViewerIconButton(
                      key: const Key('authenticated-image-zoom-in'),
                      tooltip: strings.zoomIn,
                      icon: Icons.add_rounded,
                      onPressed: _scale >= _maximumScale - 0.001
                          ? null
                          : () => _zoomBy(1.25),
                    ),
                    _ViewerIconButton(
                      key: const Key('authenticated-image-save'),
                      tooltip: strings.saveImage,
                      icon: Icons.download_rounded,
                      onPressed: _loaded == null || _exporting
                          ? null
                          : _saveToGallery,
                    ),
                    _ViewerIconButton(
                      key: const Key('authenticated-image-share'),
                      tooltip: strings.shareImage,
                      icon: Icons.share_rounded,
                      onPressed: _loaded == null || _exporting ? null : _share,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _ImageLoadFailure extends StatelessWidget {
  const _ImageLoadFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Semantics(
      liveRegion: true,
      label: strings.imageLoadFailed,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.broken_image_outlined,
                color: Colors.white,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                strings.imageLoadFailed,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('authenticated-image-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(strings.retry),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ViewerIconButton extends StatelessWidget {
  const _ViewerIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      color: Colors.white,
      disabledColor: const Color(0xff8c8c8c),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      icon: Icon(icon),
    );
  }
}
