# Fulcrum 用户指南

一次按键，整台电脑触手可及。

[English](user-guide.md)

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

输入应用名的任意片段——`firefox`、`term`、`calc`。模糊匹配：`ffx` 能找到 Firefox，手滑打错也能容忍。常用的应用会越来越靠前。

### 粘贴任何东西到任何地方

你复制的每段文字都会被记住。输入 `clip` 或那段文字里的任意词，按回车——文字直接粘贴进你刚才在用的应用。不用切窗口，不用按 <kbd>Ctrl</kbd>+<kbd>V</kbd>。

> macOS 首次使用会请求辅助功能权限，授权一次即可全局生效。

### 行内计算

在搜索框里敲算式：`128*768`、`(2+3)^4`、`sqrt(2)`、`sin(pi/4)`。答案出现在结果最上面，回车复制。

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

`find 发票` 通过 Spotlight 搜文件名（macOS）。其他平台会诚实提示需要系统搜索索引。

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

插件用任何能输出 JSON 的语言编写。内置画廊自带十一个真实插件：单位换算（`u`）、时间戳（`ts`）、正则（`re`）、时区（`tz`）、GitHub 搜索（`gh`）、crates.io（`crate`）、Homebrew（`brew`）、Docker（`dk`）、winget（`winget`）、Bitwarden（`bw`）、汇率（`cur`）。

- 输入 `gallery` 查看全部；回车安装或卸载。
- 输入 `plugins` 逐个开关。
- 输入 `plugins <名字>` 看详情页。
- `install plugin /路径` 从任意文件夹安装。
- `plugin set <id> <pref> <value>` 配置插件偏好。

写一个插件：一个 manifest + 一个脚本，见 [docs/plugins.md](plugins.md)——Python 就够。

---

## 设置

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

| 数据 | 存在哪 | 离开你的设备？ |
|---|---|---|
| 搜索历史 | 不存储 | 从不 |
| 剪贴板历史 | 本地 JSON | 从不 |
| 片段 | 本地 JSON（+ 你配置的同步镜像） | 仅到你自己选的云盘 |
| AI 提示 | 不存储（仅传输中） | 仅到你选的 AI 服务商 |
| AI 对话 | 本地 JSON | 从不 |
| API 密钥 | 本地文件 | 从不 |
| 遥测 | 不存在 | 无数据可发 |

Fulcrum 只发三种网络请求：更新检查（签名、节流）、你主动执行的网页搜索、你主动执行的 AI 提示。

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

- **免费，没有账号。** Fulcrum 没有 Pro 会员，没有登录，没有账号体系。这个页面上写的一切都是免费的，永远。
- **三平台平等。** macOS、Windows、Linux 功能相同、键位相同、原生 UI。不是一头优先两头将就。
- **BYOK AI 不订阅。** 用你自己的密钥。没有月费，没有按次计费，数据不过 Fulcrum 的服务器。
- **本地优先。** 你的数据不离开设备，除非你主动让它走（AI 提示、网页搜索）。同步不需要云账号——用你已有的文件夹同步服务。
- **插件用任何语言。** Raycast 只收 TypeScript。Fulcrum 接受任何读 stdin 写 JSON 的程序——Python、Go、Rust、shell 脚本。
- **专注，不臃肿。** Fulcrum 把启动器的事做好，不试图变成窗口管理器、笔记应用或 AI 聊天机器人。

**还没做到的（诚实清单）：** 插件生态年轻（11 个内置 vs Raycast 的几千个）；剪贴板只收文本；文件搜索仅限 macOS；片段自动展开不支持 Linux。

---

## 排障

- **热键没反应。** 组合键被占了。Fulcrum 自动退到 `Ctrl+Alt+Space` 并提示。也可以从托盘图标（Windows）、菜单栏（macOS）、`fulcrum --toggle`（Linux）。GNOME 上特别注意：系统自带的「激活窗口菜单」键位就是 Alt+Space，合成器会先把它吃掉——Fulcrum 启动时会检测这种遮蔽并在托盘菜单里给出「修复 Alt+Space 冲突」一键解除；手动修法：`gsettings set org.gnome.desktop.wm.keybindings activate-window-menu "[]"`。

- **macOS 上粘贴回前台没反应。** 授权辅助功能：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 Fulcrum。

- **Linux 上粘贴回前台。** X11 开箱即用。Wayland 装 `wtype`。

- **AI 说没有密钥。** 先选服务商再运行 `ai key <密钥>`。Ollama 不需要密钥。

- **想要的热键被占。** `settings` → `hotkey` 循环切换。

- **数据在哪？** 全部在一个数据目录里（`FULCRUM_DATA_DIR`）。删掉就是全新状态。

---

## 为什么选 Fulcrum？

启动器是你每天用几百次的工具。它应该快、私密、属于你。

Fulcrum 建在 [Rivet](https://rivet.jrtx.site) 之上：一个 Racket 大脑嵌入每个平台的原生 UI——macOS 用 SwiftUI，Windows 用 WinUI 3，Linux 用 GTK4。不是 Electron，不是网页套壳。Windows 版就是 Windows 应用，macOS 版就是 macOS 应用。

我们是后来者。这意味着我们研究了 Raycast 用户的抱怨——AI 功能挤占基础稳定性、功能膨胀、Pro 会员门槛——然后做了不同的选择。Fulcrum 把优先级放在：快速搜索、可靠操作、诚实的错误、你的数据留在你的机器上。

源码可用（BUSL-1.1，到期转 MIT）。插件协议 MIT。无遥测。无账号。无云。
