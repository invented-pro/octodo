// The pbbp2 wire frames of Feishu's long connection: protobuf
// messages `Frame` and `Header` exactly as the official SDKs define
// them (field numbers and proto2 "required" semantics — scalar
// fields are written even when zero). Hand-rolled varint coding so
// the app takes no protobuf dependency for four scalar fields and
// three strings.
//
// Verified against the reference vector from the official SDKs:
//   Frame(seq:0, log:0, service:7, method:0, headers:[type:ping])
//   → 08 00 10 00 18 07 20 00 2a 0c 0a 04 "type" 12 04 "ping"

import 'dart:convert';
import 'dart:typed_data';

/// Frame.method: pings and pongs.
const int kPbbpControl = 0;

/// Frame.method: events and card callbacks.
const int kPbbpData = 1;

/// Header keys used by the protocol.
const String kPbbpType = 'type';
const String kPbbpMessageId = 'message_id';
const String kPbbpTraceId = 'trace_id';
const String kPbbpSum = 'sum';
const String kPbbpSeq = 'seq';
const String kPbbpBizRt = 'biz_rt';

class PbbpHeader {
  final String key;
  final String value;
  const PbbpHeader(this.key, this.value);
}

class PbbpFrame {
  final int seqId;
  final int logId;
  final int service;
  final int method;
  final List<PbbpHeader> headers;
  final String? payloadEncoding;
  final String? payloadType;
  final Uint8List? payload;
  final String? logIdNew;

  const PbbpFrame({
    this.seqId = 0,
    this.logId = 0,
    this.service = 0,
    this.method = kPbbpControl,
    this.headers = const [],
    this.payloadEncoding,
    this.payloadType,
    this.payload,
    this.logIdNew,
  });

  String? header(String key) {
    for (final h in headers) {
      if (h.key == key) return h.value;
    }
    return null;
  }

  /// The client ping, sent every ping-interval seconds.
  factory PbbpFrame.ping(int service) => PbbpFrame(
        service: service,
        method: kPbbpControl,
        headers: const [PbbpHeader(kPbbpType, 'ping')],
      );

  /// The acknowledgement for a data frame: the same frame with the
  /// `biz_rt` (handling time, ms) header added and the payload
  /// replaced by `{"code": code}`.
  PbbpFrame ack(int code, int elapsedMs) => PbbpFrame(
        seqId: seqId,
        logId: logId,
        service: service,
        method: method,
        headers: [
          ...headers,
          PbbpHeader(kPbbpBizRt, elapsedMs.toString()),
        ],
        payload: Uint8List.fromList(utf8.encode('{"code":$code}')),
      );

  // ── Encoding ──────────────────────────────────────────────────

  Uint8List encode() {
    final w = _ProtoWriter();
    // proto2 required semantics: write scalars even when zero.
    w.scalarVarint(1, seqId);
    w.scalarVarint(2, logId);
    w.scalarVarint(3, service);
    w.scalarVarint(4, method);
    for (final h in headers) {
      final body = _ProtoWriter()
        ..string(1, h.key)
        ..string(2, h.value);
      w.bytes(5, body.takeBytes());
    }
    if (payloadEncoding != null) w.string(6, payloadEncoding!);
    if (payloadType != null) w.string(7, payloadType!);
    if (payload != null) w.bytes(8, payload!);
    if (logIdNew != null) w.string(9, logIdNew!);
    return w.takeBytes();
  }

  // ── Decoding ──────────────────────────────────────────────────

  static PbbpFrame decode(Uint8List data) {
    var seqId = 0, logId = 0, service = 0, method = 0;
    var payloadEncoding = '', payloadType = '', logIdNew = '';
    Uint8List? payload;
    final headers = <PbbpHeader>[];

    var i = 0;
    int readVarint() {
      var result = 0;
      var shift = 0;
      while (i < data.length) {
        final byte = data[i++];
        result |= (byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift += 7;
      }
        throw const FormatException('truncated varint in pbbp2 frame');
    }

    Uint8List readBytes(int len) {
      if (i + len > data.length) {
        throw const FormatException('truncated bytes in pbbp2 frame');
      }
      final out = Uint8List.sublistView(data, i, i + len);
      i += len;
      return out;
    }

    while (i < data.length) {
      final tag = data[i++];
      final field = tag >> 3;
      final wireType = tag & 7;
      switch (field) {
        case 1:
          seqId = readVarint();
        case 2:
          logId = readVarint();
        case 3:
          service = readVarint();
        case 4:
          method = readVarint();
        case 5:
          if (wireType != 2) {
            throw const FormatException('bad header wire type');
          }
          final len = readVarint();
          final body = readBytes(len);
          _decodeHeader(body, headers);
        case 6:
          payloadEncoding = utf8.decode(readBytes(readVarint()));
        case 7:
          payloadType = utf8.decode(readBytes(readVarint()));
        case 8:
          payload = readBytes(readVarint());
        case 9:
          logIdNew = utf8.decode(readBytes(readVarint()));
        default:
          // Unknown field: skip per wire type.
          switch (wireType) {
            case 0:
              readVarint();
            case 2:
              readBytes(readVarint());
            case 5:
              readBytes(4);
            case 1:
              readBytes(8);
            default:
              throw const FormatException('bad wire type in pbbp2 frame');
          }
      }
    }
    return PbbpFrame(
      seqId: seqId,
      logId: logId,
      service: service,
      method: method,
      headers: List.unmodifiable(headers),
      payloadEncoding: payloadEncoding.isEmpty ? null : payloadEncoding,
      payloadType: payloadType.isEmpty ? null : payloadType,
      payload: payload,
      logIdNew: logIdNew.isEmpty ? null : logIdNew,
    );
  }

  static void _decodeHeader(Uint8List body, List<PbbpHeader> into) {
    var i = 0;
    String key = '', value = '';
    int readVarint() {
      var result = 0;
      var shift = 0;
      while (i < body.length) {
        final byte = body[i++];
        result |= (byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift += 7;
      }
      throw const FormatException('truncated varint in pbbp2 header');
    }

    String readStr() {
      final len = readVarint();
      final end = i + len;
      if (end > body.length) {
        throw const FormatException('truncated string in pbbp2 header');
      }
      final s = utf8.decode(body.sublist(i, end));
      i = end;
      return s;
    }

    while (i < body.length) {
      final tag = body[i++];
      switch (tag >> 3) {
        case 1:
          key = readStr();
        case 2:
          value = readStr();
        default:
          if (tag & 7 == 0) {
            readVarint();
          } else if (tag & 7 == 2) {
            readStr();
          } else {
            throw const FormatException('bad wire type in pbbp2 header');
          }
      }
    }
    into.add(PbbpHeader(key, value));
  }
}

/// Minimal proto writer with correct wire-type tags: varint fields
/// use tag type 0, strings/bytes/messages use tag type 2 with a
/// length prefix.
class _ProtoWriter {
  final _out = BytesBuilder();

  void _varint(int value) {
    var v = value;
    while (true) {
      final byte = v & 0x7f;
      v >>= 7;
      if (v == 0) {
        _out.addByte(byte);
        break;
      }
      _out.addByte(byte | 0x80);
    }
  }

  void scalarVarint(int field, int value) {
    _out.addByte((field << 3) | 0);
    _varint(value);
  }

  void string(int field, String value) => bytes(field, utf8.encode(value));

  void bytes(int field, List<int> value) {
    _out.addByte((field << 3) | 2);
    _varint(value.length);
    _out.add(value);
  }

  Uint8List takeBytes() => _out.takeBytes();
}
