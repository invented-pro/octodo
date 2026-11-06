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

/// The callback's immediate response body (design doc §1.2, mode A —
/// answered within the 3 s window). [card] replaces the card in
/// place (`{type: raw, data: …}` per the callback protocol); [toast]
/// pops a toast. Both are optional; neither means "leave the card
/// unchanged".
Map<String, dynamic> cardResponse({
  Map<String, dynamic>? card,
  Map<String, dynamic>? toast,
}) =>
    {
      if (card != null)
        'card': {
          'type': 'raw',
          'data': card,
        },
      'toast': ?toast,
    };

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
      // `update_multi` lets the card be updated again after it is
      // sent — the pager, the picker and the confirmation card all
      // rely on in-place updates (§1.2).
      'config': {'wide_screen_mode': true, 'update_multi': true},
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
  bool disabled = false,
}) =>
    {
      'tag': 'button',
      'text': {'tag': 'plain_text', 'content': label},
      'type': type,
      'value': value,
      if (disabled) 'disabled': true,
    };

/// The workspace picker: one button per workspace (design doc §3.2 —
/// "卡片会话选择器"). The currently bound one is marked and disabled
/// (§3.1 — no double binding), and a chat that is bound gets an
/// unbind button.
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
            label: target.id == current
                ? '${target.name} · current'
                : (target.detail == null
                    ? target.name
                    : '${target.name} · ${target.detail}'),
            value: cardValue(CardActions.attach, {'id': target.id}),
            type: target.id == current ? 'primary' : 'default',
            disabled: target.id == current,
          ),
        ],
      },
    if (targets.isEmpty)
      {
        'tag': 'div',
        'text': {'tag': 'lark_md', 'content': 'No workspaces yet.'},
      },
    if (current != null)
      {
        'tag': 'action',
        'actions': [
          cardButton(
            label: 'Unbind — follow the active workspace',
            value: cardValue(CardActions.detach),
          ),
        ],
      },
  ];
  return feishuCard(title: title, elements: elements);
}

/// The dangerous-command confirmation card: the command is shown,
/// and the user picks Run once / Always / Cancel (§4.1). The buttons
/// carry the token, never the command itself.
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
              label: 'Run once',
              value: cardValue(CardActions.confirm,
                  {'t': token, 'd': 'once'}),
              type: 'danger',
            ),
            cardButton(
              label: 'Always in this workspace',
              value: cardValue(CardActions.confirm,
                  {'t': token, 'd': 'always'}),
            ),
            cardButton(
              label: 'Cancel',
              value: cardValue(CardActions.cancel, {'t': token}),
            ),
          ],
        },
      ],
    );

/// The terminal state of an approval (§4.2): the confirmation card is
/// replaced by the outcome via a deferred update — no buttons left to
/// press.
Map<String, dynamic> approvalDoneCard({
  required String command,
  required String outcome,
  String template = 'green',
}) =>
    feishuCard(
      title: outcome,
      template: template,
      elements: [
        {
          'tag': 'div',
          'text': {
            'tag': 'lark_md',
            'content': '```\n$command\n```',
          },
        },
      ],
    );

/// The long-output pager: the page's content (plain text, §2.1) plus
/// "prev / next" buttons (design doc §5 — long outputs are navigated
/// with card buttons, not concatenated text). Pressing one returns
/// this card with the new page — the card is replaced in place.
Map<String, dynamic> pagerCard({
  required String token,
  required int page,
  required int pages,
  required String content,
}) {
  final elements = <Map<String, dynamic>>[
    {
      'tag': 'div',
      'text': {'tag': 'plain_text', 'content': content},
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
Map<String, dynamic> cardToast(String content, {String type = 'success'}) =>
    {'toast': feishuToast(content, type: type)};

/// The inner toast map — [cardToast] wraps it as a whole response
/// body; [cardResponse] takes it directly.
Map<String, dynamic> feishuToast(String content, {String type = 'success'}) =>
    {'type': type, 'content': content};
