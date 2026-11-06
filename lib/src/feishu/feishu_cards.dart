// Feishu interactive cards (JSON 2.0) and the action values their
// buttons carry.
//
// Only the *new* card callback (`card.action.trigger`, schema 2.0)
// can be delivered over the long connection — the old v1 callback
// cannot — so every card here is a 2.0 card:
//
//   {"schema":"2.0",
//    "header":{"template":"blue","title":{"tag":"plain_text","content":"…"}},
//    "body":{"elements":[ … ]}}
//
// A button carries a `value` (an object); the callback hands it back
// verbatim in `event.action.value`, which is how the router tells
// "bind to workspace X" from "run the pending command".
//
// Design doc §3.2 / §7 phase 2: the workspace picker is a card (not a
// text list) — buttons are far easier to hit on a phone.

/// The action names the router understands.
class CardActions {
  /// Bind this chat to the workspace carried by the value.
  static const String attach = 'attach';

  /// Drop the chat's binding — go back to the focused terminal.
  static const String detach = 'detach';

  /// Run the dangerous command held under the value's token.
  static const String confirm = 'confirm';

  /// Drop the held dangerous command.
  static const String cancel = 'cancel';

  /// Show another page of a long output.
  static const String page = 'page';

  const CardActions._();
}

/// The value a card button carries.
///
/// [action] is the action name; [extra] adds its arguments (a
/// workspace id, a token, a page number).
Map<String, dynamic> cardValue(String action, [Map<String, dynamic>? extra]) =>
    <String, dynamic>{'a': action, ...?extra};

/// One pickable target on a card — a workspace of the desktop app.
class CardTarget {
  final String id;
  final String name;

  /// Optional second line (the terminal's cwd, the tab title).
  final String? detail;

  const CardTarget(this.id, this.name, {this.detail});
}

/// A card with a title, a body and one row of buttons.
Map<String, dynamic> feishuCard({
  required String title,
  String? subtitle,
  String template = 'blue',
  List<Map<String, dynamic>> elements = const [],
}) =>
    {
      'schema': '2.0',
      'config': {'wide_screen_mode': true},
      'header': {
        'template': template,
        'title': {'tag': 'plain_text', 'content': title},
        if (subtitle case final subtitleText?) 'subtitle': {
            'tag': 'plain_text',
            'content': subtitleText,
          },
      },
      'body': {
        'elements': elements,
      },
    };

/// One button element.
Map<String, dynamic> cardButton({
  required String label,
  required Map<String, dynamic> value,
  String type = 'default',
}) =>
    {
      'tag': 'button',
      'text': {'tag': 'plain_text', 'content': label},
      'type': type,
      'value': value,
    };

/// The workspace picker: one button per workspace (design doc §3.2 —
/// "卡片会话选择器"). The currently bound one is highlighted.
Map<String, dynamic> workspaceSelectorCard(
  List<CardTarget> targets, {
  String? current,
  String title = 'Pick a workspace',
}) {
  final elements = <Map<String, dynamic>>[
    for (final target in targets)
      {
        'tag': 'action',
        'actions': [
          cardButton(
            label: target.detail == null
                ? target.name
                : '${target.name} · ${target.detail}',
            value: cardValue(CardActions.attach, {'id': target.id}),
            type: target.id == current ? 'primary' : 'default',
          ),
        ],
      },
  ];
  if (targets.isEmpty) {
    elements.add({
      'tag': 'div',
      'text': {'tag': 'lark_md', 'content': 'No workspaces yet.'},
    });
  }
  return feishuCard(title: title, elements: elements);
}

/// The dangerous-command confirmation card: the command is shown, and
/// the user must press "Run" before it is executed.
Map<String, dynamic> confirmCard({
  required String command,
  required String token,
  String title = 'Confirm a dangerous command',
}) =>
    feishuCard(
      title: title,
      template: 'orange',
      elements: [
        {
          'tag': 'div',
          'text': {
            'tag': 'lark_md',
            'content': 'Run this command?\n\n'
                '```\n$command\n```',
          },
        },
        {
          'tag': 'action',
          'actions': [
            cardButton(
              label: 'Run',
              value: cardValue(CardActions.confirm, {'t': token}),
              type: 'danger',
            ),
            cardButton(
              label: 'Cancel',
              value: cardValue(CardActions.cancel, {'t': token}),
            ),
          ],
        },
      ],
    );

/// The long-output pager: the output's page plus "prev / next"
/// buttons (design doc §5 — long outputs are navigated with card
/// buttons, not concatenated text).
Map<String, dynamic> pagerCard({
  required String token,
  required int page,
  required int pages,
  String? note,
}) {
  final elements = <Map<String, dynamic>>[
    if (note != null)
      {
        'tag': 'div',
        'text': {'tag': 'lark_md', 'content': note},
      },
    {
      'tag': 'action',
      'actions': [
        if (page > 0)
          cardButton(
            label: 'Previous',
            value: cardValue(CardActions.page, {'t': token, 'p': '${page - 1}'}),
          ),
        if (page < pages - 1)
          cardButton(
            label: 'Next',
            value: cardValue(CardActions.page, {'t': token, 'p': '${page + 1}'}),
            type: 'primary',
          ),
      ],
    },
  ];
  return feishuCard(
    title: 'Output',
    subtitle: 'page ${page + 1} / $pages',
    elements: elements,
  );
}

/// The toast shown when a card button is pressed (the callback
/// response body — it reaches the user as a popup on the card).
Map<String, dynamic> cardToast(String content, {String type = 'success'}) => {
      'toast': {'type': type, 'content': content},
    };
