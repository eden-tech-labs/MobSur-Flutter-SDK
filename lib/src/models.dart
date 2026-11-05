import 'dart:convert';

/// How many times an event must have happened for a rule to match.
///
/// A missing [min] means 1. A missing [max] means no upper limit.
class SurveyOccurrence {
  const SurveyOccurrence({this.min, this.max});

  final int? min;
  final int? max;

  static SurveyOccurrence? tryParse(Object? json) {
    if (json is! Map) return null;
    return SurveyOccurrence(min: _int(json['min']), max: _int(json['max']));
  }

  Map<String, Object?> toJson() => {'min': min, 'max': max};
}

/// A rule that decides when a survey is shown.
class SurveyRule {
  const SurveyRule({
    required this.type,
    required this.name,
    this.occurred,
    this.delay = 0,
  });

  /// The only rule type the dashboard creates.
  static const String countedEvent = 'counted_event';

  final String type;

  /// The app event name, matched exactly.
  final String name;

  final SurveyOccurrence? occurred;

  /// Milliseconds to wait between the event and showing the survey.
  final int delay;

  bool get isCountedEvent => type == countedEvent;

  /// Whether the [count]th occurrence of the event falls inside this rule's window.
  bool allows(int count) {
    final min = occurred?.min ?? 1;
    final max = occurred?.max;
    return count >= min && (max == null || count <= max);
  }

  static SurveyRule? tryParse(Object? json) {
    if (json is! Map) return null;
    final type = json['type'];
    final name = json['name'];
    if (type is! String || name is! String) return null;
    final delay = _int(json['delay']) ?? 0;
    return SurveyRule(
      type: type,
      name: name,
      occurred: SurveyOccurrence.tryParse(json['occurred']),
      delay: delay < 0 ? 0 : delay,
    );
  }

  Map<String, Object?> toJson() => {
        'type': type,
        'name': name,
        'occurred': occurred?.toJson(),
        'delay': delay,
      };
}

/// A survey the server made available to the current user.
class Survey {
  const Survey({
    required this.id,
    required this.url,
    this.startDate,
    this.endDate,
    this.rules = const [],
  });

  final int id;

  /// The survey page. Open it unmodified.
  final String url;

  /// `null` when the survey has no start bound.
  final DateTime? startDate;

  /// `null` when the survey is open-ended.
  final DateTime? endDate;

  final List<SurveyRule> rules;

  bool isActiveAt(DateTime now) =>
      (startDate == null || !now.isBefore(startDate!)) && (endDate == null || now.isBefore(endDate!));

  /// Returns `null` for an entry that can't be used, so one bad survey never
  /// hides the others.
  static Survey? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = _int(json['id']);
    final url = json['url'];
    if (id == null || url is! String || url.isEmpty) return null;
    final (startValid, start) = _date(json['start_date']);
    final (endValid, end) = _date(json['end_date']);
    if (!startValid || !endValid) return null;
    final rawRules = json['rules'];
    return Survey(
      id: id,
      url: url,
      startDate: start,
      endDate: end,
      rules: rawRules is List ? rawRules.map(SurveyRule.tryParse).whereType<SurveyRule>().toList() : const [],
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'url': url,
        'start_date': startDate?.toUtc().toIso8601String(),
        'end_date': endDate?.toUtc().toIso8601String(),
        'rules': rules.map((rule) => rule.toJson()).toList(),
      };
}

/// Parses the body of `GET /api/surveys`, keeping the server's priority order.
///
/// Returns `null` when the body isn't the expected JSON document, for example
/// a captive portal's HTML page.
List<Survey>? parseSurveyList(String body) {
  try {
    final json = jsonDecode(body);
    final data = json is Map ? json['data'] : null;
    if (data is! List) return null;
    return data.map(Survey.tryParse).whereType<Survey>().toList();
  } on FormatException {
    return null;
  }
}

/// The in-app message a `treatment` arm shows.
class ExperimentMessage {
  const ExperimentMessage({
    required this.title,
    this.body = '',
    required this.ctaLabel,
    required this.ctaAction,
    this.dismissLabel,
    this.imageUrl,
  });

