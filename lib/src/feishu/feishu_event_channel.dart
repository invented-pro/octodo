// The event-channel seam for phase 2 (design doc §1 / §4): the
// Feishu WebSocket long connection that receives
// `im.message.receive_v1` events and card callbacks.
//
// Phase 1 ships only the contract + an idle implementation, so the
// wiring shape (who starts/stops the channel, what an inbound
// message looks like) is settled now and the WS transport drops in
// later without touching the binding flow or the settings UI.
//
// Phase-2 responsibilities documented on the interface:
//   * whitelist check at the event entry (§4.2)
//   * 3-second ack + async queueing (§4.3)
//   * message_id sliding-window dedup (§4.3)

import 'dart:async';

import 'feishu_credentials.dart';

/// A normalized inbound bot message. Only fields phase 2 needs to
/// route and gate the event — transport details (frame format,
/// protobuf vs JSON, pong bookkeeping) stay inside the channel.
class FeishuInboundEvent {
  /// `ou_…` sender identity — the whitelist key (§4.2).
  final String senderOpenId;

  /// `oc_…` / `om_…` conversation / message id used for dedup.
  final String chatId;
  final String messageId;

  /// Message content; text messages arrive as a JSON payload with
  /// a `text` field — the channel decodes it before emitting.
  final String text;

  const FeishuInboundEvent({
    required this.senderOpenId,
    required this.chatId,
    required this.messageId,
    required this.text,
  });
}

/// Long-connection transport contract. Implementations must:
///   * start/stop idempotently,
///   * never let a transport error escape into the caller (log +
///     surface state instead; the terminal core must not notice,
///     §6 "runtime isolation"),
///   * reconnect with backoff until [stop] is called.
abstract class FeishuEventChannel {
  /// Whether the channel currently holds a live connection.
  ValueObservableConnection get connectionState;

  /// Inbound events (already deduped, not yet allowlisted — the
  /// router above the channel owns the whitelist decision).
  Stream<FeishuInboundEvent> get events;

  /// Connect using [credentials]. Resolves once the channel is
  /// starting (not necessarily connected).
  Future<void> start(FeishuCredentials credentials);

  /// Close the connection and pending work. Safe to call when
  /// never started.
  Future<void> stop();
}

/// Connection state surfaced to the UI (settings badge, future
/// status chip).
enum FeishuConnectionState { disconnected, connecting, connected }

class ValueObservableConnection {
  final Stream<FeishuConnectionState> changes;
  final FeishuConnectionState current;
  const ValueObservableConnection(this.changes, this.current);
}

/// Phase-1 placeholder: no transport, never connects, emits
/// nothing. Swapped for the WebSocket implementation in phase 2.
class IdleFeishuEventChannel implements FeishuEventChannel {
  @override
  ValueObservableConnection get connectionState => const ValueObservableConnection(
    Stream.empty(),
    FeishuConnectionState.disconnected,
  );

  @override
  Stream<FeishuInboundEvent> get events => const Stream.empty();

  @override
  Future<void> start(FeishuCredentials credentials) async {}

  @override
  Future<void> stop() async {}
}
