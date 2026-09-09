# PR 描述模板

> 文档编号：KA-09-02
> 级别：L4 ⚖️
> 状态：现行
> 关联代码：仓库 Git 历史（`master` 单主干、14 次合并提交）、`docx/` 全部文档
> 最近更新：2026-09-09
> 变更触发条件：分支策略变化、评审流程变化、关联编号体系增删、新增平台或页面时

---

## 一句话结论（TL;DR）

1. PR 描述必须回答六件事：**改了什么、为什么改、影响谁、怎么验证、出问题怎么回滚、文档更新了哪些**；缺任何一项评审直接退回。
2. 每个 PR 只做一件事（`../07-推进计划/工程化推进总纲.md` P-03），标题沿用提交信息格式 `type(scope): subject`，正文用本模板。
3. **现状是没有 PR 模板**：仓库无 `.github/` 目录，历史 18 个 PR 的描述由作者自由书写；本模板是目标态，落地后需在 `T-M7-02` 中登记。

---

## 1. 现状（实测事实）

| 项 | 实测值 | 核对方式 |
|---|---|---|
| 仓库是否有 PR 模板 | **无**（无 `.github/PULL_REQUEST_TEMPLATE.md`，无 `.github/` 目录） | `Get-ChildItem .github` |
| 历史合并 PR 数 | 11（编号 #1~#5、#7、#8、#16~#18、#20） | `git log --merges --format='%s'` |
| 合并提交总数 | 14 | `git log --merges` |
| 分支命名实际样例 | `feat/qr-login`、`feat/view-artist`、`fix/login-icon-button`、`fix/sliver-header-overlay-pr`、`fix/webapi-session-header-flutter` | 合并提交信息 |
| 贡献者 | 6（`cnb`、`Xiaoqi2145`、`XiaoMai`、`Lins`、`hank`、`bakamake`） | `git log --format='%an'` |
| 评审依据文档 | `../08-工程纪律/代码评审清单.md`（**尚未生成，待核实**） | 目录实测 |
| 关联编号体系 | `TD-xx` / `C-xx` / `K-xx` / `A-xx` / `R-xx` / `RC-xx` / `T-Mx-xx` / `G-xx` / `KA-BUG-YYYYMMDD-nn` | `../06-质量保障/已知问题与技术债台账.md` §1 |

---

## 2. 可直接复制的模板

