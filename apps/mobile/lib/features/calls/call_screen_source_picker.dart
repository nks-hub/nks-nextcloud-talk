import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import 'call_media_engine.dart';

final class CallScreenSourcePicker extends StatefulWidget {
  const CallScreenSourcePicker({super.key, required this.loadSources});

  final Future<List<CallScreenSource>> Function() loadSources;

  @override
  State<CallScreenSourcePicker> createState() => _CallScreenSourcePickerState();
}

final class _CallScreenSourcePickerState extends State<CallScreenSourcePicker> {
  late Future<List<CallScreenSource>> _sources;
  CallScreenSource? _selection;

  @override
  void initState() {
    super.initState();
    _sources = Future.sync(widget.loadSources);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(strings.callBannerShareScreen),
      content: SizedBox(
        width: 480,
        height: 320,
        child: FutureBuilder<List<CallScreenSource>>(
          future: _sources,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: CircularProgressIndicator(
                  key: Key('call-screen-source-loading'),
                ),
              );
            }
            final sources = snapshot.data;
            if (snapshot.hasError || sources == null || sources.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      strings.conversationActionErrorGeneric,
                      key: const Key('call-screen-source-error'),
                    ),
                    TextButton(
                      key: const Key('call-screen-source-retry'),
                      onPressed: () => setState(() {
                        _selection = null;
                        _sources = Future.sync(widget.loadSources);
                      }),
                      child: Text(strings.retry),
                    ),
                  ],
                ),
              );
            }
            return RadioGroup<String>(
              groupValue: _selection?.id,
              onChanged: (id) => setState(() {
                _selection = id == null
                    ? null
                    : sources.firstWhere((source) => source.id == id);
              }),
              child: ListView.builder(
                primary: false,
                itemCount: sources.length,
                itemBuilder: (context, index) {
                  final source = sources[index];
                  final icon = source.isWindow
                      ? Icons.web_asset_rounded
                      : Icons.monitor_rounded;
                  final thumbnail = source.thumbnail;
                  return RadioListTile<String>(
                    key: ValueKey('call-screen-source-${source.id}'),
                    value: source.id,
                    title: Text(source.name),
                    secondary: thumbnail == null
                        ? Icon(icon)
                        : Image.memory(
                            thumbnail,
                            width: 72,
                            height: 40,
                            fit: BoxFit.contain,
                            excludeFromSemantics: true,
                            errorBuilder: (_, _, _) => Icon(icon),
                          ),
                  );
                },
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('call-screen-source-confirm'),
          onPressed: _selection == null
              ? null
              : () => Navigator.pop(context, _selection),
          child: Text(strings.callBannerShareScreen),
        ),
      ],
    );
  }
}
