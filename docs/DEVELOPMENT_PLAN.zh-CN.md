# Tic 二次开发计划

日期：2026-10-14  
状态：仅完成方案与计划编写，以下实现项尚未完成。  
依据：[开发方案](DEVELOPMENT_SPEC.zh-CN.md)。源码基线 `fab0042`。

## 1. 里程碑与实施顺序

依赖：M0 → M1 → M2 → M3 → M4 → M5。每阶段完成验收后提交可独立审查的变更，避免一次性大改窗口、数据库与通知。

| 阶段 | 结果 | 粗略工作量 |
| --- | --- | --- |
| M0 基线与技术验证 | 可安全开发与迁移，验证关键系统行为 | 1–2 人日 |
| M1 窗口与快捷创建 | 默认置顶、跨桌面、全局快捷新建 | 1–2 人日 |
| M2 分类与选择性展示 | 可按项目分类控制实际便签窗口 | 2–4 人日 |
| M3 关联资源 | 文件、目录、仓库、网页可打开和重新定位 | 2–3 人日 |
| M4 DDL 与提醒 | 可配置、可取消、支持稍后提醒 | 3–5 人日 |
| M5 整体验收 | 可日常使用的独立 macOS 应用包 | 1–3 人日 |

合计约 10–19 人日，是单人熟悉 Swift/AppKit 情况下的规划估计，不是交付承诺；不含签名公证等待、云同步和完整 Git 集成。优先交付 M2，先验证“分类便签始终可见”的核心体验。

## 2. M0：建立可靠基线

- [x] 检查本机 Swift/Xcode 与 macOS，记录 `swift build`、`swift test`、打包运行结果。
  验证：macOS 26.6.2 + Xcode 27 + Swift 6.4；`swift build` 成功；`swift test` 176 测试 / 26 套件全通过；`scripts/package.sh` 产出并 ad-hoc 签名 `dist/Tic.app`，`codesign --verify --strict` 通过。
- [x] 创建独立开发数据目录、bundle ID、MCP socket 与偏好域；明确本地二次开发包不从上游下载替换安装。
  验证：`AppEnvironment` 按 bundle id 判定，dev 用 `com.kasvith.tic.dev` + `~/…/TicDev/`，release 用 `com.kasvith.tic` + `~/…/Tic/`；真机运行日志确认 release 路径生效。详见 `DEVELOPMENT_NOTES.zh-CN.md`。
- [x] 禁止真实数据路径自动擦库，追加迁移并验证旧版数据库升级；提供一致性备份与手动恢复说明。
  验证：移除 `eraseDatabaseOnSchemaChange`；迁移 v6–v8 追加；真机演练 v5→v8（见 M5 第 1 项）；恢复步骤见 `DEVELOPMENT_NOTES.zh-CN.md` §2。
- [~] 打包验证 `.floating + .canJoinAllSpaces`：应用切换、两个普通桌面、焦点、显示器插拔。
  验证：`.floating + .canJoinAllSpaces` 代码路径与落位/可见性判定有单元测试；真机多桌面与插拔矩阵**未自动验证**（需带会话人工确认）。
- [x] 验证全局快捷键实现与冲突反馈，不把现有 local monitor 当全局快捷键。
  验证：Carbon `RegisterEventHotKey`，注册冲突返回状态且保留原绑定（`GlobalHotkeyService`）；真机按键触发**未自动验证**。
- [~] 用独立打包 app 验证系统本地通知：授权、前台、后台、退出后、睡眠唤醒；记录签名与容量限制。
  验证：委托与路由有代码与假客户端测试；真实授权弹窗/退出后投递/睡眠唤醒**未自动验证**，边界记录见 `DEVELOPMENT_NOTES.zh-CN.md` §3。
- [x] 验证 bookmark 对移动文件及当前权限模型的适用性，确定是否需要 security-scoped 访问。
  验证：应用未沙盒化，采用普通 bookmark（非 security-scoped）；失效可“重新定位”。

验收：有可重复基线与验证记录；不会读写正式 Tic 数据；系统行为不符合预期时先修订方案，避免后续承诺不可实现的提醒能力。

## 3. M1：置顶、跨桌面与快捷创建

涉及：`Note`、`NotePanel`、`NoteWindowManager`、`AppModel`、`AppDelegate`、`NoteHeaderView`、MCP 创建入口、新增快捷键服务及偏好页。

- [x] 新便签默认置顶与跨桌面，增加独立开关及全局默认偏好。
  验证：`NotePreferences` 注册默认 true/true；设置页与便签开关；旧便签不被改写（仅新建读取）。
- [x] 建立统一创建策略供菜单栏、Dock、便签按钮与 MCP 使用；旧数据不改写。
  验证：`NoteWindowManager.newNote()` 与 MCP `create_note` 均读取同一 `NewNotePolicy`（默认值 + 目标分类）。
- [x] 修复现有 `openNote` 已存在窗口分支对 `makeKey: false` 的处理，区分展示与主动编辑。
  验证：已存在 panel + `makeKey:false` 不再调用 `makeKeyAndOrderFront`。