```markdown
## 变更摘要

<3 行以内说清这个 PR 做了什么、解决什么问题。不要复述 diff。>

## 变更类型

- [ ] feat 新功能
- [ ] fix 缺陷修复
- [ ] refactor 重构（行为不变）
- [ ] perf 性能优化
- [ ] docs 文档
- [ ] test 测试
- [ ] build 构建/依赖/打包
- [ ] ci 门禁与流水线
- [ ] chore 杂项

## 关联缺陷 / 任务编号

| 类型 | 编号 | 说明 |
|---|---|---|
| 缺陷/技术债 | TD-xx | |
| 任务 | T-Mx-xx | |
| 回归用例 | RC-xx | |
| 运行时缺陷 | KA-BUG-YYYYMMDD-nn | |
| Issue / PR | #N | |

## 影响范围

**页面**（勾选实际受影响的页面）：

| 页面 | 受影响 | 对应用例 |
|---|---|---|
| ... | | |

**模块**：config / core / models / services / controllers / ui / 原生
**平台**：Android / iOS / Windows / macOS / Linux / Web

## 测试方式与证据

| 项 | 内容 |
|---|---|
| 自动化 | `flutter analyze` / `flutter test` / `dart format --set-exit-if-changed` |
| 新增用例 | <文件:用例数> |
| 手工验证 | <步骤 + 结论> |
| 证据 | <截图 / 日志 / 录屏 / 命令输出> |

## 风险与回滚方案

| 项 | 内容 |
|---|---|
| 主要风险 | |
| 影响面 | |
| 回滚方式 | `git revert <sha>` / 还原开关 / 还原配置 |
| 回滚代价 | |

## 文档更新清单

- [ ] `docx/04-数据与接口/`（接口/存储键变化时）
- [ ] `docx/03-模块详解/`（模块行为变化时）
- [ ] `docx/05-平台与原生/`（原生能力变化时）
- [ ] `docx/06-质量保障/`（新增用例 / 技术债状态）
- [ ] `update.md`（用户可见变更）
- [ ] 无需更新（说明理由）

## 自检勾选项

- [ ] 单个 PR 只做一件事，可独立回滚
- [ ] `flutter analyze` 零 error
- [ ] `dart format` 无差异
- [ ] `flutter test` 全绿（52 例基线不下降）
- [ ] 新增/修改的纯函数、状态机、解析器已带测试
- [ ] 无新增 `// TODO` 悬挂
- [ ] 未提交密钥、keystore、本地路径、临时文件
- [ ] 触及契约的文档已同提交更新
- [ ] 手动冒烟：<列出执行过的 RC 用例编号>
```

---

## 3. 逐字段填写规则

### 3.1 变更类型

| 类型 | 判定标准 | 常见误用 |
|---|---|---|
| `feat` | 用户可感知的新能力 | 把内部重构写成 feat |
| `fix` | 修复可复现的错误行为，必须有关联 `KA-BUG` 或 `TD` | 把「顺手优化」写成 fix |
| `refactor` | 行为完全不变（可用对照录屏/测试证明） | 重构同时改逻辑 |
| `perf` | 有前后对比数据 | 无数据声称「更快」 |
| `docs` | 只改 `.md` 与注释 | 文档里夹带代码改动 |
| `test` | 只改 `test/` | 为通过测试而改产品代码 |
| `build` | `pubspec.yaml`、Gradle、签名、ABI | 把 CI 脚本算作 build |
| `ci` | `scripts/`、工作流 | — |
| `chore` | 发版、忽略文件、清理 | 能归类时不要用 chore |

> 一个 PR **只勾一个主类型**；确有多类改动时，说明为什么无法拆分，并给出后续拆分任务编号。

### 3.2 关联编号前缀表

| 前缀 | 含义 | 唯一来源 |
|---|---|---|
| `TD-xx` | 技术债 / 缺陷主编号 | `../06-质量保障/已知问题与技术债台账.md` |
| `C-xx` | 缓存体系专项缺陷 | `../03-模块详解/服务层-缓存体系.md` |
| `K-xx` | 本地存储与配置专项问题 | `../04-数据与接口/本地存储与配置项清单.md` |
| `A-xx` | 架构越层例外 | `../02-架构设计/分层架构与依赖规则.md` |
| `R-xx` | 风险 | `../07-推进计划/风险登记册.md` |
| `RC-xx` | 回归用例编号 | `../06-质量保障/回归测试用例库.md` |
| `T-Mx-xx` | WBS 任务编号 | `../07-推进计划/任务分解-WBS.md` |
| `G-xx` | 测试缺口编号 | `../06-质量保障/测试策略与现有用例.md` §7 |
| `KA-BUG-YYYYMMDD-nn` | 运行时缺陷报告编号 | `../08-工程纪律/缺陷处理纪律.md` |

> 关联编号**必须能在来源文档中查到**；查不到就是编号错误，评审退回。

### 3.3 影响范围 · 页面清单（20 个页面，逐项勾选）

| 页面文件（`lib/ui/pages/`） | 公开类 | 对应用例域 |
|---|---|---|
| `player_page.dart` | `PlayerPage` | RC-PL、RC-LY、RC-EF |
| `home_page.dart` | `HomePage` | RC-HM |
| `playlist_detail_page.dart` | `PlaylistDetailPage` | RC-LB-01~07 |
| `library_page.dart` | `LibraryPage` | RC-LB-03/04 |
| `settings_page.dart` | `SettingsPage` | RC-ST、RC-CA |
| `login_page.dart` | `LoginPage` | RC-AU |
| `search_page.dart` | `SearchPage` | RC-SE |
| `cloud_drive_page.dart` | `CloudDrivePage` | RC-LB-08 |
| `artist_detail_page.dart` | `ArtistDetailPage` | 无专用用例（建议补） |
| `personalization_settings_page.dart` | `PersonalizationSettingsPage` | RC-ST-01~03 |
| `about_page.dart` | `AboutPage` | 无专用用例（建议补） |
| `playback_history_page.dart` | `PlaybackHistoryPage` | RC-LB-09 |
| `downloaded_songs_page.dart` | `DownloadedSongsPage` | RC-DL-03/05 |
| `playback_stats_page.dart` | `PlaybackStatsPage` | RC-LB-09 |
| `desktop_lyrics_settings_page.dart` | `DesktopLyricsSettingsPage` | RC-LY-09 |
| `local_songs_page.dart` | `LocalSongsPage` | RC-LC |
| `comment_page.dart` | `CommentPage` | 无专用用例（建议补） |
| `album_shop_page.dart` | `AlbumShopPage` | RC-HM-05 |
| `app_shell.dart` | `AppShell` | 全局（导航/迷你播放器） |
| `audio_interruption_settings_page.dart` | `AudioInterruptionSettingsPage` | RC-PL-16 |

### 3.4 影响范围 · 模块与平台

| 维度 | 取值 | 判定依据 |
|---|---|---|
| 模块 | `config` / `core` / `models` / `services` / `controllers` / `ui` / `android`（原生） | 分层见 `../02-架构设计/分层架构与依赖规则.md` |
| 平台 | Android / iOS / Windows / macOS / Linux / Web | 能力矩阵见 `../05-平台与原生/多平台差异矩阵.md` §2 |

**平台影响填写要求**：

| 场景 | 填写要求 |
|---|---|
| 仅改 Dart 逻辑 | 勾 Android（主力），并在说明中写「其余平台未实测」 |
| 触及自建原生通道 | 必须勾 Android，并注明 iOS/桌面端行为（大多数为不支持） |
| 触及文件系统/下载/缓存 | Web 必须标注「不支持」（`dart:io` 依赖） |
| 触及音频播放 | Windows/Linux 必须标注「不支持」（缺 `just_audio` 平台实现） |

### 3.5 测试方式与证据

| 项 | 必须提供 | 命令 / 形式 |
|---|---|---|
| 静态分析 | 必须 | `flutter analyze`（要求零 error） |
| 格式 | 建议 | `dart format --set-exit-if-changed .` |
| 单元测试 | 必须 | `flutter test`；新增用例给出「文件 + 用例数」 |
| 覆盖率 | 建议 | `flutter test --coverage`（当前基线 23.76%，见 `../06-质量保障/测试策略与现有用例.md` §1.4） |
| 手工回归 | 必须（涉及 UI/播放时） | 列出执行的 `RC-xx` 编号与结论 |
| 证据附件 | 必须（涉及 UI 时） | 截图 / 录屏 / logcat 片段 |

> PowerShell 下 `flutter test` 的 `$LASTEXITCODE` 可能是 1（Flutter 向 stderr 写资源提示），**以 stdout 的 `All tests passed!` 为准**。

### 3.6 文档更新清单（触发式）

| 改动内容 | 必须更新的文档 |
|---|---|
| 新增/删除 API 端点 | `../04-数据与接口/API-端点清单.md`、`API-契约总览.md` |
| 新增/修改设置项 | `../04-数据与接口/本地存储与配置项清单.md`、`../03-模块详解/UI层-页面与组件清单.md` |
| 新增/修改数据模型字段 | `../04-数据与接口/数据模型参考.md` |
| 改动缓存策略/上限 | `../03-模块详解/服务层-缓存体系.md`、`../04-数据与接口/本地存储与配置项清单.md` |
| 改动播放链路 | `../03-模块详解/控制器层-PlayerController.md` |
| 新增平台原生能力 | `../05-平台与原生/` 全部相关文档 |
| 版本发布 | `../07-推进计划/里程碑与版本路线图.md`、`update.md` |
| 发现新缺陷/技术债 | `../06-质量保障/已知问题与技术债台账.md` |

### 3.7 自检勾选项说明

| 勾选项 | 不合格判定 |
|---|---|
| 单个 PR 只做一件事 | 同时改 3 个以上互不相关模块 |
| `flutter analyze` 零 error | 有 error 或新增 warning 未说明 |
| `flutter test` 全绿 | 用例数低于 52 且无说明 |
| 新增纯函数/状态机/解析器带测试 | 违反 `../06-质量保障/测试策略与现有用例.md` §4 的 C-01~C-08 |
| 未提交密钥 | 出现 `buildKey.keystore`、`key.properties`、token、手机号 |
| 文档同提交 | 触及契约但文档未改（规范 D-08） |

---

## 4. 完整填写示例

> 示例内容依据真实代码与台账（`lib/config/app_config.dart:41-43`、`lib/services/artwork_cache_service.dart`、`TD-05`、`T-M3-03`）；「手工验证」中的设备信息为示例值。

```markdown
## 变更摘要

