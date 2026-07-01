import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Regression guard for the bundled shell/distro SVG assets.
///
/// `flutter_svg` parses assets through `vector_graphics_compiler`, whose
/// strict SVG parser rejects attributes / namespaces it can't decode
/// (e.g. Adobe Illustrator's `xmlns:i="http://ns.adobe.com/...` causes
/// `FormatException: Invalid double`). If a downstream tool ever
/// replaces an asset with one of those files, this suite catches it
/// at unit-test time instead of in the live app.
void main() {
  for (final name in const [
    'powershell',
    'git-bash',
    'ubuntu',
    'debian',
    'fedora',
    'arch',
    'opensuse',
    'kali',
    'alpine',
    'centos',
    'oracle',
    'nixos',
    'wsl-fallback',
  ]) {
    testWidgets('$name.svg loads without throwing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 64,
                height: 64,
                child: SvgPicture.asset('assets/icons/$name.svg'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The loader runs under compute(); a parse throw surfaces here.
      expect(tester.takeException(), isNull,
          reason: '$name.svg raised during parse');
      // Sanity: the asset key resolved and produced an SvgPicture.
      expect(find.byType(SvgPicture), findsOneWidget,
          reason: '$name.svg did not produce an SvgPicture widget');
    });
  }
}