// Tests for the outbound Feishu API client: token lifecycle,
// message send, token-expiry retry, and long-text chunking. HTTP
// faked with MockClient.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:octodo/src/feishu/feishu_api_client.dart';
import 'package:octodo/src/feishu/feishu_credentials.dart';

FeishuCredentials _creds() => FeishuCredentials(
      appId: 'cli_x',
      appSecret: 'secret',
      ownerOpenId: 'ou_o',
      tenantBrand: 'feishu',
      boundAt: DateTime.utc(2026),
    );

Map<String, dynamic> bodyOf(http.Request req) =>
    jsonDecode(req.body) as Map<String, dynamic>;

void main() {
  test('sendText obtains a token then posts a message', () async {
    final requests = <http.Request>[];
    final client = FeishuApiClient(
      httpClient: MockClient((req) async {
        requests.add(req);
        final path = req.url.path;
        if (path.endsWith('tenant_access_token/internal')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'tenant_access_token': 't-1',
              'expire': 3600,
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
      }),
    );
    client.bind(_creds());

    await client.sendText('oc_chat', 'hello');

    expect(requests.length, 2);
    expect(requests[0].url.path,
        '/open-apis/auth/v3/tenant_access_token/internal');
    expect(bodyOf(requests[0])['app_id'], 'cli_x');
    expect(requests[1].url.path, '/open-apis/im/v1/messages');
    expect(requests[1].url.queryParameters['receive_id_type'], 'chat_id');
    expect(requests[1].headers['authorization'], 'Bearer t-1');
    final send = bodyOf(requests[1]);
    expect(send['receive_id'], 'oc_chat');
    expect(send['msg_type'], 'text');
    expect(jsonDecode(send['content'] as String), {'text': 'hello'});
    client.dispose();
  });

  test('an expired token is refreshed once and the send retried',
      () async {
    var tokenCalls = 0;
    var sendCalls = 0;
    final client = FeishuApiClient(
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('tenant_access_token/internal')) {
          tokenCalls++;
          return http.Response(
            jsonEncode({
              'code': 0,
              'tenant_access_token': 't-$tokenCalls',
              'expire': 3600,
            }),
            200,
          );
        }
        sendCalls++;
        final auth = (req).headers['authorization']!;
        if (auth == 'Bearer t-1') {
          return http.Response(
            jsonEncode({'code': 99991663, 'msg': 'token expired'}),
            200,
          );
        }
        return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
      }),
    );
    client.bind(_creds());

    await client.sendText('oc_chat', 'hi');

    expect(tokenCalls, 2); // initial + refresh
    expect(sendCalls, 2); // bounced + retried
    client.dispose();
  });

  test('a rejected send surfaces FeishuApiException', () async {
    final client = FeishuApiClient(
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('tenant_access_token/internal')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'tenant_access_token': 't-1',
              'expire': 3600,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'code': 230002, 'msg': 'no permission'}),
          200,
        );
      }),
    );
    client.bind(_creds());

    await expectLater(
      client.sendText('oc_chat', 'hi'),
      throwsA(isA<FeishuApiException>().having(
        (e) => e.code,
        'code',
        230002,
      )),
    );
    client.dispose();
  });

  test('long text is chunked with part markers', () async {
    final sends = <http.Request>[];
    final client = FeishuApiClient(
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('tenant_access_token/internal')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'tenant_access_token': 't-1',
              'expire': 3600,
            }),
            200,
          );
        }
        sends.add(req);
        return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
      }),
    );
    client.bind(_creds());

    final long = 'x' * (kFeishuMaxMessageChars + 500);
    await client.sendText('oc_chat', long);

    expect(sends.length, 2);
    final first = jsonDecode(bodyOf(sends[0])['content'] as String)
        as Map<String, dynamic>;
    final second = jsonDecode(bodyOf(sends[1])['content'] as String)
        as Map<String, dynamic>;
    expect((first['text'] as String).startsWith('x'), isTrue);
    expect(first['text'].toString().endsWith('(1/2)'), isTrue);
    expect(second['text'].toString().endsWith('(2/2)'), isTrue);
    client.dispose();
  });

  test('unbound client refuses to send', () async {
    final client = FeishuApiClient(
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    await expectLater(client.sendText('oc', 'hi'), throwsA(anything));
    client.dispose();
  });
}
