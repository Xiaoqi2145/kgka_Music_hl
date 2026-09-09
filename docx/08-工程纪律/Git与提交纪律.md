> 文档编号：KA-08-03
> 级别：L4 ⚖️
> 状态：现行
> 关联代码：仓库级（.gitignore、.gitattributes、pubspec.yaml、android/app/build.gradle.kts）
> 最近更新：2026-09-08
> 变更触发条件：引入 CI、引入 PR 强制检查、调整分支模型、仓库迁移或历史重写、新增二进制资源类型

# Git 与提交纪律

## TL;DR

1. 提交粒度 = **一个提交只做一件事**；格式 = **`type(scope): subject`**，type 从 10 个取值中选，冒号必须半角。
2. 现状是**中英混用**（125 条中 79 条含中文、46 条纯英文、67 条用全角冒号、3 条 `fixs:`、1 条 `flx:`），本文件给出统一规则：**type/scope 英文小写，subject 与正文用中文**。
3. 提交前必须跑通 4 条命令（见 §8），并确认没有 `build/`、`.dart_tool/`、`local.properties`、签名文件入库。

---

## 1. 现状（事实）

| 项 | 实测 | 命令/锚点 |
|---|---|---|
| 提交总数 | 125 | `git rev-list --count HEAD` |
| merge 提交 | 14（含 4 个 PR 分支合并） | `git log --merges` |
| 含中文 subject | 79 | `git log --format='%s'` |
| 纯英文 subject | 46 | 同上 |
| 使用全角冒号「：」 | 67 | 同上 |
| 合规 `type: subject`（半角+空格） | 29 | 同上 |
| 类型拼写错误 | `fixs:` 3 条、`flx:` 1 条 | `e4c6a3a`、`f2598ae`、`01b303b`、`91d0b1b` |
| 非约定 type | `publish` 8、`add` 5、`remove` 4 | `git log` 统计 |
| 无 type 前缀 | 18 条（如 `增加接续播放功能`、`Update README.md`） | 同上 |
| 单提交文件数 | 均值 4.3；> 10 个文件的提交 18 条；最大 130 个文件（`b815758 add：init`） | `git show --stat` |
| 分支 | 仅 `master` | `git branch -a` |
| 远程 | `origin`（SSH）、`upstream`（HTTPS） | `git remote -v` |
| 标签 | `v1.6.0`、`v2.0.5`、`v2.3.0`、`v2.5.0` | `git tag` |
| 行尾/大文件属性 | `.gitattributes` 由 UGit 生成，仅对 `*.png/*.jar/*.pbxproj/*.ico/*.metadata` 启用 LFS | `.gitattributes:1-6` |
| 忽略规则 | `build/`、`.dart_tool/`、`.flutter-plugins-dependencies`、`coverage/` 已忽略 | `.gitignore:29-36` |

---

## 2. 提交粒度

| 规则 | 内容 |
|---|---|
| G2.1 | 一个提交只做一件事：功能、修复、重构、格式、文档各自独立 |
| G2.2 | 单提交建议 ≤ 10 个文件；超过必须说明理由或拆分（历史均值 4.3） |
| G2.3 | 重构与功能必须分开：`refactor:` 提交内不得夹带行为变更 |
| G2.4 | 纯格式改动单独提交（`style:`），不与逻辑改动混合 |
| G2.5 | 依赖升级单独提交（`build(deps):`），并附 `pubspec.lock` 变更 |
| G2.6 | 每个提交都必须能单独通过 `flutter analyze` 与 `flutter test` |

反例（历史真实提交，一次提交混了 5 件事）：

> `c59ef26`：`feat：新增下载和缓存音乐…feat：新增歌单信息…feat：优化我的页面UI/UX设计…feat：优化部分性能问题…feat：修复和优化了已知问题`

正例（单一目的、可独立回滚）：

> `c086bfa feat: add configurable artwork cache limit`（仅缩略图缓存上限可配置）
> `4fb3418 fix: bound loudness metadata cache lifetime`（仅响度缓存生命周期）

---

## 3. 提交信息格式

格式：`<type>(<scope>): <subject>`，第二行空行，第三行起为正文；破坏性改动加脚注。

### 3.1 type 取值（10 个，禁止自造）

