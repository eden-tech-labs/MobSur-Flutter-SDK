import 'package:flutter/material.dart';
import 'package:mobsur_flutter_sdk/mobsur_flutter_sdk.dart';

// flutter run --dart-define=MOBSUR_APP_ID=<your App ID>
const appId = String.fromEnvironment('MOBSUR_APP_ID', defaultValue: 'YOUR-APP-ID');
// Only for testing against a local MobSur server.
const baseUrl = String.fromEnvironment('MOBSUR_BASE_URL');

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MobSurSDK().setup(
    appId,
    null, // pass your signed-in user's ID when you have one
    debug: true,
    navigatorKey: navigatorKey,
    baseUrl: baseUrl.isEmpty ? null : Uri.parse(baseUrl),
  );
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MobSur example',
      navigatorKey: navigatorKey,
      theme: ThemeData(colorSchemeSeed: Colors.green),
      home: const EventPage(),
    );
  }
}

class EventPage extends StatefulWidget {
  const EventPage({super.key});

  @override
  State<EventPage> createState() => _EventPageState();
}

class _EventPageState extends State<EventPage> {
  final _event = TextEditingController(text: 'negative_id_feedback');

  @override
  void dispose() {
    _event.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surveys = MobSurSDK().availableSurveys() ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('MobSur example')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            controller: _event,
            decoration: const InputDecoration(labelText: 'Event name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => MobSurSDK().logEvent(_event.text.trim(), context),
            child: const Text('Send event'),
          ),
          const SizedBox(height: 24),
          Text('Surveys for this device: ${surveys.length}', style: Theme.of(context).textTheme.titleMedium),
          for (final survey in surveys)
            Text('#${survey.id} on ${survey.rules.map((rule) => rule.name).join(', ')}'),
          TextButton(onPressed: () => setState(() {}), child: const Text('Refresh this list')),
        ],
      ),
    );
  }
}
