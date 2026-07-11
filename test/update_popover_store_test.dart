// Widget tests for the store-distribution branch of the update
// popover (`_AvailableBody`). The portable body shows Download +
// Skip; the store body shows a plain "Update" button that opens
// the Store URL in the browser and drops the Skip affordance.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/settings/settings_catalog.dart';
import 'package:octodo/src/theme/app_theme.dart';
import 'package:octodo/src/theme/palettes.dart';
import 'package:octodo/src/update/distribution.dart';
import 'package:octodo/src/update/release_resolver.dart';
import 'package:octodo/src/update/update_controller.dart';
import 'package:octodo/src/update/update_state.dart';
import 'package:octodo/ui/update/update_popover_view.dart';

ReleaseInfo _release() => ReleaseInfo(
      version: '9.9.9',
      tagName: 'v9.9.9',
      prerelease: false,
      htmlUrl: Uri.parse('https://github.com/invented-pro/octodo/releases'
          '/tag/v9.9.9'),
      zipUrl: Uri.parse(
          'https://example.com/v9.9.9/octodo-v9.9.9-windows-x64.zip'),
      zipSizeBytes: 5242880,
    );

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(palette: AppPalettes.byId('catppuccin-mocha')),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('store body shows "Update" button and no Download/Skip',
      (tester) async {
    final model = UpdateStateModel(
      currentVersion: '1.0.0',
      distribution: InstallDistribution.store,
    )..setAvailable(_release());
    final controller = UpdateController(
      model: model,
      settings: SettingsCatalog().update,
      userAgentVersion: '1.0.0',
      distribution: InstallDistribution.store,
    );

    await tester.pumpWidget(_wrap(
      UpdatePopoverView(model: model, controller: controller),
    ));

    expect(find.text('Update'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
    // Portable-only affordances must be absent on the store body.
    expect(find.text('Skip this version'), findsNothing);
    expect(find.textContaining('Download'), findsNothing);
    // The Store explanatory copy replaces the GitHub/SHA-256 one.
    expect(find.textContaining('Microsoft Store'), findsOneWidget);
    expect(find.textContaining('SHA-256'), findsNothing);

    controller.dispose();
  });
}

