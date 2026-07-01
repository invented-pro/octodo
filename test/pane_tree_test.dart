// Unit tests for Surface.normalizeShellCwd (a pure static function
// exposed via `@visibleForTesting`). The function translates the URI-style
// forward-slash drive paths that shells emit via OSC 7 back into
// Windows-style backslash paths so they compare equal against the
// `initialCwd` we stored at Surface construction. POSIX paths and UNC
// paths pass through unchanged.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/terminal/pane_tree.dart';
import 'package:octodo/src/terminal/terminal_workspace.dart'
    show applyCloseSurfaceForTest;

List<PaneContainer> _allLeaves(PaneNode root) {
  final out = <PaneContainer>[];
  if (root is PaneContainer) {
    out.add(root);
  } else if (root is PaneSplit) {
    out.addAll(_allLeaves(root.first));
    out.addAll(_allLeaves(root.second));
  }
  return out;
}

void main() {
  group('Surface.normalizeShellCwd', () {
    test('null stays null', () {
      expect(Surface.normalizeShellCwd(null), isNull);
    });

    test('empty string stays empty', () {
      expect(Surface.normalizeShellCwd(''), '');
    });

    test('drive-rooted forward-slash path → backslash', () {
      expect(Surface.normalizeShellCwd('C:/Users/<user>'), r'C:\Users\<user>');
      expect(Surface.normalizeShellCwd('c:/Program Files/app'),
          r'c:\Program Files\app');
      expect(Surface.normalizeShellCwd('D:/'), r'D:\');
    });

    test('drive-rooted backslash path passes through unchanged', () {
      expect(Surface.normalizeShellCwd(r'C:\Users\<user>'), r'C:\Users\<user>');
      expect(Surface.normalizeShellCwd(r'D:\proj\src'), r'D:\proj\src');
    });

    test('POSIX absolute path passes through unchanged', () {
      expect(Surface.normalizeShellCwd('/home/alice'), '/home/alice');
      expect(Surface.normalizeShellCwd('/mnt/c/Users/<user>'),
          '/mnt/c/Users/<user>');
      expect(Surface.normalizeShellCwd('/tmp'), '/tmp');
    });

    test('POSIX relative path passes through unchanged', () {
      expect(Surface.normalizeShellCwd('./proj'), './proj');
      expect(Surface.normalizeShellCwd('../sibling'), '../sibling');
      expect(Surface.normalizeShellCwd('docs/readme.md'), 'docs/readme.md');
    });

    test('WSL /home/<user> path passes through unchanged', () {
      // Critical for the `~` shortcut in the tab chip — WSL's OSC 7
      // reports the distro home as `/home/<user>`, which must NOT be
      // rewritten to backslashes.
      expect(Surface.normalizeShellCwd('/home/alice'), '/home/alice');
    });

    test('UNC path passes through unchanged', () {
      expect(
        Surface.normalizeShellCwd(r'\\server\share\dir'),
        r'\\server\share\dir',
      );
    });

    test('mixed forward + backslash in a drive path → all backslashes', () {
      // Some shells emit `C:/Users\<user>` (mixed). The rewrite is
      // unconditional for drive-rooted paths.
      expect(Surface.normalizeShellCwd(r'C:/Users\<user>'), r'C:\Users\<user>');
    });

    test('drive letter without colon is treated as POSIX', () {
      // The regex requires the colon; "C" alone shouldn't match the
      // drive pattern (avoids accidentally rewriting a bare drive
      // letter component of some other scheme).
      expect(Surface.normalizeShellCwd('C'), 'C');
    });

    test('multiple forward slashes in a drive path collapse to backslashes',
        () {
      expect(Surface.normalizeShellCwd('C://Users///<user>'),
          r'C:\\Users\\\<user>');
    });
  });

  group('PaneSplit.removeSurface — nested-collapse focus tracking', () {
    // When a [Surface] in a [PaneContainer] nested inside a multi-level
    // split is closed, and that container's last surface (so the
    // container collapses), the outer split may still be the same object
    // even though the *focused container itself* was disposed. The
    // workspace's `_closeSurfaceInContainer` historically used
    // `identical(newRoot, split)` as a proxy for "container still has
    // other surfaces" — which is wrong for the nested case, and leaves
    // `_focusedContainer` pointing at a disposed [PaneContainer].
    //
    // These tests pin down the *model* invariants the workspace relies
    // on; the workspace-level fix is in
    // `_closeSurfaceInContainer` (it must detect the "owner no longer
    // in tree" case separately from "owner still has other surfaces").

    test('closing the only tab of a nested container collapses the '
        'inner split; the outer split object is unchanged but `a` is '
        'gone', () {
      final a = PaneContainer()..surfaces.add(Surface());
      final b = PaneContainer()..surfaces.add(Surface());
      final c = PaneContainer()..surfaces.add(Surface());
      final innerSplit = PaneSplit(
        direction: Axis.horizontal,
        first: a,
        second: b,
      );
      final outerSplit = PaneSplit(
        direction: Axis.vertical,
        first: innerSplit,
        second: c,
      );

      final newRoot = outerSplit.removeSurface(a.surfaces.first);

      // Outer split object is unchanged (the inner split collapsed and
      // was spliced in by being replaced with `b`); but `a` is gone.
      expect(identical(newRoot, outerSplit), isTrue,
          reason: 'outer split is the same object; only its first child '
              'changed from innerSplit → b');
      // `a` no longer reachable from the new tree.
      final reachable = <String>{
        for (final leaf in _allLeaves(newRoot!)) leaf.id,
      };
      expect(reachable.contains(a.id), isFalse,
          reason: 'a was disposed and removed from the tree');
      expect(reachable.contains(b.id), isTrue);
      expect(reachable.contains(c.id), isTrue);
    });

    test('top-level (non-nested) collapse: identical(newRoot, split) is '
        'false because the split is replaced by the surviving container',
        () {
      final a = PaneContainer()..surfaces.add(Surface());
      final b = PaneContainer()..surfaces.add(Surface());
      final split = PaneSplit(
        direction: Axis.horizontal,
        first: a,
        second: b,
      );

      final newRoot = split.removeSurface(a.surfaces.first);

      expect(identical(newRoot, split), isFalse,
          reason: 'top-level collapse returns the sibling, not the split');
      expect(identical(newRoot, b), isTrue);
    });
  });

  group('applyCloseSurfaceForTest — focus-container invariants', () {
    // The workspace previously used `identical(newRoot, split)` to
    // decide "container still has other surfaces". That check is wrong
    // for *nested* splits: the outer split object survives an inner
    // collapse even though the focused container is gone. The fix
    // walks the tree to confirm `owner` is still reachable before
    // re-pointing `_focusedContainer` at it. These tests pin down the
    // three cases the helper handles.

    test('top-level collapse: focused = surviving sibling', () {
      final a = PaneContainer()..surfaces.add(Surface());
      final b = PaneContainer()..surfaces.add(Surface());
      final split = PaneSplit(
        direction: Axis.horizontal,
        first: a,
        second: b,
      );

      final result = applyCloseSurfaceForTest(split, a, a.surfaces.first);
      expect(result, isNotNull);
      expect(identical(result!.tree, b), isTrue,
          reason: 'tree root collapses to the surviving sibling');
      expect(identical(result.focused, b), isTrue,
          reason: 'focus transfers to the surviving sibling');
    });

    test('nested collapse (owner disposed inside inner split): '
        'focused = first reachable leaf, NOT the disposed owner', () {
      final a = PaneContainer()..surfaces.add(Surface());
      final b = PaneContainer()..surfaces.add(Surface());
      final c = PaneContainer()..surfaces.add(Surface());
      final innerSplit = PaneSplit(
        direction: Axis.horizontal,
        first: a,
        second: b,
      );
      final outerSplit = PaneSplit(
        direction: Axis.vertical,
        first: innerSplit,
        second: c,
      );

      final result = applyCloseSurfaceForTest(
          outerSplit, a, a.surfaces.first);
      expect(result, isNotNull);
      // Tree root is unchanged (outerSplit), but a is gone.
      expect(identical(result!.tree, outerSplit), isTrue);
      // CRITICAL: focused must NOT be the disposed `a`.
      expect(identical(result.focused, a), isFalse,
          reason: 'a was disposed; pointing _focusedContainer at it would '
              'break Ctrl+Shift+K, visual focus indicator, and '
              'focusCurrentPane()');
      // Focused should be the first reachable leaf (B in this layout).
      expect(identical(result.focused, b), isTrue);
    });

    test('non-collapsing close (owner keeps other surfaces): '
        'focused = owner', () {
      final a = PaneContainer()
        ..surfaces.addAll([Surface(), Surface()]);
      final b = PaneContainer()..surfaces.add(Surface());
      final split = PaneSplit(
        direction: Axis.horizontal,
        first: a,
        second: b,
      );

      final result = applyCloseSurfaceForTest(
          split, a, a.surfaces[0]);
      expect(result, isNotNull);
      expect(identical(result!.tree, split), isTrue);
      expect(identical(result.focused, a), isTrue);
      // focusedIndex clamped to the new last surface.
      expect(a.focusedIndex, 0);
    });
  });
}