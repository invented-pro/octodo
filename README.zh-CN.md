# <img src="assets/logo.png" alt="Octodo Logo" align="top" width="40" /> Octodo

**为 CLI 重度玩家打造的终端复合体。**

一个基于 Rust + Flutter 原生构建的多工作区终端复合体，面向 Windows 与 macOS。不是臃肿的网页套壳——内存太贵了，你的时间和注意力也一样。

[English](./README.md) | 简体中文

[![Release](https://img.shields.io/github/v/release/invented-pro/octodo)](https://github.com/invented-pro/octodo/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE) [![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-0078d4)](https://github.com/invented-pro/octodo/releases/latest)

---

## 简介

`Octodo` 将多个终端装进同一个窗口，组成一个个工作区。每个工作区运行各自的 shell 会话、标签与分屏——让你可以假装同时掌控着它们全部。

<img src="docs/images/Screenshot1.png" alt="Octodo 界面" align="center" width="100%" />

---

## 功能亮点

- **Rust 级速度**
  - 由 **Alacritty** GPU 渲染器驱动。
  - 亚毫秒级按键渲染，零卡顿。
- **Flutter 原生 UI**
  - 流畅的多窗格、多标签布局。
  - 为 **Windows** 与 **macOS** 原生构建。
- **键盘优先，鼠标也顺手**
  - 以键盘快捷键为核心驱动。
  - 配备鼠标**划选即复制**与**右键即粘贴**——左手忙着端咖啡时也能操作。
- **自动发现**
  - 自动检测主机上所有可用的 shell。
  - 开箱即用支持 **WSL** 发行版。
- **多语言支持**
  - 完整 **IME 输入法支持**，多语言输入无碍。
- **自我维护**
  - 静默的应用内**自动升级**。
  - 无需手动下载更新。

---

## 平台支持

| #   | 平台                 | 状态          |
| --- | -------------------- | ------------- |
| 1   | Windows              | ✅            |
| 2   | macOS (Apple Silicon) | ✅            |
| 3   | Linux                | ⏳ 即将推出   |

---

## 使用与安装

应用内更新器会自动适配：Microsoft Store 与 App Store 版本经由对应商店更新；直接下载版安全地自动应用最新 GitHub 发布（下载 → SHA-256 校验 → 热替换 → 重启）。

### Windows

#### Microsoft Store
直接从 [Microsoft Store](https://apps.microsoft.com/detail/9PJ4NR9XL3ZQ) 安装。更新在后台自动完成。

#### 便携版（.zip）
1. 从 [最新发布](https://github.com/invented-pro/octodo/releases/latest) 下载 `octodo-v<version>-windows-x64.zip`。
2. 右键 zip 文件 → **属性** → 勾选 **解除锁定** → **确定**。*（关键步骤：避免 Windows 拦截网络与 shell 启动相关的 API。）*
3. 解压到任意目录，运行 `octodo.exe`。

### macOS（Apple Silicon）

#### 直接下载（.dmg）
1. 从 [最新发布](https://github.com/invented-pro/octodo/releases/latest) 下载 `Octodo-v<version>-macos-arm64.dmg`。
2. 挂载 DMG，将 `Octodo.app` 拖入**应用程序（Applications）**文件夹。
3. 若首次启动被 Gatekeeper 拦截，在终端执行以下命令清除隔离属性：
   ```bash
   xattr -dr com.apple.quarantine /Applications/Octodo.app
   ```

#### Mac App Store
*即将上线。* 商店版将通过 App Store 自动更新。

---

## 从源码构建

### 前置要求
* **Flutter SDK**（`>= 3.44.0`）
* **Rust 工具链**（通过 [rustup.rs](https://rustup.rs) 安装）
* **平台构建工具**：
  * **Windows**：Windows 10/11，安装 Visual Studio（**使用 C++ 的桌面开发**工作负载）。
  * **macOS**：Xcode Command Line Tools。

### 编译步骤
```bash
git clone https://github.com/invented-pro/octodo.git
cd octodo
flutter pub get
flutter run -d windows    # Windows 主机
# 或
flutter run -d macos      # macOS 主机
```
单元测试、lint 规范与 fork 补丁工作流请见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

---

## 键盘快捷键

### 工作区（侧边栏）

| Windows              | macOS               | 动作                             |
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

| Windows        | macOS         | 动作                     |
| -------------- | ------------- | ------------------------ |
| `Ctrl+Shift+D` | `Cmd+Shift+D` | 垂直分屏（右侧）         |
| `Ctrl+Shift+E` | `Cmd+Shift+E` | 水平分屏（下方）         |
| `Ctrl+Shift+↑` | `Cmd+Shift+↑` | 焦点移到上方窗格         |
| `Ctrl+Shift+↓` | `Cmd+Shift+↓` | 焦点移到下方窗格         |
| `Ctrl+Shift+←` | `Cmd+Shift+←` | 焦点移到左侧窗格         |
| `Ctrl+Shift+→` | `Cmd+Shift+→` | 焦点移到右侧窗格         |
| `Ctrl+Shift+M` | `Cmd+Shift+M` | 最大化 / 还原聚焦窗格    |

### 标签（聚焦窗格内）

| Windows          | macOS          | 动作                   |
| ---------------- | -------------- | ---------------------- |
| `Ctrl+Shift+T`   | `Cmd+Shift+T`  | 在聚焦窗格打开新标签   |
| `Ctrl+Shift+K`   | `Cmd+Shift+K`  | 关闭当前标签           |
| `Ctrl+Tab`       | `Cmd+Option+→` | 切到下一个标签         |
| `Ctrl+Shift+Tab` | `Cmd+Option+←` | 切到上一个标签         |
| `Ctrl+1` … `9`   | `Cmd+1` … `9`  | 直接跳转到第 N 个标签  |

### 终端引擎（剪贴板与缩放）

| Windows                        | macOS                        | 动作               |
| ------------------------------ | ---------------------------- | ------------------ |
| `Ctrl+Shift+C` / `Ctrl+Insert` | `Cmd+Shift+C` / `Cmd+Insert` | 复制选中内容       |
| `Ctrl+V` / `Ctrl+Shift+V`      | `Cmd+V` / `Cmd+Shift+V`      | 从剪贴板粘贴       |
| `Shift+Insert`                 | `Shift+Insert`               | 备选粘贴方式       |
| `PageUp` / `PageDown`          | `PageUp` / `PageDown`        | 上下翻一页         |
| `Ctrl+=`                       | `Cmd+=`                      | 放大字体           |
| `Ctrl+-`                       | `Cmd+-`                      | 缩小字体           |
| `Ctrl+0`                       | `Cmd+0`                      | 重置字体缩放       |

---

## 致谢

衷心感谢 [Alacritty](https://github.com/alacritty/alacritty) 团队打造出如此轻量、快速、优雅的杰作，为本项目提供了终端仿真与硬件加速渲染（基于 MPL-2.0 许可证）。

## 许可证

基于 **MIT 许可证** 发布，完整文本请见 [`LICENSE`](./LICENSE)。