| type | 含义 | 典型场景 | 历史出现次数 |
|---|---|---|---|
| `feat` | 新功能 | 新增扫码登录、接续播放 | 52 |
| `fix` | 缺陷修复 | 修复歌词错位、空指针 | 33 |
| `refactor` | 重构（行为不变） | 播放器 UI 状态重构 | 1 |
| `perf` | 性能优化 | 背景图延迟、长列表虚拟化 | 0 |
| `test` | 测试相关 | 新增 LRU 淘汰单测 | 0 |
| `docs` | 文档 | 更新 `docx/`、`update.md` | 0（历史用 `Update README.md`） |
| `build` | 构建/依赖 | 签名配置、ABI、依赖升级 | 0 |
| `chore` | 杂项（不含上述） | 清理无效文件 | 0（历史用 `remove:` 4 次） |
| `style` | 格式（不影响行为） | `dart format` 结果 | 0 |
| `revert` | 回滚 | 回滚某次提交 | 0 |

> 历史遗留的 `add`（5）、`remove`（4）、`publish`（8）**不再使用**：`add` → `feat`，`remove` → `chore`/`refactor`，`publish` → `chore(release):`。

### 3.2 scope 取值（与模块对应）

| scope | 对应路径/领域 | 示例 |
|---|---|---|
| `config` | `lib/config/` | `feat(config): 新增缩略图缓存上限常量` |
| `core` | `lib/core/`（`ApiClient`） | `fix(core): 修正重试 deadline 判断` |
| `models` | `lib/models/` | `refactor(models): 拆分 music_models` |
| `services` | `lib/services/` 通用 | `feat(services): 新增失败缓存` |
| `api` | `lib/services/music_api.dart` | `feat(api): 新增 /listen/timeadd 封装` |
| `cache` | `cache_service.dart` / `artwork_cache_service.dart` | `fix(cache): 计数按删除量扣减` |
| `download` | `download_service.dart` / `download_controller.dart` | `feat(download): 支持断点续传` |
| `player` | `player_controller.dart` | `fix(player): 修复焦点恢复` |
| `lyrics` | 歌词解析/渲染/桌面歌词 | `feat(lyrics): 支持更换歌词版本`（历史 `e773882`） |
| `auth` | `auth_controller.dart` / 登录页 | `fix(auth): 修复扫码登录态丢失` |
| `theme` | `theme_controller.dart` / `app_theme.dart` | `feat(theme): 支持自定义背景` |
| `search` | 搜索页与搜索历史 | `feat(search): 新增热搜分类` |
| `ui` | `lib/ui/` 页面与组件 | `fix(ui): 修复顶栏穿透重叠` |
| `android` | `android/` 原生 | `feat(android): 新增 LoudnessEnhancer 通道` |
| `ios` / `desktop` | 对应平台目录 | `fix(desktop): 桌面歌词窗口置顶` |
| `docs` | `docx/`、根目录 `*.md` | `docs: 新增工程纪律九篇` |
| `ci` | CI 配置与门禁脚本 | `build(ci): 新增 scripts/check.ps1` |
| `release` | 版本发布 | `chore(release): v2.2.0` |

### 3.3 subject 与正文

| 规则 | 内容 |
|---|---|
| G3.1 | subject ≤ 50 字符，结尾不加句号 |
| G3.2 | subject 用**动词开头**（新增/修复/优化/移除/重构），不用「一些」「若干」 |
| G3.3 | 正文说明**为什么**与**影响面**；涉及缺陷时写 `KA-BUG-YYYYMMDD-nn` |
| G3.4 | 一行一个要点，可用 `-` 列表 |
| G3.5 | 关联任务写 `Refs: T-M3-02`；关联技术债写 `Refs: TD-01` |

---

## 4. 中英文使用规则（统一后）

| 位置 | 语言 | 说明 |
|---|---|---|
| `type` / `scope` | 英文小写 | 固定词表，见 §3 |
| 冒号与空格 | 半角 `: ` | **禁止全角「：」**（历史 67 条） |
| `subject` | 中文 | 描述用户可见变化；专有名词（`ApiClient`、`KRC`、`LUFS`）保持原文 |
| 正文 | 中文 | 引用代码标识符时用反引号 |
| 脚注关键字 | 英文 | `BREAKING CHANGE:`、`Refs:`、`Closes:` |

**存量处置**：不重写历史（会破坏所有克隆）。规则自本文件生效日起适用于新提交；历史不一致在评审时说明即可。

---

## 5. 正文与脚注

| 脚注 | 用法 | 示例 |
|---|---|---|
| `BREAKING CHANGE:` | 破坏性改动（存储键改名、公开签名变更、目录迁移） | 见下 |
| `Refs:` | 关联任务/技术债 | `Refs: TD-31` |
| `Closes:` | 关闭缺陷 | `Closes: KA-BUG-20260908-01` |

破坏性改动示例：

~~~text
refactor(storage)!: 迁移播放缓存目录到 ApplicationSupport

