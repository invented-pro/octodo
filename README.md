# <img src="assets/logo.png" alt="Octodo Logo" align="top" width="40" /> Octodo

**A Terminal Complex for CLI-Maxing Developers.**

A multi-workspace terminal complex built natively on Rust + Flutter for Windows and macOS. Not a bloated web wrapper—RAM is too expensive, same as your time and attention.

English | [中文简体](./README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/invented-pro/octodo)](https://github.com/invented-pro/octodo/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE) [![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-0078d4)](https://github.com/invented-pro/octodo/releases/latest)

---

## Overview

`Octodo` packs multi-terminals right into a single window as workspace. Each workspace  runs its own shell sessions, tabs, and split panes—so you can pretend you know exactly what is happening in all of them at once. 

<img src="docs/images/Screenshot1.png" alt="Octodo Interface" align="center" width="100%" />

---

## Highlights

- **Rust-Fueled Speed**
  - Powered by **Alacritty** GPU renderer.
  - Sub-millisecond keystroke rendering, zero stutter.
- **Flutter-Native UI**
  - Fluid, multi-pane-tab layouts. 
  - Natively built for **Windows** and **macOS**.
- **Keyboard First, Mouse Matters**
  - Keyboard shortcuts driven.
  - Mouse **select-to-copy** and **right-click-to-paste** for when your left hand is busy holding coffee.
- **Auto-Discovery**
  - Auto detects all available local shells.
  - Friendly with **WSL** distributions out of box.
- **Multilingual Support**
  - Full **IME support** for multi-language typing.
- **Self-Maintaining**
  - Silent, in-app **auto-upgrade**. 
  - No manual fetching required.

---

## Platform Support

| #   | Platform              | Status        |
| --- | --------------------- | ------------- |
| 1   | Windows               | ✅             |
| 2   | macOS (Apple Silicon) | ✅             |
| 3   | Linux                 | ⏳ Coming Soon |

---

## Usage & Installation

The in-app updater adapts automatically: Microsoft Store and App Store builds update via their respective marketplaces. Direct-download builds self-apply the latest GitHub releases securely (Download → SHA-256 Verification → Hot Swap → Relaunch).

### Windows

#### Microsoft Store
Install directly from the [Microsoft Store](https://apps.microsoft.com/detail/9PJ4NR9XL3ZQ). Updates handle themselves automatically in the background.

#### Portable (.zip)
1. Download `octodo-v<version>-windows-x64.zip` from [Latest Releases](https://github.com/invented-pro/octodo/releases/latest).
2. Right-click the zip → **Properties** → check **Unblock** → Click **OK**. *(Crucial: This prevents Windows from blocking network and shell-spawn APIs).*
3. Extract anywhere and run `octodo.exe`.

### macOS (Apple Silicon)

#### Direct Download (.dmg)
1. Download `Octodo-v<version>-macos-arm64.dmg` from [Latest Releases](https://github.com/invented-pro/octodo/releases/latest).
2. Mount the DMG and drag `Octodo.app` into your **Applications** folder.
3. If Gatekeeper blocks execution on first launch, clear the quarantine attribute via terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Octodo.app
   ```

#### Mac App Store
*Coming soon.* Store builds will update automatically through the App Store ecosystem.

---

## Build From Source

### Prerequisites
* **Flutter SDK** (`>= 3.44.0`)
* **Rust Toolchain** (Installed via [rustup.rs](https://rustup.rs))
* **Platform Build Tools**: 
  * **Windows**: Windows 10/11 with Visual Studio (**Desktop development with C++** workload).
  * **macOS**: Xcode Command Line Tools.

### Compilation steps
```bash
git clone https://github.com/invented-pro/octodo.git
cd octodo
flutter pub get
flutter run -d windows    # For Windows hosts
# or
flutter run -d macos      # For macOS hosts
```
See [CONTRIBUTING.md](./CONTRIBUTING.md) for unit tests, lint policies, and our fork-patch workflow.

---

## Keyboard Shortcuts

### Workspaces (Sidebar)

| Windows              | macOS               | Action                                          |
| -------------------- | ------------------- | ----------------------------------------------- |
| `Ctrl+Shift+B`       | `Cmd+Shift+B`       | Toggle workspace drawer                         |
| `Ctrl+Shift+N`       | `Cmd+Shift+N`       | Create new workspace (auto-focus)               |
| `Ctrl+Shift+W`       | `Cmd+Shift+W`       | Close current workspace (requires confirmation) |
| `Ctrl+Shift+]`       | `Cmd+Shift+]`       | Next workspace (cyclic)                         |
| `Ctrl+Shift+[`       | `Cmd+Shift+[`       | Previous workspace (cyclic)                     |
| `Ctrl+Shift+1` … `9` | `Cmd+Shift+1` … `9` | Jump directly to workspace N                    |
| `F11`                | `Ctrl+Cmd+F`        | Toggle fullscreen mode                          |
| `Ctrl+Shift+Q`       | `Cmd+Shift+Q`       | Quit application                                |

### Panes (Splitting & Focus)

| Windows        | macOS         | Action                                 |
| -------------- | ------------- | -------------------------------------- |
| `Ctrl+Shift+D` | `Cmd+Shift+D` | Split focused pane vertically (Right)  |
| `Ctrl+Shift+E` | `Cmd+Shift+E` | Split focused pane horizontally (Down) |
| `Ctrl+Shift+↑` | `Cmd+Shift+↑` | Move focus to pane above               |
| `Ctrl+Shift+↓` | `Cmd+Shift+↓` | Move focus to pane below               |
| `Ctrl+Shift+←` | `Cmd+Shift+←` | Move focus to pane on the left         |
| `Ctrl+Shift+→` | `Cmd+Shift+→` | Move focus to pane on the right        |
| `Ctrl+Shift+M` | `Cmd+Shift+M` | Maximize / Restore focused pane        |

### Tabs (Inside Focus Pane)

| Windows          | macOS          | Action                       |
| ---------------- | -------------- | ---------------------------- |
| `Ctrl+Shift+T`   | `Cmd+Shift+T`  | Open new tab in focused pane |
| `Ctrl+Shift+K`   | `Cmd+Shift+K`  | Close active tab             |
| `Ctrl+Tab`       | `Cmd+Option+→` | Cycle to next tab            |
| `Ctrl+Shift+Tab` | `Cmd+Option+←` | Cycle to previous tab        |
| `Ctrl+1` … `9`   | `Cmd+1` … `9`  | Jump directly to tab N       |

### Terminal Engine (Clipboard & Zoom)

| Windows                        | macOS                        | Action                      |
| ------------------------------ | ---------------------------- | --------------------------- |
| `Ctrl+Shift+C` / `Ctrl+Insert` | `Cmd+Shift+C` / `Cmd+Insert` | Copy active selection       |
| `Ctrl+V` / `Ctrl+Shift+V`      | `Cmd+V` / `Cmd+Shift+V`      | Paste from clipboard        |
| `Shift+Insert`                 | `Shift+Insert`               | Alternative paste           |
| `PageUp` / `PageDown`          | `PageUp` / `PageDown`        | Scroll view by single page  |
| `Ctrl+=`                       | `Cmd+=`                      | Increase font scale         |
| `Ctrl+-`                       | `Cmd+-`                      | Decrease font scale         |
| `Ctrl+0`                       | `Cmd+0`                      | Reset font scale to default |

---

## Desktop Notifications

Octodo watches every terminal for "needs attention" signals and posts a native desktop notification (with the Octodo icon) when you're not looking at that terminal. Clicking the notification jumps straight back to the workspace → pane → tab that raised it. Controlled by **Settings → General → Desktop notifications** (on by default), with a sub-item for the minimum task duration.

### What triggers a notification

| Source | Fires when | Notes |
| ------ | ---------- | ----- |
| OSC 9 / OSC 777 / OSC 99 (kitty) | A tool or script emits a notification escape sequence | Agents (opencode, Claude Code, Codex CLI) and build scripts — see recipes below |
| BEL | A terminal emits the bell character | Gated by `Terminal → Bell ≠ none` |
| OSC 133 (shell integration) | A command you ran finishes | Octodo injects the marks into bash / zsh / fish / PowerShell prompts; only commands longer than the threshold (default 10 s) notify. CMD and Nushell are not covered |

### Notifying from your own tools

```bash
# OSC 777 (title + body)
printf '\e]777;notify;Build Complete;All tests passed\e\\'

# OSC 9 (body only)
printf '\e]9;deploy done\e\\'

# OSC 99 (kitty protocol; title chunk + body chunk)
printf '\e]99;i=mytask:d=0;Build\e\\'
printf '\e]99;i=mytask:p=body:d=1;All tests passed\e\\'
```

```python
import sys
sys.stdout.write("\x1b]777;notify;opencode;waiting for input\x07")
sys.stdout.flush()
```

### opencode

opencode's TUI has a built-in attention system — sounds and terminal notifications for *question needs input*, *permission needs input*, *session error*, and *session done* — but it is **disabled by default**. Enable it in `~/.config/opencode/tui.json`:

```json
{
  "$schema": "https://opencode.ai/tui.json",
  "attention": { "enabled": true }
}
```

Octodo implements both halves of the terminal contract opencode needs: it answers the kitty OSC 99 capability probe (how opencode delivers notifications) and reports terminal focus (`CSI I` / `CSI O`, DECSET 1004) so opencode knows the session is blurred — without focus reports opencode stays in an "unknown" focus state and silently drops every notification.

### Claude Code hook

`~/.claude/settings.json` — notify when a session finishes:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "printf '\\e]777;notify;Claude Code;session complete\\a'"
          }
        ]
      }
    ]
  }
}
```

Notifications are suppressed while you're looking at the terminal that raised them; unread counts show as a dot on the tab, a badge on the workspace tile, and a macOS dock / Windows taskbar badge.

### Banners that don't vanish

macOS and Windows both auto-dismiss native banners after a few seconds. Octodo layers four mechanisms so an unattended notification stays impossible to miss:

- **Persistent in-app banners** — every notification also shows as a card in the top-right corner of the Octodo window, where it stays until you click it (jump to the terminal) or dismiss it. Repeated events from the same terminal coalesce into one card with a ×N counter.
- **Re-alert until read** — while a notification is still unread and Octodo is in the background, the banner is re-posted every 30 seconds (same id, so Notification Center replaces instead of stacking) until you click it, open the terminal, or swipe it away. Controlled by **Settings → General → Keep re-alerting until read**.
- **Dock bounce (macOS)** — a banner posted while Octodo is backgrounded also bounces the dock icon until you switch over.
- **"Alerts" style (macOS)** — for a banner that literally never auto-dismisses, switch Octodo to *Alerts* in System Settings → Notifications. **Settings → General → Open system notification settings** takes you there directly.

---

## Acknowledgments

Sincere thanks to the [Alacritty](https://github.com/alacritty/alacritty) team for creating such a lightweight, fast, and elegant masterpiece to power our terminal emulation and hardware-accelerated rendering (licensed under MPL-2.0).

## License

Released under the **MIT License**. See [`LICENSE`](./LICENSE) for the full text.
