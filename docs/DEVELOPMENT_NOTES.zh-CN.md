# Tic 二次开发：与上游的差异、已知限制与手动验证记录

本文件是二次开发分支（dev 版，bundle id `com.kasvith.tic.dev`）的交付说明，配合
`DEVELOPMENT_PLAN.zh-CN.md` 的验收项使用。开发计划里明确要求：**复选框必须附实际验证结果，不能以
“代码已编写”代替验收通过**。本文件给出这些验证结果。

## 1. 与上游（`kasvith/tic` release 版）的差异

| 维度 | release 版 | 本开发分支（dev 版） |
| --- | --- | --- |
| Bundle ID | `com.kasvith.tic` | `com.kasvith.tic.dev` |
| 数据目录 | `~/Library/Application Support/Tic/` | `~/Library/Application Support/TicDev/` |
| MCP socket | `…/Tic/mcp.sock` | `…/TicDev/mcp.sock` |
| 偏好域 | `com.kasvith.tic` 的 `UserDefaults` | `com.kasvith.tic.dev` 的 `UserDefaults` |
| 更新源 | `kasvith/tic` 的 GitHub Releases | `xing-yiren/tic-dev` |
| 迁移策略 | 追加迁移 v6–v8，不改写 v1–v5 | 同左 |
| 数据保护 | — | 启动即做一致性快照；绝不在真实数据路径自动擦库 |

判定逻辑见 `Sources/Tic/Services/AppEnvironment.swift`：`Bundle.main.bundleIdentifier` 等于 release
的 bundle id 才走 release 路径，否则一律按 dev 处理。因此**一个误打包的 dev 版也不会写到真实数据目录**。

## 2. 数据库与备份

- 迁移为**追加式**：v6 分类、v7 资源、v8 截止时间/提醒。旧数据（v1–v5）保持不变，新增列有默认值。
- 启动时、迁移**之前**，用 GRDB 在线备份 API 生成一致性快照到 `…/Backups/tic-<时间戳>.sqlite`
  （打开着 WAL 时也能安全复制；保留最近 5 份）。这也覆盖 `.sqlite-wal` / `.sqlite-shm` 的一并快照。
- 统一入口 `AppDatabase.snapshot(_:into:retaining:)`，测试可注入目标目录，不触碰真实 Application Support。

**恢复步骤（手动）**：退出 Tic → 把 `…/Backups/tic-<时间戳>.sqlite` 复制回 `…/tic.sqlite`
（同时删除同目录下的 `tic.sqlite-wal` / `tic.sqlite-shm`）→ 重新启动。下次启动会按需重新迁移。

## 3. 已知限制

- **退出/关机后的提醒不保证送达**：提醒使用 `UNCalendarNotificationTrigger`，由系统在计划时间投递；
  应用退出后系统仍会照常投递，但**关机、睡眠且未唤醒、或用户关闭通知权限**时不保证送达。
  重新启动后，协调器会按 `revision` 对**已过期且未确认**的提醒**补发一次**（不重复轰炸）。
- **权限**：首次真正设置提醒时才请求通知权限（`.alert, .sound`）。被拒绝时状态为 `.denied`，
  设置界面会反馈，但不会阻止设置——放行后可恢复。
- **无 bundle id 时**（裸 `swift run`）：通知中心不可用，状态为 `.unavailable`，调度被跳过而非崩溃。
- **全局快捷键**：Carbon `RegisterEventHotKey` 实现，**不需要辅助功能权限**。默认候选 `⌘⇧N`；
  被系统或其他应用占用时注册失败，设置界面提示冲突且**保留原有绑定**（不会重复注册）。应用内 `⌘N` 保留。
- **macOS 14 未实测**：仅在当前开发机 macOS（见 §5）真正运行验证；macOS 14 的部署目标为编译目标，
  运行行为标记为“未验证”。
- **Stage Manager / 全屏应用 / 双屏插拔**：仅做了代码层与单元测试层面的处理（落位、可见性判定），
  未在所有组合上做真机矩阵验证。
- **资源访问**：只存引用（`file:` / `http` / `https`），**从不执行** shell 或仓库脚本。
  本地路径使用普通 bookmark（**非** security-scoped，因为本应用未沙盒化）；外置盘卸载后打开会提示
  失效并可“重新定位”。
- **仓库资源**：`.git` 目录识别为仓库类型，仅为分类展示；**不做** Git 操作。

## 4. 测试与构建

- 测试分层见 `DEVELOPMENT_PLAN.zh-CN.md` §8。新增测试：
  - 纯逻辑：`CategoryFilterTests`（匹配/隐藏/reveal/持久化）。
  - 数据库：`AppDatabaseMigrationTests`（v5 fixture 增量升级）、`CategoryDatabaseTests`（删除 SET NULL、
    窄字段更新）、`ResourceDatabaseTests`（URL 校验、级联、重定位）、`DatabaseBackupTests`（快照/恢复/保留）。
  - 通知模拟：`ReminderCoordinatorTests`（fake client + 固定 clock：调度/替换/取消/确认/稍后/过期补发一次）。
  - MCP：`MCPToolsTests` 新增分类/资源/提醒与 UI 行为一致性。
- 每次里程碑与交付前运行 `swift build` 与 `swift test`；窗口/通知相关变更另行验证打包 app。

## 5. 本轮验证记录（实际结果）

- **环境**：macOS 26.6.2（host），Xcode 27，Swift 6.4，SwiftPM（无 `.xcodeproj`），部署目标 macOS 14。
- **`swift build`**：成功（`Build complete!`）。
- **`swift test`**：**176 个测试 / 26 个套件全部通过**。
- **打包**：`scripts/package.sh` 成功产出并 ad-hoc 签名 `dist/Tic.app`（`com.kasvith.tic`），
  `codesign --verify --strict` 通过。
- **真机升级演练（v5 → 当前）**：
  1. 用 `sqlite3` 造一个只到 v5 的真实文件库，放入 release 数据目录。
  2. 运行打包 app：日志 `Database ready … (release)`，`restored 1 note panel(s)`。
  3. 校验：live 库迁移到 v8，**旧便签保留**（`Legacy note`）。
  4. 校验：`Backups/` 里的**迁移前快照停在 v5**（证明快照发生在迁移之前）。
  5. 恢复演练：把该快照复制回主库 → 重启 → 重新迁移到 v8，便签仍在。
- **数据隔离**：dev 包使用 `TicDev/` 与 `com.kasvith.tic.dev`，release 包使用 `Tic/` 与 `com.kasvith.tic`；
  演练后已清理本机产生的数据目录。

> 未覆盖项：真实通知授权弹窗/退出后投递、睡眠唤醒、真实 Spaces/Stage Manager/双屏插拔、
> bookmark 跨外置盘移动——这些需要人工在带界面的会话中逐项确认，标记为“未自动验证”。