BREAKING CHANGE: 播放缓存目录由 getTemporaryDirectory() 迁移到
getApplicationSupportDirectory()，首次启动执行一次性搬移；回滚需删除新目录。
影响：已下载音频与播放缓存路径变化（cache_service.dart:35、download_service.dart:63）。
Refs: TD-02 / T-M3-05
~~~

---

## 6. 禁止提交的内容

| 类别 | 路径/文件 | 现状 | 处置 |
|---|---|---|---|
| 构建产物 | `build/`、`/android/app/release` | 已忽略 | 保持 |
| 工具缓存 | `.dart_tool/`、`.flutter-plugins-dependencies` | 已忽略 | 保持 |
| 本地配置 | `android/local.properties` | 未入库（实测） | 保持，勿提交 |
| 签名文件 | `buildKey.keystore` | **已入库**（`git ls-files` 命中；`bfe70bf` 引入） | 见 `docx/08-工程纪律/安全与合规纪律.md` §2（TD-31 / T-M5-01） |
| 凭证 | `key.properties`、`.env`、任何 token/t1 明文 | 未入库 | 加入 `.gitignore` 后永不再提交 |
| 覆盖率产物 | `coverage/` | 已忽略 | 保持 |
| 编辑器/OS | `.idea/`、`*.iml`、`.DS_Store` | 已忽略 | 保持 |
| 临时脚本 | `.tmp-extract.js`（当前未跟踪） | 未跟踪 | 用完删除，勿提交 |

> 注意：`.gitignore` 对**已跟踪文件无效**。已入库的 `buildKey.keystore` 必须显式 `git rm --cached`，仅改忽略文件不够。

---

## 7. 大文件与二进制处理

| 类型 | 现状 | 规则 |
|---|---|---|
| 图片 | `*.png` 走 LFS（`.gitattributes:2`）；`screenshots/*.jpg` 未纳入 | 新增 > 1MB 的图片必须走 LFS，并在 PR 说明 |
| JAR | `*.jar` 走 LFS | 保持 |
| 音频/APK | 未纳入 LFS，且禁止入库 | 禁止提交 `*.apk`、`*.aab`、`*.mp3` |
| 字体 | 当前无自定义字体 | 若引入，> 1MB 走 LFS |
| LFS 现状 | `.gitattributes` 由 UGit 自动生成，含 `*.pbxproj`、`*.ico`、`*.metadata` | 修改前先确认所有协作者已安装 Git LFS |

> 待核实：LFS 是否真的在远程生效（`git lfs ls-files` 未实测），克隆方若未安装 LFS 会得到指针文件。

---

## 8. 提交前自检命令清单

| # | 命令 | 通过标准 | 备注 |
|---|---|---|---|
| 1 | `git status --short` | 无意外改动；确认无 `build/`、`local.properties` | — |
| 2 | `dart format lib test` | 无输出改动 | 见 KA-08-02 §14 |
| 3 | `flutter analyze --no-fatal-infos` | 无新增违规 | 当前基线 11 条 info |
| 4 | `flutter test` | stdout 出现 `All tests passed!` | **不要只看 PowerShell 退出码**（`docx/06-质量保障/测试策略与现有用例.md:52-54`） |
| 5 | `git diff --staged` | 逐行确认动机一致、无调试代码 | — |
| 6 | `git log -1 --format='%s'` | 符合 `type(scope): subject` | — |

---

## 9. rebase 与 merge 的选择

| 场景 | 选择 | 理由 |
|---|---|---|
| 本地分支追主干 | `git rebase master` | 保持线性历史，便于 `git bisect` |
| 已推送到共享分支 | **禁止 rebase** | 会改写他人已拉取的历史 |
| 合并到 `master`（PR） | `squash merge` 或 `--no-ff` | 单人维护期建议 squash：一个 PR 一个提交 |
| 同步上游 | `git merge upstream/master` | 保留上游历史，便于追踪差异 |
| 紧急回滚 | `git revert`（不用 `reset`） | 已推送历史不得改写 |

---

## 10. 冲突解决纪律

| 规则 | 内容 |
|---|---|
| G10.1 | 解决冲突后必须**重新跑完整门禁**，不能只跑受影响测试 |
| G10.2 | 冲突解决不得顺手改动无关代码；解决即提交，提交信息写 `merge:` 或说明解决范围 |
| G10.3 | 冲突涉及 `pubspec.lock` 时，删除后重新 `flutter pub get` 生成，禁止手工合并 |
| G10.4 | 冲突涉及生成物（`docx/04-数据与接口/API-端点清单.md` 等自动生成文档）时，重跑生成脚本，禁止手工编辑 |
| G10.5 | 无法判断取舍时，保留双方并登记技术债，不得静默丢弃一方 |