缩略图缓存上限从固定 512MB 改为用户可配置（64MB ~ 4GB），并在设置页新增「占用大小 / 一键清理 / 上限输入」三项。解决大屏用户封面缓存长期占用存储、又无法调整的问题。

## 变更类型

- [x] feat 新功能
- [ ] fix 缺陷修复
- [ ] refactor 重构（行为不变）
- [ ] perf 性能优化
- [ ] docs 文档
- [ ] test 测试
- [ ] build 构建/依赖/打包
- [ ] ci 门禁与流水线
- [ ] chore 杂项

## 关联缺陷 / 任务编号

| 类型 | 编号 | 说明 |
|---|---|---|
| 缺陷/技术债 | TD-05 | 淘汰无低水位，达上限后每次新增触发全目录扫描（本次不修，留待 T-M3-03） |
| 任务 | T-M3-09 | 缓存设置页统一（数值来自同一 API） |
| 回归用例 | RC-CA-03 / RC-CA-04 / RC-CA-06 | 清理缩略图缓存 / 调整上限 / 离线显示已缓存封面 |
| Issue / PR | #21（示例编号） | — |

## 影响范围

**页面**：

| 页面 | 受影响 | 对应用例 |
|---|---|---|
| `settings_page.dart` | 是（缓存管理新增条目） | RC-CA-01~06 |
| `player_page.dart` | 是（背景图读取缓存上限） | RC-PL-01 |
| 其余页面 | 否 | — |

