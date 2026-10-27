# Fulcrum（支点）

一次按键，直达一切。macOS、Windows、Linux 三平台的键盘优先启动器——一个 Racket 大脑，三套第一方原生 UI，全程无 WebView。

[![CI](https://github.com/turinglambdaai/fulcrum/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/fulcrum/actions/workflows/ci.yml) ![Windows](https://img.shields.io/badge/Windows-WinUI_3-0078D4?logo=windows11&logoColor=white) ![macOS](https://img.shields.io/badge/macOS-SwiftUI-000000?logo=apple&logoColor=white) ![Linux](https://img.shields.io/badge/Linux-GTK4-F9A03C?logo=linux&logoColor=white) [![License](https://img.shields.io/badge/license-BUSL--1.1-blue)](LICENSE) ![Version](https://img.shields.io/badge/version-0.14.1-C15F3C)

[English](README.md) · **中文**

没用过启动器？从[用户指南](docs/user-guide.zh-CN.md)开始——它假设你从未用过这类产品。English users: [user guide](docs/user-guide.md)。

## 开始使用

已有启动器、剪贴板、插件和 BYOK 功能保持免费；尚未开放 Pro 购买。 提供 macOS、Windows、Linux 桌面开发预览。权限与快捷键行为取决于系统及 Linux 图形会话。

[安装、首次使用、隐私与备份恢复](docs/user-guide.zh-CN.md) · [English](docs/user-guide.md)

## macOS 安装（开发者预览版）

前往 [GitHub Releases](https://github.com/turinglambdaai/fulcrum/releases/latest)，按芯片选择
[Apple Silicon（M 系列）DMG](https://github.com/turinglambdaai/fulcrum/releases/latest/download/fulcrum-macos-arm64.dmg)
或 [Intel DMG](https://github.com/turinglambdaai/fulcrum/releases/latest/download/fulcrum-macos-x64.dmg)。
打开 **DMG**，把 **Fulcrum 图标拖到 Applications（应用程序）文件夹**，推出安装磁盘映像，再从**应用程序文件夹**启动 Fulcrum。不要直接从 DMG 中运行。

**安全提示：** 当前版本的自动发布流程使用开发用临时签名，**尚未提供 Apple Developer ID 公证**，所以首次启动时可能被 Gatekeeper 拦截。请先确认下载自官方 Releases，再依据 [Apple 官方说明](https://support.apple.com/102445) 决定是否手动允许打开。**不建议关闭 Gatekeeper 或用 `xattr -cr` 清除隔离信息。** 在使用需要权限的功能时再授权「辅助功能」，详见 [macOS 初次安装与启动](docs/user-guide.zh-CN.md#macos-安装与首次启动)。

## Fulcrum 是什么？

按下全局热键，一个悬浮命令面板随即出现：

- **模糊搜索一切** —— 应用、剪贴板历史、片段，多字段加权排序
- **随处粘贴** —— 剪贴板行回车直接粘贴进你来自的应用；传统复制仍在 ⌘K 里
- **内联计算** —— 精确算术、函数、常量；↵ 复制结果
- **剪贴板历史** —— 每次复制都记录在本机，可搜索、可置顶
- **片段** —— 带关键词的命名文本展开，在启动器内一行创建（`add snippet addr 南京西路 42 号`）
- **Web 搜索 bang** —— `!g`、`!gh`、`!so`、`!w`、`!yt`、`!m`、`!d`、`!t`
- **Quicklinks** —— 自带关键词的 URL 模板（`yt nature` 直达搜索），在启动器内一行创建
- **窗口管理** —— 左/右半屏、最大化、近最大化、居中、还原，三平台各自原生实现
- **文件搜索** —— `find <query>` 合并本地持久化文件名索引与平台索引：macOS 用 Spotlight，Windows 用 Windows Search，Linux 用 `plocate`/`locate`
- **BYOK AI（流式）** —— 自带 OpenAI / Anthropic / Ollama 密钥：`ai summarize`、`ai clean`、`ai translate <lang>`、`ai explain`、`ai chat <msg>`、`ai <question>`——答案在面板里流式生成，完成后自动进剪贴板；密钥只存本机、绝不参与同步
- **系统命令** —— 锁屏、睡眠、重启
- **插件** —— 任何能通过 stdio 说 JSON 的语言（[FPP1](docs/plugins.md)），附二十六个第一方插件，可在启动器内直接安装（查询 `gallery`）
- **同步（beta）** —— 设置与片段镜像到任意云盘同步目录；机器数据被清空后可从镜像恢复

本地搜索（包括已索引的文件名与路径）、历史与片段保存在设备上；插件、BYOK 请求和配置的同步具有各自的联网与数据去向。

## 为什么还要一个启动器？

因为没有任何产品能在三个桌面系统上同时提供 Raycast 级别的打磨和**原生** UI。Fulcrum 构建在 [Rivet](https://rivet.jrtx.site) 之上：一个共享的 Racket 后端嵌入每个应用，macOS 用 SwiftUI，Windows 用 WinUI 3，Linux 用 GTK4。不是 Electron，不是网页套壳。Windows 版就是 Windows 应用，macOS 版就是 macOS 应用。

| | Fulcrum | Raycast | PowerToys Run | Ulauncher |
|---|---|---|---|---|
| 平台 | macOS + Windows + Linux | macOS（Windows beta 中） | Windows | Linux |
| 原生 UI | **逐平台第一方** | macOS 原生 | WinUI | GTK |
| 后端 | 一个内嵌 Racket CS | 各平台独立 | C# | Python |
| 插件 | JSON over stdio，任意语言 | TypeScript，进程内 | C# | Python |
| 价格 | 核心免费；1.0 推出 Pro | 免费 + Pro | 免费 | 免费 |

## 仓库结构

```text
fulcrum/
├── rivet.rktd              # 发布标识、版本、部署目标
├── app/
│   ├── backend.rkt         # RVT1 线上契约（RPC、Event、State）
│   ├── update.rkt          # 签名清单更新检查（rivet/distribution）
│   └── core/               # 搜索引擎、provider、存储、FPP1 插件
├── macos-host/             # SwiftUI 悬浮面板 + Carbon 全局热键
├── windows/                # WinUI 3 悬浮窗 + RegisterHotKey
├── linux/                  # GTK4 面板 + X11 grab（Rivet 0.3 Linux preview）
├── gallery/                # 26 个第一方 FPP1 插件（应用内可安装）
├── tests/                  # 后端测试（raco test tests/）
├── docs/                   # user-guide.md、plugins.md、fpp2.md、registry.md
├── site/                   # fulcrum.jrtx.site（GitHub Pages）
└── .github/workflows/      # CI 矩阵 + tag 驱动的发布流水线
```

## 状态（开发者预览）

开发者预览。后端已完成并通过全部测试（101 个 test case，覆盖排序、存储、插件、AI、签名更新链路），内置二十六个第一方插件的 gallery（查询 `gallery` 安装）与设置/片段同步 beta（`sync-root`）。三个宿主均对齐后端契约：Windows（WinUI 3）、macOS（SwiftUI）、Linux（GTK4）——Linux 宿主通过 [Rivet 0.3](https://github.com/turinglambdaai/rivet) 引入的官方 `raco rivet build` Linux 路径构建。已知的平台边界在[用户指南](docs/user-guide.zh-CN.md#疑难排查)里如实列明：文件搜索依赖各平台索引（Windows 索引未开启的机器回退到有界慢扫描）；Linux 的 Wayland 粘贴到前台需要 `wtype`。`raco rivet doctor` / `dev` 是所有平台受支持的开发循环。

## 开发

依赖：[Racket CS](https://racket-lang.org/) 9.3（stable）、以包形式链接的 Rivet checkout（v0.3.0 或更高）、以及平台工具链（macOS 需要 Xcode CLT，Windows 需要 VS 2022 Build Tools，Linux 需要 `build-essential cmake pkg-config libgtk-4-dev zlib1g-dev liblz4-dev libncurses-dev libx11-dev libxtst-dev`——缺什么 `raco rivet doctor` 会给出精确清单）。

```bash
raco pkg install --auto --no-docs --link /path/to/rivet
raco make app/core/*.rkt app/backend.rkt
raco test tests/
raco rivet acceptance --json # 当前平台打包产品验收
```

通过 Rivet 工具链运行启动器（macOS / Windows）：

```bash
raco rivet doctor
raco rivet dev
```

想做插件？从 [gallery/epoch](gallery/epoch) 和 [docs/plugins.md](docs/plugins.md) 开始——Python 就够了。

## 许可

Fulcrum 核心以 BUSL-1.1 源码可用许可发布，到期自动转为 MIT（见 [LICENSE](LICENSE)）。插件协议（[docs/plugins.md](docs/plugins.md)）与示例插件为 MIT——插件是你的代码，即使启动器核心不是完全开放，协议也是开放的。这一拆分的商业考量记录在 [docs/business.zh-CN.md](docs/business.zh-CN.md)。
