# Tic 二次开发方案

日期：2026-10-14  
状态：待实施；本文记录产品与技术决策，不代表功能已实现。  
源码基线：`fab0042`，以本地实际代码为准。实施顺序见 [开发计划](DEVELOPMENT_PLAN.zh-CN.md)。

## 1. 产品目标与范围

面向 macOS 14+，开发本地优先的项目便签工具。核心体验：切换其他应用后便签仍置顶，切换普通桌面 Spaces 后仍可见；可用分类控制当前展示的便签，并关联任务、截止时间、本地文件、代码仓目录及网页。

用户已确认：使用 Tic 为基础；需要分类、快捷创建、Todo 勾选、置顶与跨桌面、资源关联、DDL 提醒、仅显示选定分类。

以下为本方案的默认设计，可在实施中调整：单便签属于一个分类；资源先关联到便签；DDL 先关联到任务；第一版提醒默认使用 macOS 系统通知；新便签默认置顶且跨桌面。上述默认设计不等于用户逐项确认。

第一版不包含：云同步、Git 状态扫描与自动拉取、GitHub Issue 同步、自然语言时间解析、重复任务、任意文件内容索引、覆盖系统安全界面。全屏应用覆盖作为独立兼容性验证项，不与普通 Spaces 可见混为一谈。

## 2. 已核实的项目基础

| 能力 | 本地代码事实 | 二次开发工作 |
| --- | --- | --- |
| 窗口 | `NotePanel.apply` 已支持 `.floating` 与 `.canJoinAllSpaces`，`hidesOnDeactivate = false` | 设置新便签默认值，补齐显式控制入口及验证 |
| 默认值 | `Note` 的 `floatOnTop`、`showOnAllSpaces` 均默认 false；MCP 创建也有独立默认值 | 所有创建入口统一读取偏好；旧便签不批量改写 |
| 待办 | 稳定 UUID、三级层次、勾选级联、拖动排序 | 保留 TaskOutline，叠加截止时间 |
| 创建 | 菜单栏、Dock、便签按钮、应用内 `⌘N` | 新增真正的系统全局快捷键 |
| 存储 | GRDB + SQLite，现有迁移 v1 至 v5，图片独立存储 | 增量迁移，增加分类、资源和提醒 |
| 通知 | UpdateChecker 已发更新通知；AppDelegate 统一接收通知点击 | 先加通知类型路由，再接入任务提醒 |
| 窗口关闭 | `isOpen` 记录用户打开意图；关闭后重启不恢复 | 分类隐藏不能写成用户关闭 |
| MCP | 已有工具、内部服务和 Unix socket | 扩展字段时保持 UI / MCP 语义一致 |

主要入口：`AppModel.swift`、`Windows/NoteWindowManager.swift`、`Windows/NotePanel.swift`、`Controllers/NoteController.swift`、`Database/AppDatabase.swift`、`Database/AppDatabase+Tasks.swift`、`AppDelegate.swift`、`MCP/`。

上游 `PLAN.md` 含早期设计与历史方案，部分内容已经过时。实现事实以源码和测试为准；本文和开发计划描述本次扩展，不覆盖上游历史。

## 3. 用户流程

### 3.1 创建与持续显示

菜单栏或全局快捷键 → 新便签 → 当前仅选中一个分类时自动归入该分类，否则归入“未分类”。新便签继承置顶、跨桌面的全局默认值，每张便签可独立覆盖。

在多分类筛选中，创建“未分类”便签时若未分类当前被排除，提示并把“未分类”加入可见集合，保证刚创建内容可见。菜单栏、Dock、便签加号、MCP 创建均复用同一创建策略。

后台恢复、分类切换和通知送达不抢键盘焦点；主动新建、主动点击“打开便签”时获取焦点用于编辑。全局快捷键支持配置，建议初始候选为 `⌘⇧N`，注册冲突必须反馈并允许更换。

### 3.2 分类与窗口显示

便签标题区域显示分类，菜单栏提供多选分类与“全部 / 未分类”。分类管理支持新建、改名、调整顺序、删除；删除分类将便签移到未分类，保留内容。

有效可见条件：`note.isOpen && filter.matches(note.categoryID) && !temporarilyHideAll`。

