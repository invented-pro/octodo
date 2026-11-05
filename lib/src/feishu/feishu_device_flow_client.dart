// Feishu/Lark one-click app registration — the OAuth 2.0 Device
// Authorization Grant (RFC 8628) flow behind the "scan a QR code to
// create a bot" experience.
//
// Protocol notes (mirrors the official SDKs' `registration` scene,
// e.g. larksuite-oapi-sdk-rs `src/registration.rs`):
//
//   POST {accountsDomain}/oauth/v1/app/registration
//   Content-Type: application/x-www-form-urlencoded
//
//   begin → action=begin & archetype=PersonalAgent
//           & auth_method=client_secret & request_user_info=open_id
//         ← { device_code, verification_uri_complete, interval, expire_in }
//
//   poll  → action=poll & device_code=…
//         ← { client_id, client_secret,
//             user_info: { open_id, tenant_brand },
//             error, error_description }
//
// `error` is empty on success ("authorization_pending" while the
// user has not confirmed yet, "slow_down" asks for +5 s, and
// "access_denied" / "expired_token" are terminal). A Lark-tenant
// user (`tenant_brand == "lark"`) means later polls must be sent to
// the larksuite.com accounts domain instead of feishu.cn.
//
// The QR URL shown to the user is `verification_uri_complete` with
// the `from`/`tp`/`source` params replaced and an `addons` param
// appended: base64url(gzip(JSON)) declaring the scopes / events /
// callbacks to pre-fill on the confirmation page, so the user only
// confirms instead of picking permissions by hand.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Terminal failures surfaced by [FeishuDeviceFlowException.code].
const String kFeishuFlowErrorAccessDenied = 'access_denied';
const String kFeishuFlowErrorExpiredToken = 'expired_token';
const String kFeishuFlowErrorInvalidResponse = 'invalid_response';
const String kFeishuFlowErrorNetwork = 'network';

class FeishuDeviceFlowException implements Exception {
  /// One of the `kFeishuFlowError*` constants (or a platform error
  /// code forwarded verbatim from the poll response).
  final String code;
  final String description;

  const FeishuDeviceFlowException(this.code, this.description);

  @override
  String toString() => 'FeishuDeviceFlowException($code): $description';
}

/// Result of the `begin` request: what to render as a QR code and
/// how to pace the polling loop.
class FeishuDeviceFlowBegin {
  final String deviceCode;
  final Uri verificationUriComplete;

  /// Suggested delay between polls. Zero is normalized to 5 s by
  /// the server contract; kept verbatim here.
  final Duration interval;

  /// Total lifetime of the device code.
  final Duration expiresIn;

  const FeishuDeviceFlowBegin({
    required this.deviceCode,
    required this.verificationUriComplete,
    required this.interval,
    required this.expiresIn,
  });
}

/// Result of a single `poll` request. Success is signaled by
/// non-empty [appId] + [appSecret]; otherwise [error] carries the
/// pending / slow_down / terminal code.
class FeishuPollResult {
  final String appId;
  final String appSecret;
  final String openId;
  final String tenantBrand;
  final String error;
  final String errorDescription;

  const FeishuPollResult({
    this.appId = '',
    this.appSecret = '',
    this.openId = '',
    this.tenantBrand = '',
    this.error = '',
    this.errorDescription = '',
  });

  bool get hasCredentials => appId.isNotEmpty && appSecret.isNotEmpty;
}

/// Scopes / events / callbacks pre-filled on the QR confirmation
/// page (the `addons` query param of the verification URL).
class FeishuAppAddons {
  /// `false` switches the base template to "bot capability only"
  /// so the final config is fully declared by the lists below.
  final bool minimalPreset;
  final List<String> scopesTenant;
  final List<String> scopesUser;
  final List<String> eventsTenant;
  final List<String> eventsUser;
  final List<String> callbacks;

  const FeishuAppAddons({
    this.minimalPreset = false,
    this.scopesTenant = const [],
    this.scopesUser = const [],
    this.eventsTenant = const [],
    this.eventsUser = const [],
    this.callbacks = const [],
  });

  /// JSON shape the platform expects inside the gzipped `addons`
  /// param (empty lists omitted, matching the official SDKs).
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (minimalPreset) json['preset'] = false;
    if (scopesTenant.isNotEmpty || scopesUser.isNotEmpty) {
      json['scopes'] = {
        if (scopesTenant.isNotEmpty) 'tenant': scopesTenant,
        if (scopesUser.isNotEmpty) 'user': scopesUser,
      };
    }
    if (eventsTenant.isNotEmpty || eventsUser.isNotEmpty) {
      json['events'] = {
        'items': {
          if (eventsTenant.isNotEmpty) 'tenant': eventsTenant,
          if (eventsUser.isNotEmpty) 'user': eventsUser,
        },
      };
    }
    if (callbacks.isNotEmpty) {
      json['callbacks'] = {'items': callbacks};
    }
    return json;
  }
}

/// HTTP client for the two device-flow requests. Pure protocol
/// layer: no state, no polling loop (see `FeishuBindingFlow`), so
/// every request can be faked with `MockClient` in tests.
class FeishuDeviceFlowClient {
  /// Accounts domains. `accounts.feishu.cn` serves Feishu tenants;
  /// a poll response with `tenant_brand == "lark"` instructs the
  /// caller to re-target [larkDomain] (international Lark tenants).
  final String feishuDomain;
  final String larkDomain;