- [x] 实现可配置全局新建快捷键；保留应用内 `⌘N`，冲突时提示且不重复注册。
  验证：默认 `⌘⇧N`，`RegistrationResult` 反馈冲突；应用内 `⌘N` 不变。
- [x] 切换桌面或应用保持可见；后台恢复不激活应用；主动新建后可直接输入。
  验证：主动新建 `NSApp.activate` + `makeKeyAndOrderFront` + `requestTitleFocus()`；后台/筛选恢复不激活。

验收：新旧便签行为符合偏好，重启保持；全局快捷键在其他应用前台有效；全屏和 Stage Manager 单列验证结果，不以普通 Spaces 验收代替。

## 4. M2：分类与窗口筛选（首个可用版本）

涉及：category 增量迁移、`Note.categoryID`、分类 CRUD/观察、菜单栏分类选择、标题分类入口、窗口可见性协调器、MCP。

- [x] 分类新增、改名、排序、删除；未分类不建可删除的普通记录。
  验证：`CategoryDatabaseTests`（CRUD/排序/校验）；未分类 = `categoryID IS NULL`，无实体行。
- [x] 增加按分类赋值的窄字段更新，删除分类迁回未分类。
  验证：`updateNoteCategory` 单列写；`CategoryDatabaseTests.deleteSetsNull` 证明 FK `ON DELETE SET NULL`。
- [x] 持久化 all / selected 筛选模式，支持空集合、未分类、多选。
  验证：`CategoryFilterTests` + `CategoryFilterStore`（UserDefaults JSON）；空集合语义为“显示为空”。
- [x] 分类隐藏使用临时显隐，不修改 `isOpen`；手动关闭仍持久化。
  验证：`NoteWindowManager` 用 `hiddenByFilter` + `orderOut`，不触碰 `isOpen`。
- [x] restore、showAll、搜索、MCP open/focus、创建分类默认值全部接入同一策略。
  验证：统一经 `reconcileVisibility()`。
- [x] 处理新建到未分类且被筛选排除、删除当前分类、移动正在显示便签等边界。
  验证：`revealNote(withCategory:)`、删除分类时从持久化选择移除该 id。
- [x] MCP 可读取分类、创建/分配分类，新增字段兼容旧客户端。
  验证：`list_categories`/`create_category`/`rename_category`/`delete_category`/`set_note_category`；`MCPOrganisationTests` 通过；`noteValue` 仅在存在时新增 `category_id`。

验收场景：A/B 两分类各两张便签，手动关闭 A1 → 仅显示 B → 改回 A → 重启；A1 始终关闭，A2 按筛选恢复，B 不被误删除，位置不变。分类切换不夺走其他应用输入焦点。

## 5. M3：文件、代码仓与链接

- [x] 增加 resource 表及便签资源列表；首版关联到便签，不混入任务正文。
  验证：v7 `resource` 表 + `ResourceListView`；`ResourceDatabaseTests`。
- [x] 支持文件/文件夹选择与拖入、网页 URL 添加、显示名称修改、删除关联。
  验证：`NoteController.attachResource/attachWebLink/renameResource/removeResource`；DB 层测试。
- [x] 本地 bookmark 解析、失效处理、重新定位、Finder 显示与默认应用打开。
  验证：`ResourceAccessService` + `relocateResource`；`ResourceDatabaseTests.relocate`。
- [x] 仓库作为一种目录资源；支持关联远程网页链接；选定编辑器集成可后置。
  验证：`ResourceAccessService.kind(for:)` 将含 `.git` 的目录标为 `.repository`。
- [x] 校验 URL 协议与拖拽内容，不隐式执行 shell 或仓库脚本。
  验证：`validatedResourceURL` 仅放行 `file`/`http`/`https`；无任何 shell/脚本执行路径。
- [x] MCP 新增资源读写时复用相同校验，不允许远程参数绕过本地资源访问规则。
  验证：`add_resource` 复用 `validatedResourceURL`；`MCPOrganisationTests.resourceValidation` 证明 `javascript:` 被拒。

验收：中文/空格路径、文件移动、原文件删除、外接盘不可用、重复添加和重启后打开；移除关联保留原文件；网页用浏览器打开。

## 6. M4：截止时间与系统提醒

- [x] 新增任务 dueAt 与 taskReminder 迁移，提供日期时间编辑与清除入口。
  验证：v8 迁移；`TaskRowView` 截止时间 chip + 编辑弹层；`set_task_due` MCP。
- [x] 先增加 NotificationRouter，保留更新通知原行为，再接入任务通知。
  验证：`UpdateChecker.postBanner` 改走 `NotificationRouter.updateRequest`，文案/行为不变，identifier 命名空间化。
- [x] 提醒协调器：提交后调度、启动核对、唤醒核对、时区变化核对、失败可重试。
  验证：`ReminderCoordinator.reconcile()` 幂等；`AppDelegate` 挂唤醒 + 时区观察；失败记录日志下次重试。
