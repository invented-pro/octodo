// Test relay: writes its inherited helper env vars to a
// PID-scoped log in the system temp dir, then exits. Used by the
// staged_apply_test.dart regression test to assert that
// `StagedApply._relaunch` clears `OCTODO_UPDATE_HELPER` (and the
// matching payload/pid vars) in the spawned child. Without that
// override the new exe re-enters helper mode at the top of
// `main()` and the helper chain recurses — see the comment on
// `_relaunch` in staged_apply.dart for the full writeup.
//
// Output file: `<systemTemp>/octodo_relay_<pid>.log`
// Format: one `KEY=value\n` line per helper env var, with `<UNSET>`
// for keys absent from the environment.

import 'dart:io';

void main() {
  final dir = Directory.systemTemp.path;
  final myPid = pid;
  final outFile = File(
    '$dir${Platform.pathSeparator}octodo_relay_$myPid.log',
  );
  String lookup(String name) =>
      Platform.environment[name] ?? '<UNSET>';
  outFile.writeAsStringSync(
    'OCTODO_UPDATE_HELPER=${lookup('OCTODO_UPDATE_HELPER')}\n'
    'OCTODO_UPDATE_PAYLOAD=${lookup('OCTODO_UPDATE_PAYLOAD')}\n'
    'OCTODO_UPDATE_PID=${lookup('OCTODO_UPDATE_PID')}\n',
  );
}