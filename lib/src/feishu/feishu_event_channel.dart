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

  const FeishuInboundEvent({
    required this.senderOpenId,
    required this.chatId,
    required this.messageId,
    required this.text,
  });
}

enum FeishuConnectionState { disconnected, connecting, connected }

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
  Future<void> start(FeishuCredentials credentials) async {}

  @override
  Future<void> stop() async {}
}