- 分类取消选择：临时 `orderOut`，保留窗口控制器、位置、折叠状态和 `isOpen`。
- 再次选择：恢复本来打开的便签，不打开用户之前手动关闭的便签。
- 手动关闭：持久化 `isOpen = false`。
- “显示当前分类”：仅前置匹配且已打开的便签，不绕过筛选。
- 选择搜索结果或通知中的“打开”：该便签显式设为打开；若被筛选排除，先提示所属分类并将其加入可见集合，再打开。
- 分类隐藏不暂停任务提醒；“隐藏全部”为会话临时状态，重启清除；分类选择跨启动保留。
- 全部与空选择分开表示：全部 = 无限制，空集合 = 不展示任何分类；未分类作为独立选项。

窗口显隐集中由 `NoteWindowManager` 的新增协调入口处理。现有 `showAll`、restore、搜索、MCP open/focus 都必须接入；不从数据库 observer 反复调用会修改 `isOpen` 的 open/close 方法。

### 3.3 关联资源

便签底部提供“关联资源”：拖入文件或文件夹，或粘贴网页 URL。类型为文件、目录、代码仓目录、网页。

第一版代码仓是目录关联：可在 Finder 显示、用默认应用打开；支持用户选定的编辑器后再提供“在编辑器打开”。不执行仓库脚本或自动调用 Git。网页支持浏览器打开和复制链接。

本地资源以引用保存，使用 macOS URL bookmark，辅以路径供展示和失效定位；按打包权限决定是否需要 security-scoped bookmark。失效时展示“重新定位”，不删除资源记录。移除关联不删除原文件。网络 URL 先支持 http/https，文件打开与网页打开走不同代码路径。

### 3.4 DDL 提醒

任务行设置截止时间与可选提前提醒时间，显示日期及逾期状态；初版用日期时间选择器，允许取消提醒。截止时间与提醒时间是两个字段，提前提醒不改变 DDL。

默认用系统通知完成弹窗提醒；若之后需要必须手动关闭的独立提醒窗口，作为另一个模式开发。通知受系统授权、专注模式、睡眠和关机影响，不承诺指定秒数必达，也不使用后台进程绕过系统设置。

通知操作：打开便签、完成、稍后 10 分钟。稍后只修改提醒时间；完成操作复用现有任务级联逻辑。完成、删除任务、删除便签后取消对应待处理及已展示通知；撤销完成时按当前时间重新判断是否安排。

## 4. 数据方案

继续使用 GRDB，UUID 存储格式与现有 `.blob` 主键一致。以下为拟议 schema，迁移编号以实施时最新版本为准。

| 数据 | 拟议字段与约束 |
| --- | --- |
| `category` 新表 | id PK、name、sortIndex、createdAt、updatedAt；去除首尾空白后校验非空和重名 |
| `note.categoryID` | nullable FK → category，删除分类 SET NULL；null 表示未分类；加索引 |
| `resource` 新表 | id PK、noteID FK CASCADE、kind、label、url/path、bookmarkData nullable、sortIndex、createdAt、updatedAt |
| `task.dueAt` | nullable datetime，保存确定的时间点，显示时按当前时区转换 |
| `taskReminder` 新表 | taskID PK/FK CASCADE、remindAt、revision、acknowledgedRevision nullable、updatedAt |
| 偏好 | UserDefaults 保存新便签默认行为、分类筛选、全局快捷键；应用级 UI 偏好不写到单个任务 |

一项任务初版只有一个待提醒时点；通知 identifier 使用稳定 task UUID 命名空间，payload 携带 revision。时间变更增加 revision，旧通知动作必须重新读库校验；已完成或已删除的任务不允许被旧动作重新操作。

分类筛选建议表示为 `all` 或 `selected(categoryIDs, includesUncategorized)`。删除分类时同时移除失效筛选 ID。资源索引不加载 bookmark/blob 到任务列表的观察查询中。

数据迁移必须追加版本，不改写 v1-v5；先完成可靠备份和恢复路径。当前 DEBUG 开启 `eraseDatabaseOnSchemaChange`，进入开发前关闭真实数据路径上的自动擦库，使用独立开发数据目录；测试数据库可重建。备份使用 SQLite/GRDB 一致性备份，不能在数据库打开且可能有 WAL 时只复制主文件。

保持字段级 UPDATE：分类、DDL、提醒、窗口位置各自更新，避免旧快照覆盖其他入口的修改。多步骤数据修改在事务中提交；系统通知是事务外副作用，通过协调器重试修复。

