# AGENTS.md

Fulcrum 是三平台键盘启动器：一份 Racket 领域后端经 Rivet RVT1 驱动
macOS SwiftUI、Windows WinUI 3 和 Linux GTK4 原生宿主。

## 结构

- `app/` — 后端入口、搜索引擎、存储、插件和更新逻辑
- `tests/` — Racket 单元、集成与 RVT1 wire tests
- `macos-host/`、`windows/`、`linux/` — 三个平台的第一方原生宿主
- `shared/i18n/` — 跨宿主文案单源；`gallery/` — 第一方插件清单
- `scripts/` — 生成、发布和产品验收脚本

## 完成前必须运行

```bash
raco test tests/
raco test tests/backend-wire-test.rkt
raco rivet schema check rivet-schema.json --json
raco rivet acceptance --json
```

`raco rivet acceptance --json` 是当前平台的产品完成门禁：它必须依次通过
后端契约、真实 RVT1、原生宿主构建、可分发包生成，以及对打包后应用的
原生可访问性操作。GUI 工作不能只以代码审查、单元测试、构建成功或截图
宣称完成。

## 跨平台约束

- 支持矩阵是 macOS、Windows、Linux；改动公共交互时必须同步三宿主，或在
  文档和验收清单中明确记录真实的平台边界。
- 宿主只负责系统集成和原生渲染，搜索、排序、存储、插件、AI 与更新状态
  属于 Racket 后端；不得在某个平台复制一套业务逻辑来绕过 RVT1。
- UI 自动化依赖稳定的 accessibility / automation 标识。改文案或布局时不应
  删除这些标识；新增关键交互时同步扩展 `scripts/e2e/`。
- 测试必须验证可观察结果。默认验收场景通过原生查询框提交 `12*12`，并确认
  后端计算结果 `144` 出现在原生结果列表；wire test 另行证明持久化与事件。
- Rivet 使用不可变提交 pin。升级时同时更新 CI、release、acceptance workflow、
  setup action ref 和生成客户端，并在三个 runner 上跑完产品验收。
- 不提交 `.rivet/`、`dist/`、MSVC/WinUI 生成目录或本机用户数据。

## 发版

- `ci.yml` 负责常规多平台测试与宿主构建；`acceptance.yml` 负责可执行产品验收。
- tag 发版前，CI 与 Product Acceptance 都必须全绿；不得把 `continue-on-error`、
  空测试、跳过 UI 或测试中的强杀进程当作成功证据。
- 发现某平台无法完成同一产品场景时，先修产品或上游 Rivet；临时 workaround
  必须可删除、被测试覆盖，并在 PR 中明确说明边界。
