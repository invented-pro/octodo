// The event-channel seam for the Feishu WebSocket long connection
// (design doc §1 / §4): receives `im.message.receive_v1` events.
//
// Responsibilities documented on the interface (phase 2):
//   * whitelist check at the event entry (§4.2) — owned by the
//     router above the channel (FeishuIntegration), not here
//   * 3-second ack + async queueing (§4.3) — the channel acks each
//     frame immediately and emits on a broadcast stream
//   * message_id sliding-window dedup (§4.3) — also the router's

import 'dart:async';

import 'feishu_credentials.dart';

/// A normalized inbound bot message.
class FeishuInboundEvent {
  /// `ou_…` sender identity — the whitelist key (§4.2).
  final String senderOpenId;

  /// `oc_…` conversation the message arrived in.
  final String chatId;

  /// `om_…` message id used for dedup.
  final String messageId;

  /// Plain text for `text` messages; empty for other message types
  /// (images, files, post, …) which the router drops.
  final String text;

  /// Message creation time on Feishu's server, milliseconds since
  /// epoch (`message.create_time`). 0 when the field is absent.
  /// The router replays nothing older than the dedup window —
  /// Feishu redelivers every event it never saw acked, including
  /// the whole backlog queued while no client was connected.
  final int createTime;

  const FeishuInboundEvent({
    required this.senderOpenId,
    required this.chatId,
    required this.messageId,
    required this.text,
    this.createTime = 0,
  });
}

enum FeishuConnectionState { disconnected, connecting, connected }

/// A card button press — the `card.action.trigger` callback (design
/// doc §7, phase 2).
///
/// Only the *new* callback (schema 2.0) can be delivered over the
/// long connection; the old v1 callback cannot.
class FeishuCardActionEvent {
  /// `ou_…` of the operator who pressed the button — the whitelist
  /// key (§4.2), same as for a message.
  final String operatorOpenId;

  /// The chat the card lives in — the reply goes there.
  final String chatId;

  /// The card's message id (`om_…`) — needed to update the card in
  /// place.
  final String messageId;

  /// The card-update token: valid for 30 minutes, up to 2 updates.
  final String token;

  /// The developer-defined value of the pressed component — what the
  /// card put there (see `feishu_cards.dart`).
  final Map<String, dynamic> value;

  /// The action name carried by [value] ('attach', 'confirm', …).
  String get action => (value['a'] as String?) ?? '';

  const FeishuCardActionEvent({
    required this.operatorOpenId,
    required this.chatId,
    required this.messageId,
    required this.token,
    required this.value,
  });
}

/// Long-connection transport contract. Implementations must:
///   * start/stop idempotently,
///   * never let a transport error escape into the caller (log +
///     surface state instead; the terminal core must not notice,
///     §6 "runtime isolation"),
///   * reconnect with backoff until [stop] is called.
abstract class FeishuEventChannel {
  /// Broadcast stream of connection-state changes.
  Stream<FeishuConnectionState> get stateChanges;

  /// Current connection state.
  FeishuConnectionState get currentState;

  /// Inbound events (already deduped, not yet allowlisted — the
  /// router above the channel owns the whitelist decision).
  Stream<FeishuInboundEvent> get events;

  /// Card button presses (`card.action.trigger`) — phase 2.
  ///
  /// The answer to a press must reach Feishu within 3 s, so the
  /// channel answers it itself: it asks whoever handles
  /// [cardActionHandler] and sends the reply back in the frame's
  /// `data` field.
  Stream<FeishuCardActionEvent> get cardActions;

  /// Answers a card press with the body to send back — a toast, an
  /// updated card, or null to keep the card unchanged. Set by the
  /// router.
  Future<Map<String, dynamic>?> Function(FeishuCardActionEvent)?
      get cardActionHandler;
  set cardActionHandler(
      Future<Map<String, dynamic>?> Function(FeishuCardActionEvent)? value);

  /// Connect using [credentials]. Resolves once the channel is
  /// starting (not necessarily connected).
  Future<void> start(FeishuCredentials credentials);

  /// Close the connection and pending work. Safe to call when
  /// never started.
  Future<void> stop();
}

/// Placeholder used before any binding exists: no transport, never
/// connects, emits nothing.
class IdleFeishuEventChannel implements FeishuEventChannel {
  @override
  Stream<FeishuConnectionState> get stateChanges => const Stream.empty();

  @override
  FeishuConnectionState get currentState => FeishuConnectionState.disconnected;

  @override
  Stream<FeishuInboundEvent> get events => const Stream.empty();

  @override
  Stream<FeishuCardActionEvent> get cardActions => const Stream.empty();

  @override
  Future<Map<String, dynamic>?> Function(FeishuCardActionEvent)?
      get cardActionHandler => null;

  @override
  set cardActionHandler(
      Future<Map<String, dynamic>?> Function(FeishuCardActionEvent)? value) {}

  @override
  Future<void> start(FeishuCredentials credentials) async {}

  @override
  Future<void> stop() async {}
}
