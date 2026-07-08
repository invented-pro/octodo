// Unit tests for Surface.normalizeShellCwd (a pure static function
// exposed via `@visibleForTesting`). The function translates the URI-style
// forward-slash drive paths that shells emit via OSC 7 back into
// Windows-style backslash paths so they compare equal against the
// `initialCwd` we stored at Surface construction. POSIX paths and UNC
// paths pass through unchanged.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/terminal/pane_tree.dart';
import 'package:octodo/src/terminal/shell_profiles.dart';
import 'package:octodo/src/terminal/terminal_workspace.dart'
    show applyCloseSurfaceForTest, applyDropToSplitEdgeForTest;

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
      expect(
        Surface.normalizeShellCwd('c:/Program Files/app'),
        r'c:\Program Files\app',
      );
      expect(Surface.normalizeShellCwd('D:/'), r'D:\');
    });

    test('drive-rooted backslash path passes through unchanged', () {
      expect(Surface.normalizeShellCwd(r'C:\Users\<user>'), r'C:\Users\<user>');
      expect(Surface.normalizeShellCwd(r'D:\proj\src'), r'D:\proj\src');
    });

    test('POSIX absolute path passes through unchanged', () {
      expect(Surface.normalizeShellCwd('/home/alice'), '/home/alice');
      expect(
        Surface.normalizeShellCwd('/mnt/c/Users/<user>'),
        '/mnt/c/Users/<user>',
      );
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

    test(
      'multiple forward slashes in a drive path collapse to backslashes',
      () {
        expect(
          Surface.normalizeShellCwd('C://Users///<user>'),
          r'C:\\Users\\\<user>',
        );
      },
    );
  });

  group('Surface.fallbackTitle — WSL home cwd shape', () {
    // Builds a WSL profile (program=…\\wsl.exe) with the flag set so
    // the chip shows the basename of the current cwd. Mirrors what
    // shell_profiles.dart wires up per distro.
    ShellProfile wslProfile() => ShellProfile(
          label: 'Ubuntu',
          program: r'C:\Windows\System32\wsl.exe',
          args: const ['-d', 'Ubuntu', '--cd', '~'],
          icon: Icons.laptop_chromebook,
          color: const Color(0xFF22C55E),
          shortName: 'ubuntu',
          showCwdInTitle: true,
          wslDistro: 'Ubuntu',
        );

    test(
        r'resolved home: OSC 7 == initialCwd → `ubuntu ~` '
        r'(the resolved-$HOME path)',
        () {
      final s = Surface(profile: wslProfile(), initialCwd: '/home/u1');
      s.currentCwd = '/home/u1';
      expect(s.fallbackTitle, 'ubuntu ~');
    });

    test(
        'unresolved-home sentinel (initialCwd="~"): OSC 7 inside /home → `ubuntu ~`',
        () {
      // Sentinel case: `_queryWslHome` timed out in terminal_workspace.dart
      // so initialCwd is the literal `~`. Shell still starts in $HOME via
      // `--cd ~`; OSC 7 fires with the distro user's actual `/home/<u>`.
      final s = Surface(profile: wslProfile(), initialCwd: '~');
      s.currentCwd = '/home/u1';
      expect(s.fallbackTitle, 'ubuntu ~');
    });

    test(
        'unresolved-home sentinel: cd /tmp → `ubuntu tmp` (basename, not `~`)',
        () {
      // After `cd /tmp`, the chip must drop out of the home shortcut —
      // the structural match against `/home/<…>` shouldn't fire here.
      final s = Surface(profile: wslProfile(), initialCwd: '~');
      s.currentCwd = '/tmp';
      expect(s.fallbackTitle, 'ubuntu tmp');
    });

    test(
        'sentinel with empty currentCwd and empty initialCwd → just shortName',
        () {
      // OSC 7 hasn't fired yet. Sentinel matches no path; the fallback
      // is the bare shortName so a brand-new tab is readable.
      final s = Surface(profile: wslProfile(), initialCwd: '~');
      expect(s.currentCwd, isNull);
      expect(s.fallbackTitle, 'ubuntu');
    });

    test(
        'non-WSL profile with sentinel-like initialCwd does NOT enter home shortcut',
        () {
      // Belt-and-braces: a non-WSL profile whose initialCwd was somehow
      // set to the literal `~` (should never happen) must not be treated
      // as a home shortcut.
      final pwsh = ShellProfile(
        label: 'pwsh',
        program: r'C:\Program Files\PowerShell\7\pwsh.exe',
        args: const ['-NoLogo'],
        icon: Icons.terminal,
        color: const Color(0xFF0078D4),
        shortName: 'pwsh',
        showCwdInTitle: true,
      );
      final s = Surface(profile: pwsh, initialCwd: '~');
      s.currentCwd = 'C:/Users/tester';
      // No home shortcut — falls back to basename of currentCwd.
      expect(s.fallbackTitle, 'pwsh tester');
    });
  });

  group('applyDropToSplitEdgeForTest — source-pane collapse (regression: '
      'dragged terminal must dock, not disappear)', () {
    // Regression for the bug where _dropToSplitEdge captured
    // root = _rootPane at entry, but the source-collapse step then
    // reassigned _rootPane to the surviving sibling. The "wrap the
    // root in a new split" branch tested the STALE entry-time root
    // (still a PaneSplit) instead of the post-collapse root (a
    // PaneContainer identical to the target), so neither attach
    // branch ran and the new container holding the dragged tab was
    // orphaned — the terminal vanished from the workspace.

    test(
        '2 panes each 1 tab, drag A onto B edge: '
        'tab docks into a new split, A collapses away', () {
      final a = PaneContainer()..surfaces.add(Surface());
      final b = PaneContainer()..surfaces.add(Surface());
      final split = PaneSplit(direction: Axis.horizontal, first: a, second: b);
      final dragged = a.surfaces.first;

      final result = applyDropToSplitEdgeForTest(
        root: split,
        fromContainer: a,
        surface: dragged,
        target: b,
        direction: Axis.horizontal,
        isFirst: false, // right edge → new container on the second side
      );

      expect(result, isNotNull);
      // Tree must be a fresh split (NOT the stale root, NOT a lone
      // container with the surface reverted into b).
      expect(result!.tree, isA<PaneSplit>());
      final newSplit = result.tree as PaneSplit;
      // b survived as `first`; the new container is `second`.
      expect(identical(newSplit.first, b), isTrue);
      expect(newSplit.second, isA<PaneContainer>());
      expect(identical(newSplit.second, a), isFalse,
          reason: 'a collapsed and was disposed; must not reappear');
      // The dragged tab landed in the new container.
      final newContainer = newSplit.second as PaneContainer;
      expect(newContainer.surfaces, contains(dragged));
      expect(newContainer.surfaces.length, 1);
      // b still holds exactly its original tab (no accidental revert).
      expect(b.surfaces.length, 1);
      // Focus transfers to the new container.
      expect(identical(result.focused, newContainer), isTrue);
    });

    test('vertical split variant: outcome is orientation-agnostic', () {
      // The user reported the bug for both vertically- and
      // horizontally-split layouts; the attach logic doesn't depend
      // on orientation, but pin the vertical case too.
      final top = PaneContainer()..surfaces.add(Surface());
      final bottom = PaneContainer()..surfaces.add(Surface());
      final split =
          PaneSplit(direction: Axis.vertical, first: top, second: bottom);
      final dragged = top.surfaces.first;

      final result = applyDropToSplitEdgeForTest(
        root: split,
        fromContainer: top,
        surface: dragged,
        target: bottom,
        direction: Axis.vertical,
        isFirst: true, // top edge → new container on the first side
      );

      expect(result, isNotNull);
      final newSplit = result!.tree as PaneSplit;
      // bottom survived and is now `second`; new container is `first`.
      expect(identical(newSplit.second, bottom), isTrue);
      expect(newSplit.first, isA<PaneContainer>());
      expect((newSplit.first as PaneContainer).surfaces, contains(dragged));
    });

    test(
        'source keeps other tabs: A retains its remaining tab, '
        'B is wrapped in an inner split with the new container', () {
      // Non-collapsing case — this path worked before the fix too;
      // included as a non-regression guard so the collapse fix
      // doesn't accidentally break the normal multi-tab move.
      final a = PaneContainer()..surfaces.addAll([Surface(), Surface()]);
      final b = PaneContainer()..surfaces.add(Surface());
      final split = PaneSplit(direction: Axis.horizontal, first: a, second: b);
      final dragged = a.surfaces.first;

      final result = applyDropToSplitEdgeForTest(
        root: split,
        fromContainer: a,
        surface: dragged,
        target: b,
        direction: Axis.horizontal,
        isFirst: false,
      );

      expect(result, isNotNull);
      // Root split object survives (no top-level collapse).
      expect(identical(result!.tree, split), isTrue);
      // a still in tree, now with one tab; the dragged one is gone.
      expect(a.surfaces.length, 1);
      expect(a.surfaces.contains(dragged), isFalse);
      // b was replaced by an inner split (b + new container).
      final inner = split.second as PaneSplit;
      expect(identical(inner.first, b), isTrue);
      expect((inner.second as PaneContainer).surfaces, contains(dragged));
      // Focus goes to the new container.
      expect(identical(result.focused, inner.second), isTrue);
    });

    test(
        'no-op: dragging the only tab onto its own pane edge '
        'returns null and leaves the tree untouched', () {
      final a = PaneContainer()..surfaces.add(Surface());
      final b = PaneContainer()..surfaces.add(Surface());
      final split = PaneSplit(direction: Axis.horizontal, first: a, second: b);

      final result = applyDropToSplitEdgeForTest(
        root: split,
        fromContainer: a,
        surface: a.surfaces.first,
        target: a, // same container
        direction: Axis.horizontal,
        isFirst: false,
      );

      expect(result, isNull);
      expect(identical(split.first, a), isTrue);
      expect(a.surfaces.length, 1);
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
      expect(
        identical(newRoot, outerSplit),
        isTrue,
        reason:
            'outer split is the same object; only its first child '
            'changed from innerSplit → b',
      );
      // `a` no longer reachable from the new tree.
      final reachable = <String>{
        for (final leaf in _allLeaves(newRoot!)) leaf.id,
      };
      expect(
        reachable.contains(a.id),
        isFalse,
        reason: 'a was disposed and removed from the tree',
      );
      expect(reachable.contains(b.id), isTrue);
      expect(reachable.contains(c.id), isTrue);
    });

    test('top-level (non-nested) collapse: identical(newRoot, split) is '
        'false because the split is replaced by the surviving container', () {
      final a = PaneContainer()..surfaces.add(Surface());
      final b = PaneContainer()..surfaces.add(Surface());
      final split = PaneSplit(direction: Axis.horizontal, first: a, second: b);

      final newRoot = split.removeSurface(a.surfaces.first);

      expect(
        identical(newRoot, split),
        isFalse,
        reason: 'top-level collapse returns the sibling, not the split',
      );
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
      final split = PaneSplit(direction: Axis.horizontal, first: a, second: b);

      final result = applyCloseSurfaceForTest(split, a, a.surfaces.first);
      expect(result, isNotNull);
      expect(
        identical(result!.tree, b),
        isTrue,
        reason: 'tree root collapses to the surviving sibling',
      );
      expect(
        identical(result.focused, b),
        isTrue,
        reason: 'focus transfers to the surviving sibling',
      );
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

      final result = applyCloseSurfaceForTest(outerSplit, a, a.surfaces.first);
      expect(result, isNotNull);
      // Tree root is unchanged (outerSplit), but a is gone.
      expect(identical(result!.tree, outerSplit), isTrue);
      // CRITICAL: focused must NOT be the disposed `a`.
      expect(
        identical(result.focused, a),
        isFalse,
        reason:
            'a was disposed; pointing _focusedContainer at it would '
            'break Ctrl+Shift+K, visual focus indicator, and '
            'focusCurrentPane()',
      );
      // Focused should be the first reachable leaf (B in this layout).
      expect(identical(result.focused, b), isTrue);
    });

    test('non-collapsing close (owner keeps other surfaces): '
        'focused = owner', () {
      final a = PaneContainer()..surfaces.addAll([Surface(), Surface()]);
      final b = PaneContainer()..surfaces.add(Surface());
      final split = PaneSplit(direction: Axis.horizontal, first: a, second: b);

      final result = applyCloseSurfaceForTest(split, a, a.surfaces[0]);
      expect(result, isNotNull);
      expect(identical(result!.tree, split), isTrue);
      expect(identical(result.focused, a), isTrue);
      // focusedIndex clamped to the new last surface.
      expect(a.focusedIndex, 0);
    });
  });

  group('ContainerTabBarState.computeEnsureVisibleTargetOffset', () {
    // Helper to keep the test table compact. `minOffset` is 0
    // (the leading edge of a normal scrollable); `maxOffset` is
    // whatever the caller computes (e.g. total chip width minus
    // viewport width).
    double? run({
      required double chipLeft,
      required double chipWidth,
      required double listViewWidth,
      required double currentOffset,
      required double maxOffset,
    }) {
      return ContainerTabBarState.computeEnsureVisibleTargetOffset(
        chipLeft: chipLeft,
        chipWidth: chipWidth,
        listViewWidth: listViewWidth,
        currentOffset: currentOffset,
        minOffset: 0,
        maxOffset: maxOffset,
      );
    }

    test('chip fully visible at left edge → null (no scroll)', () {
      // chip occupies [0, 100] inside a 200-wide viewport; nothing
      // hidden on either side.
      expect(
        run(
          chipLeft: 0,
          chipWidth: 100,
          listViewWidth: 200,
          currentOffset: 0,
          maxOffset: 500,
        ),
        isNull,
      );
    });

    test('chip fully visible in the middle → null (no scroll)', () {
      // chip occupies [50, 150] inside a 200-wide viewport; nothing
      // hidden on either side.
      expect(
        run(
          chipLeft: 50,
          chipWidth: 100,
          listViewWidth: 200,
          currentOffset: 0,
          maxOffset: 500,
        ),
        isNull,
      );
    });

    test('chip exactly flush with right edge → null (still visible)', () {
      // chipRight == listViewWidth means the chip's right edge
      // meets the viewport's right edge — still fully visible, no
      // need to scroll.
      expect(
        run(
          chipLeft: 100,
          chipWidth: 100,
          listViewWidth: 200,
          currentOffset: 0,
          maxOffset: 500,
        ),
        isNull,
      );
    });

    test('chip off-screen to the LEFT scrolls it to the leading edge', () {
      // chip is 50px past the left edge of the viewport; current
      // scroll is 100. Absolute chip position = 50, so scroll to
      // 50 to put the chip at the leading edge.
      expect(
        run(
          chipLeft: -50,
          chipWidth: 100,
          listViewWidth: 200,
          currentOffset: 100,
          maxOffset: 500,
        ),
        50.0,
      );
    });

    test('chip off-screen to the LEFT at scroll 0 clamps to 0', () {
      // Already at the leftmost position; can't scroll further
      // negative. Result is 0 (chip will sit at viewport's left
      // edge with its tail still hidden — same as the click
      // handler's behavior on the trailing clamp).
      expect(
        run(
          chipLeft: -50,
          chipWidth: 100,
          listViewWidth: 200,
          currentOffset: 0,
          maxOffset: 500,
        ),
        0.0,
      );
    });

    test('chip off-screen to the RIGHT scrolls it to the trailing edge', () {
      // chip occupies [250, 350] in absolute coords; viewport is
      // [0, 200]. To put the chip's right edge at the viewport's
      // right edge: newOffset = 250 + 100 - 200 = 150.
      expect(
        run(
          chipLeft: 250,
          chipWidth: 100,
          listViewWidth: 200,
          currentOffset: 0,
          maxOffset: 500,
        ),
        150.0,
      );
    });

    test('chip off-screen to the RIGHT when already at max clamps to max', () {
      // Current offset is the maxScrollExtent, so we can't scroll
      // further right. The result must not exceed maxOffset, and
      // the chip will be left slightly past the trailing edge —
      // same trade-off as the off-left-at-zero case.
      expect(
        run(
          chipLeft: 550,
          chipWidth: 100,
          listViewWidth: 200,
          currentOffset: 500,
          maxOffset: 500,
        ),
        500.0,
      );
    });

    test('chip off-right while partially past current viewport mid-scroll', () {
      // viewport is [100, 300]; chip is at [350, 450]. Scrolling
      // so the chip's right edge is at viewport's right edge:
      // newOffset = 100 + (350 + 100 - 200) = 350. (chipLeft here
      // is 350 - 100 = 250; the math is chipLeft + chipWidth -
      // listViewWidth = 150, currentOffset 100 + 150 = 250.)
      expect(
        run(
          chipLeft: 250,
          chipWidth: 100,
          listViewWidth: 200,
          currentOffset: 100,
          maxOffset: 500,
        ),
        250.0,
      );
    });
  });
}
