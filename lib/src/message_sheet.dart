import 'package:flutter/material.dart';

import 'models.dart';

/// Shows an experiment's message in a modal bottom sheet styled by the host
/// app's theme. Completes with `true` when the person tapped the call to
/// action, and `false` when they dismissed the sheet any other way (the
/// dismiss button, a swipe, the back button or a tap outside).
///
/// [onCtaTapped] runs on the tap, before the sheet closes.
Future<bool> showExperimentSheet(
  BuildContext context,
  ExperimentMessage message, {
  required VoidCallback onCtaTapped,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ExperimentSheet(message: message, onCtaTapped: onCtaTapped),
  );
  return result ?? false;
}

class ExperimentSheet extends StatelessWidget {
  const ExperimentSheet({super.key, required this.message, required this.onCtaTapped});

  final ExperimentMessage message;
  final VoidCallback onCtaTapped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageUrl = message.imageUrl;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (imageUrl != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          Text(message.title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
          if (message.body.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(message.body, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () {
              if (!_isOpen(context)) return;
              onCtaTapped();
              Navigator.of(context).pop(true);
            },
            child: Text(message.ctaLabel),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              if (_isOpen(context)) Navigator.of(context).pop(false);
            },
            child: Text(message.dismissLabel ?? MaterialLocalizations.of(context).closeButtonLabel),
          ),
        ],
      ),
    );
  }

  // A second tap during the closing animation must not pop the host's route.
  static bool _isOpen(BuildContext context) => ModalRoute.of(context)?.isCurrent ?? false;
}