**模块**：`config`（新增常量）、`services`（上限读写与钳位）、`ui`（设置页输入）
**平台**：Android（已实测）；iOS / Windows / macOS / Linux / Web 未实测（缓存依赖 `dart:io`，Web 判定为不支持）

## 测试方式与证据

| 项 | 内容 |
|---|---|
| 自动化 | `flutter analyze` 零 error；`flutter test` 52 例全绿 |
| 新增用例 | `test/artwork_cache_lru_test.dart` 新增 2 例（上限钳位、超限淘汰顺序） |
| 手工验证 | Android 真机：设置页输入 64MB → 触发清理至 64MB 内；输入 4GB → 不再清理；断网重进首页，已浏览封面仍显示 |
| 证据 | 设置页前后截图 2 张；`adb logcat` 中 `ArtworkCache` 淘汰日志片段 |

## 风险与回滚方案

| 项 | 内容 |
|---|---|
| 主要风险 | 用户把上限调到极小（64MB）后，封面频繁失效重下，流量增加 |
| 影响面 | 仅缩略图缓存；不影响播放、下载、数据缓存 |
| 回滚方式 | `git revert <sha>`；或用户在设置页把上限改回 512MB |
| 回滚代价 | 低（无数据迁移，旧键 `settings.artwork_cache_max_bytes` 缺失时回退默认 512MB） |

