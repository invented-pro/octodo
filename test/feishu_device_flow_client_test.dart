// Unit tests for the Feishu device-flow protocol client. HTTP is
// faked with `MockClient` from package:http (same pattern as the
// update-feed tests) so no real request ever leaves the process.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:octodo/src/feishu/feishu_device_flow_client.dart';

void main() {
  group('begin', () {
    test('posts the documented form fields to the registration endpoint',
        () async {
      Uri? seenUrl;
      Map<String, String>? seenFields;
      final client = FeishuDeviceFlowClient(
        httpClient: MockClient((req) async {
          seenUrl = req.url;
          seenFields = req.bodyFields;
          return http.Response(
            jsonEncode({
              'device_code': 'dc_123',
              'verification_uri_complete':
                  'https://open.feishu.cn/connect/qr?x=1',
              'interval': 5,
              'expire_in': 600,
            }),
            200,
          );
        }),
      );

      final begin = await client.begin();

      expect(
        seenUrl.toString(),
        'https://accounts.feishu.cn/oauth/v1/app/registration',
      );
      expect(seenFields, {
        'action': 'begin',
        'archetype': 'PersonalAgent',
        'auth_method': 'client_secret',
        'request_user_info': 'open_id',
      });
      expect(begin.deviceCode, 'dc_123');
      expect(begin.verificationUriComplete.toString(),
          'https://open.feishu.cn/connect/qr?x=1');
      expect(begin.interval, const Duration(seconds: 5));
      expect(begin.expiresIn, const Duration(seconds: 600));
    });

    test('rejects responses missing device_code as invalid_response',
        () async {
      final client = FeishuDeviceFlowClient(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(
        client.begin(),
        throwsA(isA<FeishuDeviceFlowException>().having(
          (e) => e.code,
          'code',
          kFeishuFlowErrorInvalidResponse,
        )),
      );
    });

    test('empty body maps to invalid_response', () async {
      final client = FeishuDeviceFlowClient(
        httpClient: MockClient((_) async => http.Response('   ', 200)),
      );
      await expectLater(
        client.begin(),
        throwsA(isA<FeishuDeviceFlowException>()),
      );
    });

    test('non-JSON body maps to invalid_response', () async {
      final client = FeishuDeviceFlowClient(
        httpClient: MockClient((_) async => http.Response('<html>', 200)),
      );
      await expectLater(
        client.begin(),
        throwsA(isA<FeishuDeviceFlowException>()),
      );
    });
  });

  group('poll', () {
    test('sends action=poll with the device code to the requested domain',
        () async {
      Uri? seenUrl;
      Map<String, String>? seenFields;
      final client = FeishuDeviceFlowClient(
        httpClient: MockClient((req) async {
          seenUrl = req.url;
          seenFields = req.bodyFields;
          return http.Response(jsonEncode({'error': 'authorization_pending'}),
              200);
        }),
      );

      final result = await client.poll('dc_123',
          domain: 'https://accounts.larksuite.com/');

      expect(seenUrl.toString(),
          'https://accounts.larksuite.com/oauth/v1/app/registration');
      expect(seenFields, {'action': 'poll', 'device_code': 'dc_123'});
      expect(result.hasCredentials, isFalse);
      expect(result.error, 'authorization_pending');
    });

    test('parses the success shape including user_info', () async {
      final client = FeishuDeviceFlowClient(
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({
                'client_id': 'cli_abc',
                'client_secret': 'shh',
                'user_info': {
                  'open_id': 'ou_owner',
                  'tenant_brand': 'lark',
                },
              }),
              200,
            )),
      );

      final result = await client.poll('dc_123');

      expect(result.hasCredentials, isTrue);
      expect(result.appId, 'cli_abc');
      expect(result.appSecret, 'shh');
      expect(result.openId, 'ou_owner');
      expect(result.tenantBrand, 'lark');
    });
  });

  group('buildQrUri', () {
    test('replaces from/tp/source, keeps unrelated params, appends payload',
        () {
      final uri = FeishuDeviceFlowClient.buildQrUri(
        Uri.parse(
            'https://open.feishu.cn/connect/qr?foo=bar&from=old&tp=old&source=other'),
        source: 'octodo-sdk',
        addons: const FeishuAppAddons(
          scopesTenant: ['im:message:send_as_bot'],
        ),
        presetName: 'Octodo {user}',
        createOnly: true,
      );

      final params = uri.queryParameters;
      expect(params['foo'], 'bar');
      expect(params['from'], 'sdk');
      expect(params['tp'], 'sdk');
      expect(params['source'], 'octodo-sdk');
      expect(params['name'], 'Octodo {user}');
      expect(params['createOnly'], 'true');
      expect(params['addons'], isNotEmpty);
      expect(params.containsKey('clientID'), isFalse);
    });

    test('passes existingAppId as clientID', () {
      final uri = FeishuDeviceFlowClient.buildQrUri(
        Uri.parse('https://open.feishu.cn/connect/qr'),
        source: 'octodo-sdk',
        existingAppId: 'cli_existing',
      );
      expect(uri.queryParameters['clientID'], 'cli_existing');
    });
  });

  group('encodeAddons', () {
    test('produces unpadded base64url over gzipped JSON', () {
      final encoded = FeishuDeviceFlowClient.encodeAddons(
        const FeishuAppAddons(
          minimalPreset: true,
          scopesTenant: ['im:message.p2p_msg:readonly'],
          eventsTenant: ['im.message.receive_v1'],
          callbacks: ['card.action.trigger'],
        ),
      );

      expect(encoded, isNot(contains('=')));

      // Pad back to a multiple of 4 and reverse the transform.
      final padded = encoded + '=' * ((4 - encoded.length % 4) % 4);
      final inflated = gzip.decode(base64Url.decode(padded));
      final json =
          jsonDecode(utf8.decode(inflated)) as Map<String, dynamic>;

      expect(json['preset'], false);
      expect((json['scopes'] as Map)['tenant'],
          ['im:message.p2p_msg:readonly']);
      expect(((json['events'] as Map)['items'] as Map)['tenant'],
          ['im.message.receive_v1']);
      expect((json['callbacks'] as Map)['items'], ['card.action.trigger']);
    });

    test('omits empty sections from the JSON', () {
      final encoded = FeishuDeviceFlowClient.encodeAddons(
        const FeishuAppAddons(scopesTenant: ['x:y']),
      );
      final padded = encoded + '=' * ((4 - encoded.length % 4) % 4);
      final json = jsonDecode(utf8.decode(gzip.decode(base64Url.decode(padded))))
          as Map<String, dynamic>;
      expect(json.keys, ['scopes']);
    });
  });
}
