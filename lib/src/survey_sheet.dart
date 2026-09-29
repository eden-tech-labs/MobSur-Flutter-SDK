import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'engine.dart';
import 'models.dart';

Future<void> showSurveySheet(
  BuildContext context,
  Survey survey, {
  required VoidCallback onCompleted,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => SurveySheet(survey: survey, onCompleted: onCompleted),
  );
}

class SurveySheet extends StatefulWidget {
  const SurveySheet({super.key, required this.survey, required this.onCompleted});

  final Survey survey;
  final VoidCallback onCompleted;

  @override
  State<SurveySheet> createState() => _SurveySheetState();
}

class _SurveySheetState extends State<SurveySheet> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _failed = false;
  bool _completed = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          if (SurveyEngine.isCloseUrl(request.url)) {
            _finish();
            return NavigationDecision.prevent;
          }
          _checkSuccess(request.url);
          return NavigationDecision.navigate;
        },
        // Same-document changes such as `#close` don't always produce a
        // navigation request, but they do change the URL.
        onUrlChange: (change) {
          final url = change.url;
          if (url == null) return;
          SurveyEngine.isCloseUrl(url) ? _finish() : _checkSuccess(url);
        },
        onPageFinished: (url) {
          _checkSuccess(url);
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (error) {
          if ((error.isForMainFrame ?? true) && mounted) {
            setState(() {
              _loading = false;
              _failed = true;
            });
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.survey.url));
  }

  void _checkSuccess(String url) {
    if (SurveyEngine.isSuccessUrl(url)) _markCompleted();
  }

  void _markCompleted() {
    if (_completed) return;
    _completed = true;
    widget.onCompleted();
  }

  void _finish() {
    _markCompleted();
    _close();
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.9,
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              icon: const Icon(Icons.close),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: _close,
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                if (!_failed)
                  WebViewWidget(
                    controller: _controller,
                    gestureRecognizers: {
                      Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
                    },
                  ),
                if (_loading) const Center(child: CircularProgressIndicator()),
                if (_failed)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child:
                          Text('This survey couldn’t be loaded. Please try again later.', textAlign: TextAlign.center),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