- [x] 稳定任务通知 ID + revision，改期替换旧请求；完成级联、删除任务/便签取消相关通知。
  验证：`ReminderCoordinatorTests`（替换/完成级联/删除便签级联）。
- [x] 通知动作：打开便签、完成、稍后 10 分钟；过期 payload 重读任务并校验。
  验证：`NotificationRouterDelegate` 三类 action；`AppDelegate.validateAndAct` 重读 DB 拒绝已完成/缺失/旧 revision。
- [x] 权限按需申请；拒绝、无 bundle ID、调度失败有状态反馈。
  验证：`requestAuthorizationIfNeeded()`；`Availability` = available/denied/unavailable；`ReminderCoordinatorTests.authorizationOnDemand`。
- [x] 过期提醒按 revision 一次补发；分类隐藏不抑制提醒，通知送达不自动打开窗口。
  验证：`overduePostedOnce`（确认后不再补发）；协调器不查分类筛选；送达仅投递不唤起窗口。
- [x] 文档记录退出后提醒的实测边界及系统待处理容量；不声称关机时必达。
  验证：`DEVELOPMENT_NOTES.zh-CN.md` §3 明确边界与“不保证关机送达”。
- [x] MCP 设置/清除 DDL 与提醒，并复用相同调度逻辑。
  验证：`set_task_due`/`set_task_reminder`；经 `onRemindersChanged` 触发同一协调器。

验收：一分钟后提醒、提前提醒、改期、完成及级联完成、撤销完成、删除、稍后、旧通知动作、应用重启、应用退出、睡眠唤醒、权限拒绝、系统时区切换；每个场景记录预期与实际结果。

## 7. M5：整合与交付

- [x] 完成实际升级数据备份、迁移、恢复演练；确认旧图片与任务结构完整。
  验证：真机 v5→v8 升级 + 迁移前快照停在 v5 + 恢复后重迁移，旧便签保留（见 `DEVELOPMENT_NOTES.zh-CN.md` §5）。图片/任务的迁移保留由 `AppDatabaseMigrationTests` 覆盖。
- [x] 窗口、分类、快捷键、资源、提醒组合回归，检查竞态和焦点。
  验证：`swift test` 全绿（含窗口/控制器/提醒/MCP）；窄字段写避免复写并发编辑。真机组合回归**部分未自动验证**。
- [x] 至少验证当前开发 macOS；macOS 14 与其他版本的无法覆盖项明确标记“未验证”。
  验证：当前 macOS 26.6.2 已运行；macOS 14 运行行为在 `DEVELOPMENT_NOTES.zh-CN.md` 标记“未验证”。
- [~] 测试双显示器插拔、多 Spaces、Stage Manager、全屏应用及重启恢复。
  验证：落位/可见性判定有单元测试；重启恢复真机验证（`restored N note panel(s)`）。多显示器/Stage Manager/全屏矩阵**未自动验证**。
- [x] 完成用户说明、快捷键与权限说明、已知限制、打包版本与上游差异说明。
  验证：`docs/DEVELOPMENT_NOTES.zh-CN.md`（差异表、快捷键、权限、已知限制、恢复步骤）。
- [x] 运行完整构建/测试并打包；外部分发前再处理 Developer ID 与公证。
  验证：`swift build` + `swift test`（176/26 全绿）+ `scripts/package.sh` 成功。Developer ID 与公证留待外部分发。

完成定义：需求均有验证证据，已知限制明确，开发包可日常使用，原有 Todo、图片、MCP、更新通知无回归。

## 8. 测试分层与工程约束

| 层次 | 必须覆盖的行为 |
| --- | --- |
| 纯逻辑 | 分类匹配、提醒期望集合、revision 去重、时间边界；使用固定 clock |
| 数据库 | v5 fixture 增量升级、分类删除 SET NULL、资源/提醒级联、窄字段更新不覆盖其他状态 |
| 窗口集成 | 筛选隐藏与手动关闭区别、恢复焦点、已存在窗口的 makeKey 语义 |
| 通知模拟 | fake notification client 验证添加/替换/取消、旧动作无效与更新通知路由 |
| MCP | 创建默认值、显式 false、分类/资源/提醒与 UI 行为一致 |
| 人工真实 app | Spaces、全局快捷键、授权、退出后通知、睡眠、bookmark、显示器 |

复用现有 `Tests/TicTests/`，只为有状态变化和回归风险的行为加有意义测试。每阶段运行受影响测试；里程碑通过前运行 `swift build` 与 `swift test`，窗口/通知变更必须验证打包 app。文档变更本身只做链接与 diff 检查，不启动应用。

## 9. 下一步执行入口

从 M0 开始，先隔离数据和保护迁移，再做窗口/快捷键与系统通知的最小验证。M0 产出验证记录后实施 M1，不直接跨到通知 UI。更新本文件的复选框时必须附实际验证结果，不能以代码已编写代替验收通过。
