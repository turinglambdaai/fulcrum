# Fulcrum 用户指南

一次按键，整台电脑触手可及。

[English](user-guide.md)

---

## macOS 安装与首次启动

1. 从 [官方 Releases](https://github.com/turinglambdaai/fulcrum/releases/latest) 下载 **.dmg 安装包**（.zip 主要用于应用内更新）：M 系列 Mac 选 `arm64`，Intel Mac 选 `x64`。
2. 双击打开 DMG，在 Finder 窗口中将 **Fulcrum.app 拖到 Applications（应用程序）图标**上。如果提示覆盖旧版本，请先退出正在运行的 Fulcrum。等待拷贝完成后，推出 DMG。
3. 从 **「应用程序」文件夹**启动 Fulcrum。即使搜索面板隐藏，它也会驻留菜单栏；可以使用 <kbd>⌥</kbd>+<kbd>Space</kbd> 或备用热键唤出。
4. 需要粘贴到前台应用等功能时，macOS 可能请求辅助功能权限。按需在 **系统设置 → 隐私与安全性 → 辅助功能**授权，不必为了安装而预先打开所有权限。

**关于 Gatekeeper：** 当前开发预览版本使用临时签名，尚未完成 Apple Developer ID 公证。如果系统阻止打开，请先确认来源是官方 Releases；[Apple 安全说明](https://support.apple.com/102445) 介绍了仅对确认可信的应用在「隐私与安全性」中执行「仍要打开」的操作。不要全局关闭 Gatekeeper，也不要批量移除隔离属性。正规签名与公证仍是单独的发布要求。

**仍看到只有一个应用的旧式 DMG？** 你可能安装了旧版本。新的拖拽式 DMG 只对合并并重新发布后的安装包生效，已下载的历史包不会自动改变。

---

## 一分钟上手

1. 按 <kbd>Alt</kbd>+<kbd>Space</kbd>（macOS 是 <kbd>⌥</kbd>+<kbd>Space</kbd>），面板出现。
2. 输入 `calc`，计算器出现在结果里，回车，打开了。
3. 再按热键，输入 `128*768`，答案出现在结果里，回车，已复制。
4. 再按热键。你已经会用了。

整个产品就是：**一个键 → 输入 → 回车**。下面全是细节。

---

## 你能做什么

### 启动应用

输入应用名的任意片段——`firefox`、`term`、`calc`。模糊匹配：`ffx` 能找到 Firefox，手滑打错也能容忍。常用的应用会越来越靠前。中文名称还支持离线的无声调全拼和首字母搜索：`weixin`、`wx` 都能找到“微信”，直接输入中文仍然拥有更高权重。

### 粘贴任何东西到任何地方

你复制的每段文字都会被记住。输入 `clip` 或那段文字里的任意词，按回车——文字直接粘贴进你刚才在用的应用。不用切窗口，不用按 <kbd>Ctrl</kbd>+<kbd>V</kbd>。

> macOS 首次使用会请求辅助功能权限，授权一次即可全局生效。

### 行内计算

在搜索框里敲算式：`128*768`、`(2+3)^4`、`sqrt(2)`、`sin(pi/4)`。答案出现在结果最上面，回车复制。

计算器还能内联回答日期与换算——不需要任何关键词：

- **日期。** `next friday`（下个周五）、`in 3 weeks`（三周后）、`in 2 months`（两个月后）、`2026-10-20 + 14d`、`days until 2027-01-01`（距离某天还有多少天）、`days since 2026-01-01`（某天以来多少天）。
- **单位。** `32f to c`（华氏转摄氏）、`100c to k`、`5 km in mi`、`26.2 mi to km`、`10 kg to lb`、`12 mm to cm`——覆盖一组固定单位的温度、长度、重量。
- **汇率。** `100 usd to eur`、`1 eur to jpy`、`100$ to €`——来自本机缓存的汇率表，后台静默刷新（至多每小时一次）。离线时用最近一次缓存；首次刷新成功之前暂时没有汇率行。`¥` 按 CNY 人民币换算；日元请直接输入 `jpy`。

`u`（单位）和 `cur`（汇率）插件继续保留，负责长尾需求——它们的行会和这些内联行一起出现。

### 片段自动展开

把一段文字存在一个关键词下面，然后在任何应用里输入那个关键词加空格，Fulcrum 原地替换成完整文本——自动的，不用按任何快捷键：

```
add snippet addr 南京西路 42 号
```

在邮件里输入 `addr` + 空格，就变成了 `南京西路 42 号`。在 `settings` → `expansion-enabled` 里可以开关（macOS 和 Windows 支持；Linux 合成器不允许所需的输入监听）。

片段通过 [Sync beta](#sync-beta) 跨机器同步。

### 网页搜索

| 输入 | 打开 |
|---|---|
| `!g rockets` | Google |
| `!d rockets` | DuckDuckGo |
| `!gh rivet` | GitHub |
| `!so segfault` | Stack Overflow |
| `!w saturn` | 维基百科 |
| `!yt lofi` | YouTube |
| `!m 埃菲尔铁塔` | Google 地图 |
| `!t fulcrum` | X/Twitter |

没被别处匹配的普通文字，最后会出现一条通用搜索（默认 `!g`，可配）。

### 快捷链接

```
add link yt https://youtube.com/search?q={query}
```

之后 `yt lofi` 就打开 YouTube 搜索。`{query}` 被替换成关键词后面的内容。输入 `quicklinks` 可以查看和删除。

### 窗口管理

输入 `window` 或命令名的一部分。**左半屏**、**右半屏**、**最大化**、**近最大化**、**居中**、**还原**——作用于你召唤 Fulcrum 之前最前面的那个窗口。

### 找文件

`find 发票` 先通过平台索引搜文件名：macOS 用 Spotlight，Windows 用 Windows Search（索引未开启时回退到有界慢扫描），Linux 用 `plocate`/`locate`。命中结果同时写入 Fulcrum 的本地持久化文件名索引。第一次文件查询还会在后台建立 Desktop、Documents、Downloads 清单；存在时同时覆盖 Windows OneDrive、macOS iCloud Drive 与 Linux 本地化 XDG 用户目录，并跳过 `.git`、`node_modules`、`.cache` 等依赖/缓存树。建库期间仍由平台索引立即回答；完成后即使平台搜索超时或暂不可用，常用目录内文件的精确与前缀查询仍可返回。Linux 安装 `plocate` 后宽泛搜索更快；平台没有结果且本地也没有已知匹配时，Fulcrum 会如实说明。

输入 `file index` 可查看本地清单处于 idle、scanning、ready、因目录不可读而 partially ready，还是 failed。部分扫描会保留旧记录，不会把拒绝访问误判为文件已删除。

本地清单中的中文文件名除原文外，也可用无声调全拼和拼音首字母搜索。

### 系统命令

`lock`、`sleep`、`restart`、`toggle dark mode`、`empty trash`——Fulcrum 只提供你的平台上真实存在的命令。

### 表情搜索

输入表情英文名的两个以上字母——`grin`、`fire`、`heart`——匹配的表情内联出现。回车直接粘贴进你正在用的应用，<kbd>Ctrl</kbd>+<kbd>K</kbd> 改为复制。

---

## AI（自带密钥）

Fulcrum 的 AI 用你自己的 OpenAI、Anthropic 或本地 Ollama 密钥。Fulcrum 不收费、不经手数据——密钥存在本地文件里，永不同步。只有你执行 AI 命令时，提示词才会发给你选的服务商。

### 一次性设置

1. 输入 `settings`，运行 `ai-provider` 那行，切到你的服务商。
2. 输入 `ai key sk-…`（你的真实密钥）回车。Ollama 不需要密钥——只要 `ollama serve` 在跑。

### 用法

| 输入 | 效果 |
|---|---|
| `ai summarize` | 总结剪贴板内容 |
| `ai clean` | 修正剪贴板文本的语法拼写 |
| `ai translate zh` | 翻译剪贴板到中文（或任意语言） |
| `ai explain` | 解释剪贴板内容 |
| `ai chat 解释一下 X` | 会记住前几轮对话 |
| `什么是熵？` | 任何以 ？ 结尾的问句自动出现 AI 行 |

答案**流式打进面板**——模型还在生成你就能开始读——完成后自动进剪贴板。

### 记忆与控制

对话历史**跨重启持久化**（本地存储，永不同步）。AI 在同一服务商下跨会话记住上下文。

- `ai undo`——回退最后一条对话，换个方向重试
- `ai reset`——清空对话重来
- `ai persona 你是简洁的技术写作者`——持久化人设，每次请求都生效
- `ai model gpt-4o`——不离开启动器切换模型

---

## 插件

插件用任何能输出 JSON 的语言编写。内置画廊自带二十六个真实插件：单位换算（`u`）、时间戳（`ts`）、正则（`re`）、时区（`tz`）、GitHub 搜索（`gh`）、crates.io（`crate`）、Homebrew（`brew`）、Docker（`dk`）、winget（`winget`）、Bitwarden（`bw`）、汇率（`cur`）、进制转换（`base`）、Base64（`b64`）、大小写转换（`case`）、颜色（`color`）、词典（`define`）、哈希（`hash`）、Hacker News（`hn`）、IP 地址（`ip`）、Lorem Ipsum（`lorem`）、npm 搜索（`npm`）、密码生成（`pw`）、UUID（`uuid`）、天气（`wx`）、维基百科（`wiki`）、字数统计（`wc`）。

- 输入 `gallery` 查看全部；回车安装或卸载。
- 输入 `plugins` 逐个开关。
- 输入 `plugins <名字>` 看详情页。
- `install plugin /路径` 从任意文件夹安装。
- `plugin set <id> <pref> <value>` 配置插件偏好。

写一个插件：一个 manifest + 一个脚本，见 [docs/plugins.md](plugins.md)——Python 就够。

---

## 设置

**开机启动（登录后启动）：** 三平台均可在 **General（常规）→ Start at login** 自行开启或关闭，默认关闭，仅对当前设备生效，不随同步复制。登录系统后会在后台常驻，不自动弹出搜索界面。macOS 可能需要在系统设置的登录项中批准；Windows 使用当前用户的启动项；Ubuntu/Linux 使用 XDG 自动启动。AppImage 用户开启后请勿随意移动安装文件。

Linux 设置界面改为与 macOS、Windows 一致的五类侧边导航：General、Features、AI、Commands、Sync & Updates。Commands 可通过共同的后端编辑命令别名，但 Linux 的**单个命令全局快捷键**目前尚不支持执行，界面明确禁用以避免保存无效绑定。常规 General 中的全局唤出快捷键支持直接按键录制。Ubuntu 启动器会在首批搜索结果准备好后显示，避免只看到空白搜索框。

**Ubuntu / Linux 启动器外观：** 搜索图标与「搜索应用、剪贴板、片段、网页…」提示在同一水平线上。面板已显示时，不再常驻展示「就绪 — 使用热键或 `fulcrum --toggle` 唤出」；需要从隐藏状态重新唤出时，仍可使用全局快捷键或 `fulcrum --toggle`。启动失败、快捷键冲突和更新失败等真正需要注意的状态信息仍会显示。

**Windows 更新操作：** 从系统托盘选择「Check for Updates（检查更新）」会直接打开可见的 `update` 页面。检查后会自动刷新下载操作；点击 Download（下载）获取并校验签名 MSI，等下载结束后点击 Quit and install（退出并安装），程序退出后由系统安装器升级并重新启动。如果 Windows 要求管理员确认，按系统提示操作；失败时可以查看错误或从更新页面打开下载目录。**便携 ZIP 版本不会被 MSI 原地替换**，建议从正式 MSI 安装版使用此自动升级路径。

**Windows 和 macOS** 的设置窗口使用左侧分类导航：**General（常规）**、**Features（功能）**、**AI**、**Commands（命令）**、**Sync & Updates（同步与更新）**。可从托盘或菜单栏的「设置」打开。Windows 和 macOS 均可在常规设置中选中快捷键区域后直接按组合键录制，Esc 取消，不需要输入 `alt+space` 等内部格式。在 Commands 中可编辑命令别名和快捷键。Windows 设置窗口保留 WinUI 原生标题栏并显示 Fulcrum 图标；macOS 保留原生 AppKit/SwiftUI 标题栏。Linux 当前仍使用可滚动的 GTK 设置表单，尚无独立 Commands 设置页。

输入 `settings`，运行对应的行即可修改：

| 设置 | 说明 |
|---|---|
| language | 界面语言（zh / en） |
| theme | system / light / dark，即时生效 |
| hotkey | 循环：`alt+space` → `ctrl+alt+space` → `ctrl+shift+space` → `alt+shift+space` |
| max-results | 列表行数（5–25） |
| clipboard-enabled | 剪贴板历史开关 |
| expansion-enabled | 片段自动展开开关 |
| web-search-enabled | 网页搜索行开关 |
| plugins-enabled | 插件加载开关 |
| ai-provider | AI 服务商 |

自定义值（热键、模型、同步目录）直接输入，或编辑数据目录下的 `settings.json`。热键接受 `mod+key` 格式——修饰键 `alt/ctrl/shift/cmd/win/super`（至少一个），键位 `space`、`a`–`z`、`0`–`9`、`f1`–`f12`、`comma`、`period`、`minus`、`equal`、`tab`。三平台通用。

---

## 更新

输入 `update` → **Check for updates now**。后台下载；macOS 原地换装重启。更新包 Ed25519 签名——校验失败拒收，绝不安装。

---

## 同步 beta

把 `sync-root` 设到 iCloud Drive、Dropbox、Syncthing 或任何同步目录里。设置和片段镜像过去；新机器首次启动自动恢复。剪贴板历史和 AI 密钥**刻意**不同步。

---

## 隐私

本地文件包含剪贴板、片段、AI 历史、ai-keys.json，以及文件搜索曾返回的文件名与路径可重建索引。AI 请求会向配置的服务商发送选定上下文并用密钥鉴权；插件与汇率刷新也会联网。文件夹同步会经你选择的同步服务传输选定记录；文件索引永不参与同步。数据与恢复说明见下文。

---

## 键位速查

| 按键 | 场景 | 动作 |
|---|---|---|
| `Alt+Space` | 任意时刻 | 显示 / 隐藏面板 |
| 输入 | 面板内 | 搜索一切 |
| `↑` `↓` | 面板内 | 移动选中 |
| `回车` | 选中结果 | 执行（剪贴板 = 粘贴；表情 = 插入；文件 = 打开） |
| `Ctrl+K` / `⌘K` | 选中结果 | 附加动作 |
| `Tab` | 选中结果 | 标题补全到搜索框 |
| `Esc` | 面板内 | 逐层退掉：动作 → 详情 → AI → 查询词 → 隐藏 |

---

## 从 Raycast 过来？

同样的地方：热键 → 输入 → 回车的循环。应用启动、剪贴板、片段、快捷链接、计算器、窗口管理、文件搜索、网页搜索、系统命令、扩展、深色模式——全都有。

**我们不一样的地方，以及为什么：**

新增多步骤工作流 Pro 尚未开售；已有 BYOK、插件和自有文件夹同步保持免费。
- **三平台平等。** macOS、Windows、Linux 功能相同、键位相同、原生 UI。不是一头优先两头将就。
- **BYOK AI 不订阅。** 用你自己的密钥。没有月费，没有按次计费，数据不过 Fulcrum 的服务器。
- **本地优先。** 你的数据不离开设备，除非你主动让它走（AI 提示、网页搜索）。同步不需要云账号——用你已有的文件夹同步服务。
- **插件用任何语言。** Raycast 只收 TypeScript。Fulcrum 接受任何读 stdin 写 JSON 的程序——Python、Go、Rust、shell 脚本。
- **专注，不臃肿。** Fulcrum 把启动器的事做好，不试图变成窗口管理器、笔记应用或 AI 聊天机器人。

**还没做到的（诚实清单）：** 插件生态年轻（26 个内置 vs Raycast 商店的 2500+）；剪贴板只收文本；片段自动展开不支持 Linux。

---

## 排障

- **热键没反应。** 组合键被占了。Fulcrum 自动退到 `Ctrl+Alt+Space` 并提示。也可以从托盘图标（Windows）、菜单栏（macOS）、`fulcrum --toggle`（Linux）。GNOME 上特别注意：系统自带的「激活窗口菜单」键位就是 Alt+Space，合成器会先把它吃掉——Fulcrum 启动时会检测这种遮蔽并在托盘菜单里给出「修复 Alt+Space 冲突」一键解除；手动修法：`gsettings set org.gnome.desktop.wm.keybindings activate-window-menu "[]"`。

- **macOS 上粘贴回前台没反应。** 授权辅助功能：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 Fulcrum。

- **Linux 上粘贴回前台。** X11 开箱即用。Wayland 装 `wtype`。

- **AI 说没有密钥。** 先选服务商再运行 `ai key <密钥>`。Ollama 不需要密钥。

- **想要的热键被占。** `settings` → `hotkey` 循环切换。

- **数据在哪？** 全部在一个数据目录里（`FULCRUM_DATA_DIR`）：JSON 数据、`ai-keys.json`，以及可重建的文件名/路径缓存 `file-index.sqlite3`。删掉就是全新状态。

---

## 为什么选 Fulcrum？

启动器是你每天用几百次的工具。它应该快、私密、属于你。

Fulcrum 建在 [Rivet](https://rivet.jrtx.site) 之上：一个 Racket 大脑嵌入每个平台的原生 UI——macOS 用 SwiftUI，Windows 用 WinUI 3，Linux 用 GTK4。不是 Electron，不是网页套壳。Windows 版就是 Windows 应用，macOS 版就是 macOS 应用。

我们是后来者。这意味着我们研究了 Raycast 用户的抱怨——AI 功能挤占基础稳定性、功能膨胀、Pro 会员门槛——然后做了不同的选择。Fulcrum 把优先级放在：快速搜索、可靠操作、诚实的错误、你的数据留在你的机器上。

源码可用（BUSL-1.1，到期转 MIT）。插件协议 MIT。无遥测。无账号。无云。

## 当前可用状态

已有启动器、剪贴板、插件和 BYOK 功能保持免费；尚未开放 Pro 购买。

## 平台与安装

提供 macOS、Windows、Linux 桌面开发预览。权限与快捷键行为取决于系统及 Linux 图形会话。

从[官方 Releases](https://github.com/turinglambdaai/fulcrum/releases)选择明确标注系统和架构的附件，阅读该版本说明并核对附带校验文件。未列出的附件或平台不视为已交付。预览构建可能没有系统发行者签名或公证；不要为安装而关闭系统安全保护。

## 第一次使用

1. 打开 Fulcrum，用设置中的全局快捷键呼出窗口；快捷键冲突在设置中解决。
2. 输入 12*12 确认得到 144，再搜索并启动一个已安装应用。
3. 分别按需启用剪贴板历史、插件和 AI，先了解各自需要的数据与权限。

## 数据、备份与恢复

退出 Fulcrum 后备份配置使用的应用数据目录。剪贴板历史、片段、插件设置、AI 历史和本地文件名/路径索引可能含敏感信息。`file-index.sqlite3` 是可重建缓存，不需要恢复或同步。先用副本验证恢复，不要把完整诊断目录直接公开上传。

## 联网、密钥与隐私

本地搜索不需要商业账号。安装的插件可以运行代码和联网；BYOK 会把选定的提示及上下文发送至你配置的服务商，费用由服务商另行收取。

## 已知限制

当前为开发预览。新增多步骤工作流自动化仍在规划，尚不是可购买能力。AI 生命周期拆分见 #89。

## 更新与卸载

先备份数据，再阅读目标版本说明。应用内检查更新不一定能安装当前渠道的更新；按手册区分便携包、系统安装器和源码安装。不要绕过失败的验签或用来源不明的文件覆盖程序。更新失败时保留现有数据与错误信息，使用可信发行包恢复；卸载程序通常不等于删除独立的数据目录，删除个人数据前先确认备份。

## 获得帮助

在 [GitHub Issues](https://github.com/turinglambdaai/fulcrum/issues) 反馈，中文或英文均可。提供版本、系统与架构、安装渠道、复现步骤、预期和实际结果。先用合成样本复现；不要附上密钥、授权文件、数据库、原始私密文档或完整日志。公开支持不承诺响应时限。

[敏感漏洞请按 SECURITY.md 的私下流程报告](../SECURITY.md)。
