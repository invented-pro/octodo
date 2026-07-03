# <img src="assets/logo.png" alt="" align="top" width="40" /> Octodo

A multi-workspace terminal complex, built on Flutter + Rust, for Windows.

English | [中文简体](./README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/invented-pro/octodo)](https://github.com/invented-pro/octodo/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-0078d4)](https://github.com/invented-pro/octodo/releases/latest)

---

## Overview

`Octodo` is a desktop terminal "complex" — a single window that hosts
multiple workspaces, each with its own shell sessions, split
panes, and tabs.  

<img src="docs/images/Screenshot1.png" alt="" align="center" width="100%" />

## Highlights

- **GPU-rendered terminal powered by Alacritty, a Rust-based renderer.**
- **Flutter-native multi-pane / tab layouts.** 
- **Keyboard-shortcut driven.** 
- **IME support.** 
- **Auto-detect available shells, including WSL distributions.** 


## Platform support

| # | Platform | Status |
| --- | --- | --- |
| 1 | Windows | ✅ |
| 2 | macOS | ❌ |
| 3 | Linux | ❌ |



## Usage

1. Download the latest `octodo-windows.zip` from
   [Releases](https://github.com/invented-pro/octodo/releases/latest).
2. Before unzipping, right-click the zip → **Properties** → tick
   **Unblock** → **OK**. This stops Windows from marking the unpacked
   `.exe` as untrusted (which would block network and shell-spawn APIs).
3. Unzip anywhere and double-click `octodo.exe` to launch.

To build from source instead, see below.

### Build from source

Requires the Flutter SDK (>= 3.44.0), the Rust toolchain (installed
via [rustup](https://rustup.rs/)), and Windows 10/11 with the
**Desktop development with C++** Visual Studio workload:

    git clone https://github.com/invented-pro/octodo.git
    cd octodo
    flutter pub get
    flutter run -d windows

See [CONTRIBUTING.md](./CONTRIBUTING.md) for tests, lint, and the
fork-patch workflow.

## Keyboard shortcuts


### Workspace (sidebar)

| Windows / Linux       | macOS                | Action                             |
|-----------------------|----------------------|------------------------------------|
| `Ctrl+Shift+B`        | `Cmd+Shift+B`        | Toggle the workspace drawer        |
| `Ctrl+Shift+N`        | `Cmd+Shift+N`        | New workspace (auto-focuses)       |
| `Ctrl+Shift+W`        | `Cmd+Shift+W`        | Close current workspace (confirm)  |
| `Ctrl+Shift+]`        | `Cmd+Shift+]`        | Next workspace (cyclic)            |
| `Ctrl+Shift+[`        | `Cmd+Shift+[`        | Previous workspace (cyclic)        |
| `Ctrl+Shift+1` … `9`  | `Cmd+Shift+1` … `9`  | Jump to workspace N                |
| `F11`                 | `Ctrl+Cmd+F`         | Toggle fullscreen                   |
| `Ctrl+Shift+Q`        | `Cmd+Shift+Q`        | Quit                               |

### Panes (split + focus)

| Windows / Linux       | macOS                | Action                             |
|-----------------------|----------------------|------------------------------------|
| `Ctrl+Shift+D`        | `Cmd+Shift+D`        | Split focused pane right           |
| `Ctrl+Shift+E`        | `Cmd+Shift+E`        | Split focused pane down            |
| `Ctrl+Shift+↑`        | `Cmd+Shift+↑`        | Focus pane above                   |
| `Ctrl+Shift+↓`        | `Cmd+Shift+↓`        | Focus pane below                   |
| `Ctrl+Shift+←`        | `Cmd+Shift+←`        | Focus pane to the left             |
| `Ctrl+Shift+→`        | `Cmd+Shift+→`        | Focus pane to the right            |
| `Ctrl+Shift+M`        | `Cmd+Shift+M`        | Toggle maximize focused pane       |


### Tabs (within a pane)

| Windows / Linux       | macOS                | Action                             |
|-----------------------|----------------------|------------------------------------|
| `Ctrl+Shift+T`        | `Cmd+Shift+T`        | New tab in focused pane            |
| `Ctrl+Shift+K`        | `Cmd+Shift+K`        | Close focused tab                  |
| `Ctrl+Tab`            | `Cmd+Option+→`       | Next tab in focused pane (cyclic)  |
| `Ctrl+Shift+Tab`      | `Cmd+Option+←`       | Previous tab in focused pane       |
| `Ctrl+1` … `9`        | `Cmd+1` … `9`        | Jump to tab N in focused pane      |



### Terminal (engine — clipboard, scroll)

| Windows / Linux       | macOS                | Action                             |
|-----------------------|----------------------|------------------------------------|
| `Ctrl+Shift+C`        | `Cmd+Shift+C`        | Copy selection                     |
| `Ctrl+Insert`         | `Cmd+Insert`         | Copy selection (alternative)       |
| `Ctrl+V`              | `Cmd+V`              | Paste                              |
| `Ctrl+Shift+V`        | `Cmd+Shift+V`        | Paste                              |
| `Shift+Insert`        | `Shift+Insert`       | Paste                              |
| `PageUp` / `PageDown` | `PageUp` / `PageDown`| Scroll one page                    |
| `Ctrl+=`              | `Cmd+=`              | Font Zoom in                       |
| `Ctrl+-`              | `Cmd+-`              | Font Zoom out                      |
| `Ctrl+0`              | `Cmd+0`              | Font Reset zoom                    |



## Acknowledgments

Terminal rendering powered by [Alacritty](https://github.com/alacritty/alacritty) (MPL-2.0).

## License

Released under the **MIT License**. See [`LICENSE`](./LICENSE) for
the full text.