# Contributing to Octodo

Thanks for your interest — `Octodo` is still early-stage, and any help
(bug reports, feature ideas, docs, code) is welcome.

## Reporting bugs & requesting features

Open a [GitHub Issue](../../issues). For bugs, please include:

- Windows version and Flutter version (`flutter --version`).
- Steps to reproduce, plus expected vs. actual behaviour.
- Any relevant logs from `%APPDATA%\Octodo\logs\` (if produced).

## Development setup

Prerequisites: Flutter SDK `>= 3.44.0`, the Rust toolchain (installed
via [rustup](https://rustup.rs/)), and Windows 10/11 with the
**Desktop development with C++** Visual Studio workload.

```bash
git clone https://github.com/invented-pro/octodo.git
cd octodo
flutter pub get
flutter test
flutter run -d windows
```

## Code style

- `flutter_lints` is the baseline (`analysis_options.yaml`).
- `flutter analyze` must be clean before opening a PR.
- Add or update tests under `test/` for any behaviour change.
- Keep `lib/src/` UI-free; UI lives under `lib/ui/`.

## Pull requests

1. Fork → feature branch (`feat/short-name` or `fix/short-name`).
2. Run `flutter analyze` and `flutter test` locally — both must pass.
3. Keep commits focused; write a clear PR description that links
   any related issue.

## License

By contributing, you agree that your contributions will be licensed
under the [MIT License](./LICENSE).

## Vendored forks

`Octodo` depends on two patched forks of upstream packages, declared
as direct `git:` dependencies in `pubspec.yaml`:

| Package | Upstream | Our fork | Patch |
|---|---|---|---|
| `flutter_pty` 0.4.2 | [TerminalStudio/flutter_pty](https://github.com/TerminalStudio/flutter_pty) | [invented-pro/flutter_pty](https://github.com/invented-pro/flutter_pty) | remove 1 s `Sleep` in `pty_create` |
| `flutter_alacritty` 2.1.0 | [hhoao/flutter_alacritty](https://github.com/hhoao/flutter_alacritty) | [invented-pro/flutter_alacritty](https://github.com/invented-pro/flutter_alacritty) | add `setComposingRect` for Windows IME caret positioning |

**Tagging convention**: each patch is tagged by the date it was applied
(`YYYY.MM.DD`, e.g. `2026.07.01`). If a patch needs to be re-applied or
rebased on the same day, append `-1`, `-2`, …. The tag is decoupled from
this app's version so renames don't churn pinned refs.

**Updating the patches**:

1. Fork the upstream repo under your GitHub account.
2. Apply the patch on a branch, push, open a PR upstream — link the PR
   from the fork commit so reviewers can see the upstream discussion.
3. Bump the tag in our fork (same `YYYY.MM.DD` style) and update the
   `ref:` in `pubspec.yaml`.
4. The forks are kept public; no auth configuration is required to
   consume them.

**When the upstream PR is merged**: rebase the fork onto upstream's
`main`, drop the patch commit, push the same `YYYY.MM.DD` tag forward
(or a new date tag if you prefer), and remove the `git:` override in
`pubspec.yaml`.