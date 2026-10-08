# Fulcrum（支点）

一次按键，直达一切。macOS、Windows、Linux 三平台的键盘优先启动器——一个 Racket 大脑，三套第一方原生 UI，全程无 WebView。

[![CI](https://github.com/turinglambdaai/fulcrum/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/fulcrum/actions/workflows/ci.yml) ![Windows](https://img.shields.io/badge/Windows-WinUI_3-0078D4?logo=windows11&logoColor=white) ![macOS](https://img.shields.io/badge/macOS-SwiftUI-000000?logo=apple&logoColor=white) ![Linux](https://img.shields.io/badge/Linux-GTK4-F9A03C?logo=linux&logoColor=white) [![License](https://img.shields.io/badge/license-BUSL--1.1-blue)](LICENSE) ![Version](https://img.shields.io/badge/version-0.3.0-C15F3C)
[English](README.md) · **中文**


## Fulcrum 是什么？

按下全局热键，一个悬浮命令面板随即出现：

- **模糊搜索一切** —— 应用、剪贴板历史、片段，多字段加权排序
- **内联计算** —— 精确算术、函数、常量；↵ 复制结果
- **剪贴板历史** —— 每次复制都记录在本机，可搜索、可置顶
- **片段** —— 带关键词的命名文本展开
- **Web 搜索 bang** —— `!g`、`!gh`、`!so`、`!w`、`!yt`、`!m`、`!d`、`!t`
- **Quicklinks** —— 自带关键词的 URL 模板（`yt nature` 直达搜索），在启动器内一行创建
- **窗口管理** —— 左/右半屏、最大化、近最大化、居中、还原，三平台各自原生实现
- **文件搜索** —— `find <query>` 走 Spotlight（当前为 macOS，其他平台诚实提示）
- **BYOK AI** —— 自带 OpenAI / Anthropic / Ollama 密钥：`ai summarize`、`ai clean`、`ai translate <lang>`、`ai explain`、`ai <question>`——答案直接进剪贴板；密钥只存本机、绝不参与同步
- **系统命令** —— 锁屏、睡眠、重启
- **插件** —— 任何能通过 stdio 说 JSON 的语言（[FPP1](docs/plugins.md)），附十个第一方插件，可在启动器内直接安装（查询 `gallery`）
- **同步（beta）** —— 设置与片段镜像到任意云盘同步目录；机器数据被清空后可从镜像恢复

搜索、历史、片段永远不离开你的设备。0.1 没有任何遥测。

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
├── gallery/                # 10 个第一方 FPP1 插件（应用内可安装）
├── tests/                  # 43 个后端测试（raco test tests/）
├── docs/                   # plugins.md、release-runbook.md、商业计划
├── site/                   # fulcrum.jrtx.site（GitHub Pages）
└── .github/workflows/      # CI 矩阵 + tag 驱动的发布流水线
```

## 状态：v0.3.0（开发者预览）

开发者预览。后端已完成并通过全部测试（55/55），内置十个第一方插件的 gallery（查询 `gallery` 安装）与设置/片段同步 beta（`sync-root`）。三个宿主均针对后端契约功能完备：Windows（WinUI 3）、macOS（SwiftUI）、Linux（GTK4）——Linux 宿主现已通过 [Rivet 0.3](https://github.com/turinglambdaai/rivet) 引入的官方 `raco rivet build` Linux 路径构建。`raco rivet doctor` / `dev` 是所有平台受支持的开发循环。

## 开发

依赖：[Racket CS](https://racket-lang.org/) 9.3（stable）、以包形式链接的 Rivet checkout（v0.3.0 或更高）、以及平台工具链（macOS 需要 Xcode CLT，Windows 需要 VS 2022 Build Tools，Linux 需要 `build-essential cmake pkg-config libgtk-4-dev zlib1g-dev liblz4-dev libncurses-dev`——缺什么 `raco rivet doctor` 会给出精确清单）。

```bash
raco pkg install --auto --no-docs --link /path/to/rivet
raco make app/core/*.rkt app/backend.rkt
raco test tests/
```

通过 Rivet 工具链运行启动器（macOS / Windows）：

```bash
raco rivet doctor
raco rivet dev
```

想做插件？从 [gallery/epoch](gallery/epoch) 和 [docs/plugins.md](docs/plugins.md) 开始——Python 就够了。

## 许可

Fulcrum 核心以 BUSL-1.1 源码可用许可发布，到期自动转为 MIT（见 [LICENSE](LICENSE)）。插件协议（[docs/plugins.md](docs/plugins.md)）与示例插件为 MIT——插件是你的代码，即使启动器核心不是完全开放，协议也是开放的。这一拆分的商业考量记录在 [docs/business.zh-CN.md](docs/business.zh-CN.md)。