## 5. 模块与边界

建议新增，命名可随实现调整：

- `Models/Category.swift`、`ResourceLink.swift`、`TaskReminder.swift`、`CategoryFilter.swift`。
- `Database/AppDatabase+Categories.swift`、`+Resources.swift`、`+Reminders.swift`：CRUD、窄字段写入、观察查询。
- `Services/GlobalHotkeyService.swift`：快捷键注册/注销、冲突反馈。优先评估系统 hotkey 注册方案，避免仅为快捷键引入辅助功能监听权限；在 M0 验证部署目标与可用性。
- `Services/ResourceAccessService.swift`：bookmark 解析、打开、Finder 定位、重新关联。
- `Services/ReminderCoordinator.swift`：期望通知集合计算、系统 pending requests 协调、补发与去重。
- `Services/NotificationRouter.swift`：统一更新通知与任务通知的 category、identifier、点击和动作分发，保留现有更新页面跳转。
- `Views/CategoryPicker.swift`、`CategoryManagementView.swift`、`ResourceListView.swift`、`TaskDueDateEditor.swift`、偏好设置页。

保留 `NoteController` 的 AppKit-free 边界，窗口副作用通过 closures / manager；Swift 6 的 MainActor 与 Sendable 约束延续现有模式。MCP 扩展走相同数据库与领域操作，不直接修改 SQLite 文件，不创建第二套分类或提醒规则。

### 通知协调策略

数据库为意图来源，系统 pending requests 为实际状态。创建/改期/完成/删除后，提交事务再协调；启动、唤醒、时区变化时再核对。定时触发依赖已提交的系统本地通知，不仅依赖进程内 Timer。

协调器用可注入 clock 与 notification client。对未完成且未来到期的提醒添加请求，对无效请求删除；核对 delivered/pending 与 revision 后标记已处理。错过提醒时合并成一次“逾期待处理”摘要并记录已补发 revision，避免每次启动重复弹。系统已展示过的同 revision 不再补发；通知中心没有记录的过期提醒按一次补发处理，不宣称能识别用户是否看过。

首次设置提醒时按需申请授权；拒绝后仍保存 DDL，展示明确状态和系统设置入口。无 bundle ID 的 `swift run` 路径只显示不可用状态，不崩溃。系统待处理请求的容量、ad-hoc 签名与退出后送达能力须在 M0 以真实 app 包验证；容量不足时滚动安排最近提醒并明确边界，不能承诺退出后无限数量提醒。

## 6. 实施决策与兼容性

1. 新便签默认置顶与跨桌面；旧便签保留已有状态，提供用户主动“应用到当前便签”。MCP 省略参数使用全局默认，显式 false 必须保留。
2. 浮窗不升级到屏保或系统警报层级。全屏是否展示独立验证，后续再决定是否加单独开关。
3. 检查现有 `openNote` 复用已存在 panel 时忽略 `makeKey: false` 的路径，修复后台恢复/筛选导致抢焦点的可能性。
4. 提醒动作遇到被筛选便签，仅主动打开动作可以调整筛选；单纯通知送达不改变窗口和焦点。
5. 本次保留产品名称和上游署名；开发包使用独立 bundle ID、数据目录、socket 路径及更新源设置，防止和正式 Tic 冲突。二次开发版本不能继续把上游 release 当作自己的更新。
6. 全部阶段不依赖账户和外部服务。资源不存在、通知拒绝、快捷键冲突均提供可恢复反馈。

## 7. 验收重点

- 在编辑器、浏览器等应用间切换和普通 Spaces 间切换，便签按开关持续可见；恢复/筛选不抢焦点。
- 分类隐藏不影响手动关闭、位置和折叠；筛选持久化，重启不复活手动关闭的便签。
- 所有创建入口使用统一默认值和分类规则，Todo 原有级联与拖动语义保持。
- 文件名含空格/中文、移动或删除、外置盘卸载均可恢复处理；删除关联不动原文件。
- 提醒改期/完成/删除/旧动作/退出/重启/睡眠唤醒/权限拒绝有可复现测试，更新通知仍跳转正确页面。
- 原有数据库升级后数据、任务层级、图片及窗口位置不丢失。

具体任务、依赖、验证和交付见 [开发计划](DEVELOPMENT_PLAN.zh-CN.md)。