---

## 11. 好提交与坏提交实例

### 11.1 10 条好提交（均为真实历史）

| # | 提交 | 为什么好 |
|---|---|---|
| 1 | `c086bfa feat: add configurable artwork cache limit` | type 正确、单一目的、描述具体 |
| 2 | `4fb3418 fix: bound loudness metadata cache lifetime` | 一句话说清修复范围 |
| 3 | `09af05e feat: cache artwork for offline playback backgrounds` | 说清用户价值 |
| 4 | `21a788c fix: stabilize cached track loudness normalization` | 聚焦单一缺陷 |
| 5 | `04bb5d0 fix: respect lyric text scaling in karaoke painter` | 明确受影响组件 |
| 6 | `720133f fix: keep lyrics synchronized while scrubbing` | 描述现象而非笼统「修复歌词」 |
| 7 | `8431943 fix: migrate stale API certificate domain` | 说明迁移动作 |
| 8 | `e773882 feat(lyrics): 支持更换歌词版本并过滤署名元数据` | scope 用法正确（唯一一条规范 scope） |
| 9 | `2af0187 fix: 修复歌单详情页与云盘页顶栏滚动时内容穿透重叠` | 半角冒号 + 现象具体 |
| 10 | `ba0dc11 fix: 修复 PlayerPage dispose 时 context 失效导致的空指针异常` | 含根因（context 失效） |

### 11.2 10 条坏提交（均为真实历史）

| # | 提交 | 问题 | 应改为 |
|---|---|---|---|
| 1 | `e4c6a3a fixs:歌单缩略图载入` | type 拼写错误 + 冒号后无空格 | `fix(cache): 修复歌单缩略图加载失败` |
| 2 | `f2598ae fixs:歌词阻塞` | 同上 + 描述不完整 | `fix(lyrics): 修复歌词加载阻塞 UI` |
| 3 | `91d0b1b flx：修复桌面歌词的一些问题` | type 拼错 + 全角冒号 + 「一些」模糊 | `fix(desktop): 修复桌面歌词窗口关闭后残留` |
| 4 | `4e5a98a 增加接续播放功能` | 无 type、无冒号 | `feat(player): 新增接续播放` |
| 5 | `b56039e feat：合并2.2内容` | 全角冒号 + 目的不明（「合并内容」不是目的） | 拆成多个 `feat/fix` 提交 |
| 6 | `23bfcf2 feat：播放页面背景动态效果` | 全角冒号 | `feat(ui): 播放页背景新增动态效果` |
| 7 | `980155d publish：2.1.0` | 非约定 type + 全角冒号 | `chore(release): v2.1.0` |
| 8 | `7c83a79 remove：移除无效UI按钮` | 非约定 type | `chore(ui): 移除无效按钮` |
| 9 | `bc1d451 Enhance music playback and user interface` | 纯英文且笼统，无可核对范围 | 按模块拆分为 2~3 条 `fix/feat` |
| 10 | `c59ef26`（含 5 个 `feat：`） | 一次提交混 5 件事，无法回滚 | 拆成 5 个提交 |

---

## 12. 约束与坑

| # | 约束/坑 | 事实 |
|---|---|---|
| 1 | 历史 67 条全角冒号、4 条 type 拼写错误 | 不重写历史，仅约束新增 |
| 2 | `buildKey.keystore` 已入库 | 仅改 `.gitignore` 无效，需 `git rm --cached`（TD-31） |
| 3 | 无 CI，提交信息合规靠自检 | 见 §8 |
| 4 | PowerShell 下 `flutter test` 退出码不可信 | 以 stdout 判定 |
| 5 | LFS 生效情况未验证 | 见 §7「待核实」 |
| 6 | `publish` 等历史 type 无对应现代取值 | 已在 §3.1 给出映射 |
| 7 | `.tmp-extract.js` 未跟踪但仍在工作区 | 提交前清理 |

---

## 13. 待办与关联

| 编号 | 待办 | 关联任务 |
|---|---|---|
| — | 落地 `scripts/check.ps1` 提交前门禁 | T-M0-05 |
| — | 引入提交信息校验（`commit-msg` 钩子或 CI 检查） | T-M1-01 |
| — | 编写 `CONTRIBUTING.md`（含本文件摘要） | T-M7-01 |
| — | `buildKey.keystore` 移出仓库并轮换密钥 | T-M5-01 |

关联文档：`docx/08-工程纪律/分支与发布纪律.md`、`docx/08-工程纪律/安全与合规纪律.md`、`docx/08-工程纪律/测试与质量门禁.md`、`docx/09-模板/提交信息模板.md`