  final http.Client _http;

  /// Per-request timeout applied to both device-flow calls.
  final Duration requestTimeout;

  static const String _endpointPath = '/oauth/v1/app/registration';

  FeishuDeviceFlowClient({
    http.Client? httpClient,
    this.feishuDomain = 'https://accounts.feishu.cn',
    this.larkDomain = 'https://accounts.larksuite.com',
    this.requestTimeout = const Duration(seconds: 30),
  }) : _http = httpClient ?? http.Client();

  void close() => _http.close();

  Future<FeishuDeviceFlowBegin> begin({String? domain}) async {
    final body = await _postForm(domain ?? feishuDomain, const {
      'action': 'begin',
      'archetype': 'PersonalAgent',
      'auth_method': 'client_secret',
      'request_user_info': 'open_id',
    });
    final deviceCode = (body['device_code'] ?? '') as String;
    final uri = (body['verification_uri_complete'] ?? '') as String;
    if (deviceCode.isEmpty || uri.isEmpty) {
      throw const FeishuDeviceFlowException(
        kFeishuFlowErrorInvalidResponse,
        'device_code / verification_uri_complete missing from begin response',
      );
    }
    return FeishuDeviceFlowBegin(
      deviceCode: deviceCode,
      verificationUriComplete: Uri.parse(uri),
      interval: Duration(seconds: _asInt(body['interval'], 0)),
      expiresIn: Duration(seconds: _asInt(body['expire_in'], 0)),
    );
  }

  Future<FeishuPollResult> poll(String deviceCode, {String? domain}) async {
    final body = await _postForm(domain ?? feishuDomain, {
      'action': 'poll',
      'device_code': deviceCode,
    });
    final userInfo = body['user_info'];
    final userInfoMap = userInfo is Map<String, dynamic> ? userInfo : null;
    return FeishuPollResult(
      appId: _asStr(body['client_id']),
      appSecret: _asStr(body['client_secret']),
      openId: _asStr(userInfoMap?['open_id']),
      tenantBrand: _asStr(userInfoMap?['tenant_brand']),
      error: _asStr(body['error']),
      errorDescription: _asStr(body['error_description']),
    );
  }

  Future<Map<String, dynamic>> _postForm(
    String domain,
    Map<String, String> fields,
  ) async {
    final url = Uri.parse(
      '${domain.replaceAll(RegExp(r'/+$'), '')}$_endpointPath',
    );
    final http.Response response;
    try {
      response = await _http
          .post(url, body: fields)
          .timeout(requestTimeout);
    } catch (e) {
      throw FeishuDeviceFlowException(
        kFeishuFlowErrorNetwork,
        'registration request failed: $e',
      );
    }
    if (response.body.trim().isEmpty) {
      throw const FeishuDeviceFlowException(
        kFeishuFlowErrorInvalidResponse,
        'empty response body',
      );
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      throw const FormatException('not a JSON object');
    } on FormatException catch (e) {
      throw FeishuDeviceFlowException(
        kFeishuFlowErrorInvalidResponse,
        'undecodable response body (${response.statusCode}): $e',
      );
    }
  }

  // ── QR URL construction ─────────────────────────────────────

  /// Enrich the platform's `verification_uri_complete` for display:
  /// drop any incoming `from`/`tp`/`source` params, then append
  /// the SDK identity, optional app-preset fields, the compressed
  /// [addons] payload and the `createOnly` / `clientID` switches.
  static Uri buildQrUri(
    Uri verificationUriComplete, {
    required String source,
    FeishuAppAddons? addons,
    String? presetName,
    String? presetDesc,
    String? presetAvatar,
    bool createOnly = false,
    String? existingAppId,
  }) {
    final params = <String, List<String>>{};
    verificationUriComplete.queryParametersAll.forEach((key, values) {
      if (key != 'from' && key != 'tp' && key != 'source') {
        params[key] = values;
      }
    });
    void append(String key, String value) =>
        params[key] = [...?params[key], value];

    append('from', 'sdk');
    append('tp', 'sdk');
    append('source', source);
    if (presetAvatar != null && presetAvatar.isNotEmpty) {
      append('avatar', presetAvatar);
    }
    if (presetName != null && presetName.isNotEmpty) append('name', presetName);
    if (presetDesc != null && presetDesc.isNotEmpty) append('desc', presetDesc);
    if (addons != null) append('addons', encodeAddons(addons));
    if (createOnly) append('createOnly', 'true');
    if (existingAppId != null && existingAppId.isNotEmpty) {
      append('clientID', existingAppId);
    }
    return verificationUriComplete.replace(queryParameters: params);
  }

  /// `addons` = base64url-without-padding(gzip(JSON)), the wire
  /// format shared by every official SDK.
  static String encodeAddons(FeishuAppAddons addons) {
    final json = utf8.encode(jsonEncode(addons.toJson()));
    final compressed = gzip.encode(json);
    return base64Url.encode(compressed).replaceAll('=', '');
  }

  static int _asInt(Object? value, int fallback) =>
      value is int ? value : fallback;

  static String _asStr(Object? value) => value is String ? value : '';
}
