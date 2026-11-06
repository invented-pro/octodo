// Unit tests for the session picker the opencode gateway matches
// Feishu messages with — pure logic, no HTTP (the ranking rules
// were learned from live data; see pickSessionId's doc).

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/opencode_client.dart';

Map<String, dynamic> _session(String id, String dir,
    {int? created, int? updated, int? viewed}) {
  final time = <String, dynamic>{
    'created': created ?? 0,
    'updated': updated ?? 0,
  };
  if (viewed != null) time['viewed'] = viewed;
  return {
    'id': id,
    'location': {'directory': dir},
    'time': time,
  };
}

void main() {
  test('a fresher viewed stamp beats a fresher updated stamp', () {
    // Field shape (observed 2026-11-06): the wrong old session had
    // updated=now (every Feishu message refreshes it) while the
    // desktop TUI had just stamped viewed on the session it
    // displays. The displayed session must win — ranking by
    // max(viewed, updated) stuck every message in the old session.
    final sessions = [
      _session('ses_old', r'E:\proj', updated: 2000, viewed: 1000),
      _session('ses_new', r'E:\proj',
          created: 1500, updated: 1500, viewed: 1800),
    ];
    expect(
        OpencodeLocalGateway.pickSessionId(sessions, r'e:/proj'), 'ses_new',
        reason: 'follow the displayed session, not the chatted one');
  });

  test('updated breaks ties among never-viewed sessions', () {
    final sessions = [
      _session('ses_a', r'E:\proj', updated: 100),
      _session('ses_b', r'E:\proj', updated: 300),
      _session('ses_elsewhere', r'E:\other', updated: 999, viewed: 999),
    ];
    expect(OpencodeLocalGateway.pickSessionId(sessions, r'E:\proj'), 'ses_b');
  });

  test('other directories and junk entries are ignored', () {
    final sessions = [
      'not a map',
      _session('ses_other', r'E:\elsewhere', updated: 9000, viewed: 9000),
      _session('ses_mine', r'E:\proj', updated: 10),
    ];
    expect(OpencodeLocalGateway.pickSessionId(sessions, r'E:\PROJ'), 'ses_mine',
        reason: 'directory match is separator- and case-insensitive');
    expect(OpencodeLocalGateway.pickSessionId(sessions, r'E:\nothing'), isNull);
  });

  test('an empty list picks nothing', () {
    expect(OpencodeLocalGateway.pickSessionId(const [], r'E:\proj'), isNull);
  });
}