  final String title;
  final String body;
  final String ctaLabel;

  /// Passed to the `onAction` callback given to `setup`, or opened as a URL.
  final String ctaAction;

  /// `null` uses the platform's localized "Close" label.
  final String? dismissLabel;
  final String? imageUrl;

  static ExperimentMessage? tryParse(Object? json) {
    if (json is! Map) return null;
    final title = _text(json['title']);
    final ctaLabel = _text(json['cta_label']);
    final ctaAction = _text(json['cta_action']);
    if (title == null || ctaLabel == null || ctaAction == null) return null;
    return ExperimentMessage(
      title: title,
      body: _text(json['body']) ?? '',
      ctaLabel: ctaLabel,
      ctaAction: ctaAction,
      dismissLabel: _text(json['dismiss_label']),
      imageUrl: _text(json['image_url']),
    );
  }

  Map<String, Object?> toJson() => {
        'title': title,
        'body': body,
        'cta_label': ctaLabel,
        'cta_action': ctaAction,
        'dismiss_label': dismissLabel,
        'image_url': imageUrl,
      };
}

/// An in-app message experiment the server assigned the current user to.
///
/// In the `treatment` arm the [message] is shown; in the `control` arm nothing
/// is shown, but the exposure is still reported.
class Experiment {
  const Experiment({
    required this.id,
    required this.arm,
    this.startDate,
    this.endDate,
    this.rules = const [],
    this.message,
  });

  static const String treatment = 'treatment';
  static const String control = 'control';

  final String id;

  /// [treatment] or [control].
  final String arm;
  final DateTime? startDate;
  final DateTime? endDate;
  final List<SurveyRule> rules;

  /// Always set for [treatment], always `null` for [control].
  final ExperimentMessage? message;

  bool get isControl => arm == control;

  bool isActiveAt(DateTime now) =>
      (startDate == null || !now.isBefore(startDate!)) && (endDate == null || now.isBefore(endDate!));

  /// Returns `null` for an entry that can't be used, so one bad experiment
  /// never hides the others.
  static Experiment? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = _text(json['id']);
    final arm = json['arm'];
    if (id == null || (arm != treatment && arm != control)) return null;
    final (startValid, start) = _date(json['start_date']);
    final (endValid, end) = _date(json['end_date']);
    if (!startValid || !endValid) return null;
    final message = arm == treatment ? ExperimentMessage.tryParse(json['message']) : null;
    if (arm == treatment && message == null) return null;
    final rawRules = json['rules'];
    return Experiment(
      id: id,
      arm: arm as String,
      startDate: start,
      endDate: end,
      rules: rawRules is List ? rawRules.map(SurveyRule.tryParse).whereType<SurveyRule>().toList() : const [],
      message: message,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'arm': arm,
        'start_date': startDate?.toUtc().toIso8601String(),
        'end_date': endDate?.toUtc().toIso8601String(),
        'rules': rules.map((rule) => rule.toJson()).toList(),
        'message': message?.toJson(),
      };
}

/// Parses the `experiments` key of `GET /api/surveys`, keeping server order.
///
/// A missing or malformed key means no experiments (older servers don't send
/// it). Returns `null` only when the body isn't the expected JSON document.
List<Experiment>? parseExperimentList(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! Map || json['data'] is! List) return null;
    final experiments = json['experiments'];
    if (experiments is! List) return const [];
    return experiments.map(Experiment.tryParse).whereType<Experiment>().toList();
  } on FormatException {
    return null;
  }
}

String? _text(Object? value) => value is String && value.trim().isNotEmpty ? value : null;

/// `null` is a valid, open bound. Anything else must be an ISO-8601 string.
(bool, DateTime?) _date(Object? value) {
  if (value == null) return (true, null);
  final parsed = value is String ? DateTime.tryParse(value) : null;
  return (parsed != null, parsed);
}

int? _int(Object? value) => value is num ? value.toInt() : null;