## 文档更新清单

- [x] `docx/03-模块详解/服务层-缓存体系.md`（新增上限取值与钳位说明）
- [x] `docx/04-数据与接口/本地存储与配置项清单.md`（新增 `settings.artwork_cache_max_bytes`）
- [x] `update.md`（v2.2.0 条目新增一行）
- [ ] `docx/05-平台与原生/`（无原生改动）
- [ ] 其余无需更新

## 自检勾选项

- [x] 单个 PR 只做一件事，可独立回滚
- [x] `flutter analyze` 零 error
- [x] `dart format` 无差异
- [x] `flutter test` 全绿（52 例基线不下降）
- [x] 新增/修改的纯函数、状态机、解析器已带测试
- [x] 无新增 `// TODO` 悬挂
- [x] 未提交密钥、keystore、本地路径、临时文件
- [x] 触及契约的文档已同提交更新
- [x] 手动冒烟：RC-CA-03、RC-CA-04、RC-CA-06、RC-PL-01
```

---

## 5. 约束与坑

| # | 约束/坑 | 影响 | 核对锚点 |
|---|---|---|---|
| 1 | 仓库**没有** `.github/` 目录，PR 模板不会自动生效，必须把本文件内容手工粘贴或先创建 `PULL_REQUEST_TEMPLATE.md`。 | 模板形同虚设 | `Get-ChildItem .github` 实测 |
| 2 | 关联编号写错等于没写：`TD-xx` 必须能在台账总表中查到，`RC-xx` 必须能在用例库中查到。 | 追溯链断裂 | 台账 §2、用例库 §1~§11 |
| 3 | 「测试方式」只写「已自测」不算证据；涉及 UI 必须给截图或录屏。 | 评审无法判断 | §3.5 |
| 4 | 平台影响不得写成「全平台支持」。除 Android 外的一切格子默认是「未验证」，Web 的缓存/下载/本地音乐是「不支持」。 | 误导后续维护者 | `../05-平台与原生/多平台差异矩阵.md` §2 |
| 5 | 回滚方案不能写「重新提交修复」；必须给出可执行的还原动作（revert / 还原开关 / 还原配置）。 | 故障时无预案 | §3.6 |
| 6 | 涉及 `pubspec.yaml` 版本号的 PR 不得与功能改动混在一起，发版单独一个 PR/提交。 | 版本号与功能无法独立回滚 | `../01-项目总览/构建与发布流程.md` §4 |
| 7 | 项目当前无 CI（`TD-04`），所有门禁靠本地执行；PR 中应贴出本机命令输出，而不是声称「CI 通过」。 | 假绿 | `../06-质量保障/测试策略与现有用例.md` §6-1 |

---

## 6. 待办与关联

| 类型 | 内容 | 去向 |
|---|---|---|
| 待办 | 创建 `.github/PULL_REQUEST_TEMPLATE.md` 并把 §2 模板落地 | `../07-推进计划/任务分解-WBS.md` T-M7-02 |
| 待办 | 补充 `artist_detail_page`、`about_page`、`comment_page` 的回归用例（当前无对应用例） | `../06-质量保障/回归测试用例库.md` |
| 待办 | PR 门禁自动化（analyze + format + test） | `../08-工程纪律/测试与质量门禁.md`、T-M1-01 |
| 待核实 | 分支命名规范是否正式化（历史为 `feat/*`、`fix/*`） | `../08-工程纪律/分支与发布纪律.md` |
| 关联 | 提交信息规范 | `./提交信息模板.md` |
| 关联 | 代码评审清单 | `../08-工程纪律/代码评审清单.md` |
| 关联 | 缺陷报告模板 | `./缺陷报告模板.md` |
| 关联 | 发布检查清单 | `./发布检查清单.md` |
