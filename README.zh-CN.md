# <img src="assets/logo.png" alt="Octodo Logo" align="top" width="40" /> Octodo

**为 CLI 重度玩家打造的终端复合体。**

一个原生基于 Rust + Flutter 构建、面向 Windows、macOS 与 Linux 的多工作区终端复合体。不是臃肿的网页套壳——内存寸土寸金，你的注意力亦然。

[English](./README.md) | 简体中文

[![Release](https://img.shields.io/github/v/release/invented-pro/octodo)](https://github.com/invented-pro/octodo/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE) [![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-0078d4)](https://github.com/invented-pro/octodo/releases/latest)

---

## 简介

`Octodo` 将多个终端装进同一个窗口，组成一个个工作区。每个工作区运行各自的 shell 会话、标签与分屏——让你可以假装同时掌控着它们全部。

<img src="docs/images/Screenshot1.png" alt="Octodo 界面" align="center" width="100%" />

---

## 功能亮点

- **Rust 驱动的速度 + 流畅的 Flutter UI**
  - 基于 **Alacritty** 内核的即时 GPU 渲染，零卡顿表现。
  - 流畅的多窗格布局与灵活的标签管理。
  - 为 **Windows**、**macOS** 与 **Linux** 原生构建并优化。
- **键盘优先，鼠标也顺手**
  - 闪电般的快捷键驱动导航。
  - 顺滑的**划选即复制**与**右键即粘贴**，支持**拖拽**重排标签。
- **智能通知**
  - 长时任务完成时即刻推送通知。
  - 集成智能体监控，让你随时掌握状态。
- **零配置自动发现**
  - 开箱即用，自动检测所有本地 shell。
  - **WSL** 发行版自动集成。
- **全局多语言支持**
  - 完整、原生兼容多语言 IME 输入。
- **省心的自我维护**
  - Windows、macOS 与 Linux 均支持无摩擦的**应用内自动升级**。


---

## 平台支持

| #   | 平台                  | 状态          |
| --- | --------------------- | ------------- |
| 1   | Windows               | ✅            |
| 2   | macOS (Apple Silicon) | ✅            |
| 3   | Linux (x64)           | ✅            |
| 4   | Linux (arm64)         | ⏳ 即将推出   |

---

## 使用与安装


### Windows

- 从 [Microsoft Store](https://apps.microsoft.com/detail/9PJ4NR9XL3ZQ) 安装。**推荐**
- Msix 安装包
  * 从 [最新发布](https://github.com/invented-pro/octodo/releases/latest) 下载 `Octodo-v<version>-windows-x64.Msix`。
  * 双击 Msix 文件即可安装。
- 便携版
  * 从 [最新发布](https://github.com/invented-pro/octodo/releases/latest) 下载 `octodo-v<version>-windows-x64.zip`。
  * 右键 zip 文件 → **属性** → 勾选 **解除锁定** → **确定**。
     >- **此举可避免 Windows 拦截网络与 shell 启动相关的 API。**
  * 解压到任意目录，运行 `octodo.exe`。

### macOS（Apple Silicon）

- 从 [最新发布](https://github.com/invented-pro/octodo/releases/latest) 下载 `Octodo-v<version>-macos-arm64.dmg`。
- 双击 dmg 文件，将 `Octodo.app` 拖入**应用程序（Applications）**。
    > 若首次启动被 Gatekeeper 拦截，可在终端执行以下命令清除隔离属性：
    >> ```bash
    >> xattr -dr com.apple.quarantine /Applications/Octodo.app
    >> ```

### Linux（x64）

- 从 [最新发布](https://github.com/invented-pro/octodo/releases/latest) 下载 `octodo-v<version>-linux-x64.AppImage`。
- 添加可执行权限后运行：
    ```bash
    chmod +x octodo-v<version>-linux-x64.AppImage
    ./octodo-v<version>-linux-x64.AppImage
    ```
    >- 若 AppImage 无法启动，请通过包管理器安装 **FUSE 2**（`libfuse2`），或改用 `--appimage-extract-and-run` 运行。
    >- 可选：对照发布侧附带的 `.sha256` 校验文件验证下载。
    >- arm64 版本即将推出——受限于 Flutter 尚未发布 linux-arm64 SDK。

---

## 从源码构建

### 前置要求
* **Flutter SDK**（`>= 3.44.0`）
* **Rust 工具链**（通过 [rustup.rs](https://rustup.rs) 安装）
* **平台构建工具**：
  * **Windows**：Windows 10/11，安装 Visual Studio（**使用 C++ 的桌面开发**工作负载）。
  * **Linux**：Clang、CMake、Ninja 与 GTK3 开发头文件（如 `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev`）。
  * **macOS**：Xcode Command Line Tools。

### 编译步骤
```bash
git clone https://github.com/invented-pro/octodo.git
cd octodo
flutter pub get
flutter run -d windows    # Windows 主机
# 或
flutter run -d linux      # Linux 主机
# 或
flutter run -d macos      # macOS 主机
```
单元测试、lint 规范与 fork 补丁工作流请见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

---

## 键盘快捷键

### 工作区（侧边栏）

| Windows / Linux      | macOS               | 动作                             |
| -------------------- | ------------------- | -------------------------------- |
| `Ctrl+Shift+B`       | `Cmd+Shift+B`       | 切换工作区抽屉                   |
| `Ctrl+Shift+N`       | `Cmd+Shift+N`       | 新建工作区（自动聚焦）           |
| `Ctrl+Shift+W`       | `Cmd+Shift+W`       | 关闭当前工作区（需确认）         |
| `Ctrl+Shift+]`       | `Cmd+Shift+]`       | 下一个工作区（循环）             |
| `Ctrl+Shift+[`       | `Cmd+Shift+[`       | 上一个工作区（循环）             |
| `Ctrl+Shift+1` … `9` | `Cmd+Shift+1` … `9` | 直接跳转到第 N 个工作区          |
| `F11`                | `Ctrl+Cmd+F`        | 切换全屏模式                     |
| `Ctrl+Shift+Q`       | `Cmd+Shift+Q`       | 退出应用                         |

### 窗格（分屏与焦点）

| Windows / Linux  | macOS         | 动作                     |
| ---------------- | ------------- | ------------------------ |
| `Ctrl+Shift+D` | `Cmd+Shift+D` | 垂直分屏（右侧）         |
| `Ctrl+Shift+E` | `Cmd+Shift+E` | 水平分屏（下方）         |
| `Ctrl+Shift+↑` | `Cmd+Shift+↑` | 焦点移到上方窗格         |
| `Ctrl+Shift+↓` | `Cmd+Shift+↓` | 焦点移到下方窗格         |
| `Ctrl+Shift+←` | `Cmd+Shift+←` | 焦点移到左侧窗格         |
| `Ctrl+Shift+→` | `Cmd+Shift+→` | 焦点移到右侧窗格         |
| `Ctrl+Shift+M` | `Cmd+Shift+M` | 最大化 / 还原聚焦窗格    |

### 标签（聚焦窗格内）

| Windows / Linux  | macOS          | 动作                   |
| ---------------- | -------------- | ---------------------- |
| `Ctrl+Shift+T`   | `Cmd+Shift+T`  | 在聚焦窗格打开新标签   |
| `Ctrl+Shift+K`   | `Cmd+Shift+K`  | 关闭当前标签           |
| `Ctrl+Tab`       | `Cmd+Option+→` | 切到下一个标签         |
| `Ctrl+Shift+Tab` | `Cmd+Option+←` | 切到上一个标签         |
| `Ctrl+1` … `9`   | `Cmd+1` … `9`  | 直接跳转到第 N 个标签  |

### 终端引擎（剪贴板与缩放）

| Windows / Linux               | macOS                        | 动作               |
| ------------------------------ | ---------------------------- | ------------------ |
| `Ctrl+Shift+C` / `Ctrl+Insert` | `Cmd+Shift+C` / `Cmd+Insert` | 复制选中内容       |
| `Ctrl+V` / `Ctrl+Shift+V`      | `Cmd+V` / `Cmd+Shift+V`      | 从剪贴板粘贴       |
| `Shift+Insert`                 | `Shift+Insert`               | 备选粘贴方式       |
| `PageUp` / `PageDown`          | `PageUp` / `PageDown`        | 上下翻一页         |
| `Ctrl+=`                       | `Cmd+=`                      | 放大字体           |
| `Ctrl+-`                       | `Cmd+-`                      | 缩小字体           |
| `Ctrl+0`                       | `Cmd+0`                      | 重置字体缩放       |

---

## 桌面通知

Octodo 会监听每个终端发出的「需要关注」信号，并在你未注视该终端时推送一条带 Octodo 图标的原生桌面通知。点击通知可直接跳回发出通知的工作区 → 窗格 → 标签。该功能由 **设置 → 通用 → 桌面通知** 控制（默认开启），并包含一个用于设置最小任务时长的子项。

### 触发通知的来源

| 来源 | 触发条件 | 备注 |
| ------ | ---------- | ----- |
| OSC 9 / OSC 777 / OSC 99 (kitty) | 工具或脚本发出通知转义序列 | 代理（opencode、Claude Code、Codex CLI）与构建脚本——参见下方示例 |
| BEL | 终端发出响铃字符 | 受 `Terminal → Bell ≠ none` 控制 |
| OSC 133（shell 集成） | 你运行的命令执行完成 | Octodo 会向 bash / zsh / fish / PowerShell 提示符注入标记；只有超过阈值（默认 10 秒）的命令才会通知。CMD 与 Nushell 不在此列 |

### 从你自己的工具中发送通知

```bash
# OSC 777（标题 + 正文）
printf '\e]777;notify;Build Complete;All tests passed\e\\'

# OSC 9（仅正文）
printf '\e]9;deploy done\e\\'

# OSC 99（kitty 协议；标题片段 + 正文片段）
printf '\e]99;i=mytask:d=0;Build\e\\'
printf '\e]99;i=mytask:p=body:d=1;All tests passed\e\\'
```

```python
import sys
sys.stdout.write("\x1b]777;notify;opencode;waiting for input\x07")
sys.stdout.flush()
```

### opencode

opencode 的 TUI 内置了一套关注系统——会针对*问题需要输入*、*权限需要授权*、*会话出错*与*会话结束*发出声音与终端通知，但**默认处于关闭状态**。可在 `~/.config/opencode/tui.json` 中启用：

```json
{
  "$schema": "https://opencode.ai/tui.json",
  "attention": { "enabled": true }
}
```

Octodo 实现了 opencode 所需的终端契约的两端：一方面响应 kitty OSC 99 能力探测（opencode 借此投递通知），另一方面上报终端焦点状态（`CSI I` / `CSI O`，DECSET 1004），让 opencode 知道会话已失焦——如果不上报焦点，opencode 将停留在「未知」焦点状态并静默丢弃所有通知。

### Claude Code hook

在 `~/.claude/settings.json` 中——会话结束时发送通知：

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

当你的视线停留在发出通知的终端上时，通知会被抑制；未读计数会在标签上显示一个小圆点，在工作区磁贴上显示徽标，并在 macOS Dock 与 Windows 任务栏上显示徽章。

### 不会消失的横幅

Windows、macOS 与 Linux 都会在数秒后自动关闭原生横幅。Octodo 叠加了四层机制，确保即便无人值守，通知也不可能被错过：

- **应用内持久横幅**——每条通知同时会在 Octodo 窗口右上角以卡片形式展示，直到你点击（跳转到对应终端）或主动关闭。来自同一终端的重复事件会合并为一张带 ×N 计数的卡片。
- **未读前持续提醒**——只要通知仍处于未读状态且 Octodo 处于后台，横幅就会每 30 秒重新推送一次（使用同一 id，因此通知中心会替换而非堆叠），直到你点击、打开终端或手动滑掉。可在 **设置 → 通用 → 未读前持续提醒** 中配置。
- **Dock 弹跳（macOS）**——在 Octodo 处于后台时发出的横幅会同时弹跳 Dock 图标，直到你切回应用。
- **「提醒」样式（macOS）**——如果希望横幅永不自动关闭，可在系统设置 → 通知中将 Octodo 切换为*提醒*样式。**设置 → 通用 → 打开系统通知设置** 可一键直达。

---

## 致谢

衷心感谢 [Alacritty](https://github.com/alacritty/alacritty) 团队打造出如此轻量、快速、优雅的杰作，为本项目提供了终端仿真与硬件加速渲染（基于 MPL-2.0 许可证）。

## 许可证

基于 **MIT 许可证** 发布，完整文本请见 [`LICENSE`](./LICENSE)。