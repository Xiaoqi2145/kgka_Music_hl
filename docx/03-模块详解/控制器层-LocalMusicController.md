# 控制器层 · LocalMusicController

> 文档编号：KA-03-13
> 级别：L2 📖
> 状态：现行
> 关联代码：lib/controllers/local_music_controller.dart（105 行，主） + lib/ui/pages/local_songs_page.dart + lib/ui/pages/settings_page.dart + lib/ui/pages/library_page.dart + lib/controllers/player_controller.dart + lib/models/music_models.dart + lib/main.dart
> 最近更新：2026-09-09
> 变更触发条件：改动扫描目录规则、增删支持的文件类型、改动文件名解析规则、改动 settings.local_music_dir 键、把元数据读取从文件名切换到标签库时

---

## 1. 一句话结论（TL;DR）

`LocalMusicController` 只做三件事：记住一个目录（`settings.local_music_dir`）、**递归扫描该目录下的 5 种音频扩展名**、把每个文件包装成一个 `Song`（`id` 与 `hash` 都是**文件绝对路径**）。它**不读 ID3/FLAC 标签**——标题与歌手全部由文件名按 `"歌手 - 歌名"` 规则推断；歌词由 `PlayerController` 在播放时按同名 `.lrc` 侧车文件读取，控制器本身不参与。

---

## 2. 现状

### 2.1 基本信息

| 项 | 值 | 锚点 |
|---|---|---|
| 文件 | `lib/controllers/local_music_controller.dart` | — |
| 行数 | 105 行（口径：PowerShell `Measure-Object -Line`，约等于非空行；文件总行数含空行为 120） | — |
| 基类 | `ChangeNotifier` | `local_music_controller.dart:6` |
| 构造 | `LocalMusicController()`，构造体内**未 await** 地调用 `_loadSettings()` | :7-9 |
| 装配点 | `_localMusic = LocalMusicController()` | `main.dart:93` |
| 释放 | `_localMusic.dispose()` | `main.dart:112` |
| 传递链 | `AppShell.localMusic` → `LibraryPage.localMusic` → `SettingsPage.localMusic` / `LocalSongsPage.localMusic` | `app_shell.dart:37`、`library_page.dart:35` |

### 2.2 状态字段

| 字段 | 类型 | 初值 | Getter | 语义 | 锚点 |
|---|---|---|---|---|---|
| `_localMusicDir` | `String?` | `null` | `localMusicDir` | 已配置的扫描根目录绝对路径 | :13、:17 |
| `_songs` | `List<Song>` | `[]` | `songs` | 扫描结果（内存态，不持久化） | :14、:18 |
| `_isScanning` | `bool` | `false` | `isScanning` | 扫描中标志，驱动 UI 进度圈 | :15、:19 |

### 2.3 持久化键

| 键 | 常量 | 类型 | 默认 | 清除 | 锚点 |
|---|---|---|---|---|---|
| `settings.local_music_dir` | `_localMusicDirKey` | `String`（目录绝对路径） | 键不存在 → `localMusicDir == null` | `setLocalMusicDir(null)` 或空串时 `prefs.remove` | :11、:23、:32-37 |

---

## 3. 设计说明

### 3.1 目录选择与设置

| 入口 | 调用 | 说明 | 锚点 |
|---|---|---|---|
| 设置页「本地音乐目录」 | `_selectOrClearDir` → `FilePicker.getDirectoryPath()` → `setLocalMusicDir(path)` | 已有目录时先弹 BottomSheet 选「选择新目录 / 清除目录」 | `settings_page.dart:257-263`、:472-549 |
| 本地音乐页右上角文件夹按钮 | 同上逻辑（`local_songs_page.dart:47-112`） | 逻辑与设置页重复实现 | `local_songs_page.dart:47-112` |
| 清除目录 | `setLocalMusicDir(null)` → `Toast.success('已清除本地目录')` | 清键 + 清空 `_songs` | `settings_page.dart:530-533`、`local_songs_page.dart:96-99` |

`setLocalMusicDir(String? dirPath)`（`local_music_controller.dart:29-40`）的行为：

| 输入 | 行为 | 锚点 |
|---|---|---|
| `null` 或空白串 | `prefs.remove` + `_songs = []` + `notifyListeners()`（**不触发扫描**） | :35-39 |
| 非空路径 | `prefs.setString` + `await scanLocalMusic()`（**立即全量扫描**） | :32-34 |

入参先做 `dirPath?.trim()`（:30）。**不做路径存在性校验**，不存在的路径交给扫描阶段处理。

### 3.2 扫描策略

`scanLocalMusic()`（`local_music_controller.dart:42-62`）：

| 步 | 动作 | 细节 | 锚点 |
|---|---|---|---|
| 1 | 前置校验 | 目录为 null 或空串直接 `return`（不改变 `_isScanning`） | :43-44 |
| 2 | 置扫描态 | `_isScanning = true` + `notifyListeners()` | :46-47 |
| 3 | 构造结果容器 | `final List<Song> list = []`（局部变量，扫描结束才整体替换） | :49 |
| 4 | 目录存在性 | `Directory(dirPath).exists()` 为 false 时跳过扫描 | :51-54 |
| 5 | 递归收集 | `_scanDirectory(dir, list)` | :53 |
| 6 | 异常兜底 | 捕获后 `debugPrint('Error scanning local music: $e')`，已收集的部分仍会保留 | :55-57 |
| 7 | 收尾 | `_songs = list`、`_isScanning = false` + `notifyListeners()` | :59-61 |

`_scanDirectory(Directory dir, List<Song> list)`（:64-119）：

| 项 | 实现 | 锚点 |
|---|---|---|
| 遍历方式 | `dir.list(recursive: false, followLinks: false)`，**手动递归**子目录 | :66、:75 |
| 符号链接 | `followLinks: false`，不跟随 | :66 |
| 子目录名提取 | 优先 `entity.uri.pathSegments`（处理目录 URI 末尾空段），回退 `path.split(Platform.isWindows ? '\\' : '/')` | :69-73 |
| 跳过规则 | 名称以 `.` 开头（隐藏目录）或以 `$` 开头（如 `$RECYCLE.BIN`） | :74 |
| 单目录异常 | 整个 `await for` 包在 `try/catch` 中，出错 `debugPrint('Skipping directory ${dir.path} due to error: $e')` 并放弃该目录剩余条目 | :65、:115-118 |

### 3.3 文件类型过滤

判定方式：取 `entity.path.toLowerCase()` 后做 `endsWith` 后缀匹配（`local_music_controller.dart:78-83`）：

| 序 | 扩展名 | 说明 | 锚点 |
|---|---|---|---|
| 1 | `.mp3` | MPEG-1/2 Layer III | :79 |
| 2 | `.m4a` | MPEG-4 Audio（AAC） | :80 |
| 3 | `.flac` | FLAC 无损 | :81 |
| 4 | `.wav` | 未压缩 PCM | :82 |
| 5 | `.ogg` | Ogg Vorbis | :83 |

**不在列表中的常见格式（有意/未支持）**：`.aac`、`.opus`、`.ape`、`.wma`、`.m4b`、`.aiff`、`.wv`。过滤大小写不敏感（先 `toLowerCase()`），但仅匹配后缀，不校验文件头——**改扩展名的文件也会被收录**。

### 3.4 元数据读取（文件名解析）

不读取任何音频标签，仅从文件名推断（`local_music_controller.dart:85-101`）：

| 步 | 规则 | 锚点 |
|---|---|---|
| 1 | 取文件名：优先 `entity.uri.pathSegments.last`，回退按平台分隔符切分 | :86-88 |
| 2 | 去扩展名：`lastIndexOf('.')`，找不到则用原名 | :89-90 |
| 3 | 默认 `title` = 去扩展名后的文件名 | :92 |
| 4 | 默认 `artist` = 字符串 `'本地音乐'` | :93 |
| 5 | 若文件名含 `' - '`（空格-连字符-空格）：`parts[0].trim()` 作 `artist`，`parts.sublist(1).join(' - ').trim()` 作 `title` | :95-101 |

`Song` 字段填充（:103-111）：

| Song 字段 | 取值 | 说明 |
|---|---|---|
| `id` | 文件绝对路径 | 注释明确「use file path as song ID」 |
| `hash` | 文件绝对路径 | 与 `id` 相同，因此**不能用 hash 判断「是否同一首歌的另一次扫描」以外的语义** |
| `title` | 文件名解析结果 | — |
| `artist` | 文件名解析结果或 `'本地音乐'` | — |
| `coverUrl` | `null` | UI 走 `Artwork` 的渐变占位（`artwork.dart:62-73`） |
| `duration` | `null` | 不解析时长 |
| `source` | `SongSource.local` | 枚举定义见 `music_models.dart:415-424` |

### 3.5 歌词文件匹配

`LocalMusicController` **完全不处理歌词**。歌词在播放链路中按侧车文件读取（`player_controller.dart:1591-1600`）：

| 项 | 规则 | 锚点 |
|---|---|---|
| 触发条件 | `song.source == SongSource.local` | `player_controller.dart:1592` |
| 定位方式 | 取 `song.id` 最后一个 `.` 之前的部分 + `.lrc` | :1593-1595 |
| 缺失处理 | `file.exists()` 为 false 时返回 `const []`（无歌词） | :1596 |
| 编码 | `utf8.decode(await file.readAsBytes(), allowMalformed: true)` | :1598 |
| 解析 | `parseLyrics(...)` | :1597 |

因此约束是：**`.lrc` 必须与音频文件同目录、同主文件名**（`歌曲.mp3` → `歌曲.lrc`），且**不支持 GBK 编码的歌词**（`allowMalformed` 会产出替换字符而非正确解码）。

### 3.6 与 `PlayerController` 的接入方式

| 环节 | 实现 | 锚点 |
|---|---|---|
| UI 触发播放 | `widget.player.playSong(song, queue: filteredSongs)`，队列为**当前检索过滤后的列表** | `local_songs_page.dart:330-332` |
| 音源解析 | `PlayerController` 优先查下载/播放缓存（`downloadController?.localSourceFor`），未命中且 `song.source == SongSource.local` 时直接把 `song.id`（文件路径）当播放地址 | `player_controller.dart:612-636`、:1853-1859 |
| 预加载路径 | 同一分支逻辑（`_prepareNextSource` 等）复用 `song.id` | `player_controller.dart:1858-1859` |
| 本地源加载失败 | `if (song.source == SongSource.local) rethrow;`——本地文件不可播时**直接抛错**，不回退网络（网络源才有降级逻辑） | `player_controller.dart:620` |
| 音量均衡 | `_hydrateLocalLoudnessOnce` 对 `SongSource.local` 直接 `return`——本地曲目**不做 LUFS 归一化** | `player_controller.dart:790-792` |
| 播放统计/历史 | 走通用播放链路，与音源类型无关（`player_controller.dart` 通用逻辑） | 待核实具体落盘时机 |

### 3.7 权限要求

| 项 | 现状 | 锚点 |
|---|---|---|
| 目录选择 | `file_picker` 的 `FilePicker.getDirectoryPath()`，不请求运行时权限 | `local_songs_page.dart:104`、`settings_page.dart:541` |
| Android 声明权限 | `AndroidManifest.xml` 仅声明 INTERNET、WAKE_LOCK、MODIFY_AUDIO_SETTINGS、FOREGROUND_SERVICE、FOREGROUND_SERVICE_MEDIA_PLAYBACK、REQUEST_INSTALL_PACKAGES、SYSTEM_ALERT_WINDOW、FOREGROUND_SERVICE_SPECIAL_USE——**没有 `READ_MEDIA_AUDIO` / `READ_EXTERNAL_STORAGE` / `MANAGE_EXTERNAL_STORAGE`** | `android/app/src/main/AndroidManifest.xml:3-10` |
| 结论 | 目录选择依赖系统文件选择器的授权；扫描阶段用 `dart:io Directory.list` 直接读路径，**在 Android 上是否总能读到所选目录，待核实**（可能受分区存储限制） | — |
| 其他平台 | 无权限模型限制（桌面/Windows 直接读路径）；`file_picker` 构建告警见 `KA-Music-项目状态.md` §4.3 | — |

### 3.8 UI 层行为（`LocalSongsPage`）

| 区域 | 行为 | 锚点 |
|---|---|---|
| 未配置目录 | 空态卡片：图标 + 「未设置本地音乐目录」+ 说明文案 + 「设置目录」按钮 | `local_songs_page.dart:159-196` |
| 路径卡片 | 显示完整路径（单行省略）+ 「共 N 首」 | :208-244 |
| 检索框 | 监听 `TextEditingController`，`toLowerCase()` 后对 `title` 与 `artist` 做 `contains` 匹配（**不匹配专辑，因为本地曲目无专辑字段**） | :199-203、:246-266 |
| 列表 | `ListView.builder`，`padding: EdgeInsets.only(bottom: 120)`，当前播放项高亮 + `NowPlayingBadge` | :280-335 |
| 扫描中 | 列表区显示 `CircularProgressIndicator`；AppBar 的刷新按钮替换为 20x20 进度圈 | :269-272、:127-151 |
| 空态 | 无文件显示「目录下没有找到可播放的音频文件」，检索无结果显示「没有检索到匹配的歌曲」 | :273-279 |
| 重新扫描 | 目录非空时可用，完成后 `Toast.success('扫描完成')` | :140-149 |
| 库页入口 | 「本地」快捷卡，副标题显示 `${localMusic.songs.length} 首歌曲` | `library_page.dart:361-379` |
| 设置页入口 | 「本地音乐目录」条目，副标题为路径或「未设置」 | `settings_page.dart:257-263` |

---

## 4. 约束与坑

1. **每次冷启动都会全量重扫。** `_loadSettings()` 在构造时读到非空目录就 `await scanLocalMusic()`（:24-26），而 `_songs` 只在内存中，从不持久化——配置了目录的用户每次启动都要等一次完整目录遍历。
2. **无增量扫描、无缓存、无隔离线程。** `_scanDirectory` 在 UI isolate 上 `await for` 逐条处理（:66），大目录（万级文件）会占用主 isolate 并可能造成掉帧。
3. **不读音频标签。** `title`/`artist` 完全来自文件名（§3.4）。含 `" - "` 之外分隔习惯的文件（如 `歌名_歌手.mp3`、`01. 歌名.mp3`）会整体落入 `title`，`artist` 固定为 `'本地音乐'`。
4. **`hash` == 文件路径。** 文件移动/重命名后 `hash` 变化，会导致「我喜欢」判断、播放统计、队列去重等按 hash 索引的功能把同一首歌当作新歌。
5. **不解析时长。** `duration` 恒为 `null`，播放前 UI 无法显示时长。
6. **不支持内嵌歌词与 GBK 歌词。** 仅读同名 `.lrc` 侧车文件（§3.5）。
7. **本地曲目无音量均衡。** `_hydrateLocalLoudnessOnce` 对 local 直接返回（`player_controller.dart:790`），且「为纯本地文件做离线 LUFS 计算」在项目状态中明确列为未实现（`KA-Music-项目状态.md` §4.4）。
8. **本地源失败不降级。** `song.source == SongSource.local` 时 `rethrow`（`player_controller.dart:620`），文件被删/损坏会直接报错，而网络源会尝试降级。
9. **目录配置无校验。** `setLocalMusicDir` 不检查路径是否存在或是否可读（:29-40）；不存在的路径表现为「扫描后 0 首」，与「目录为空」不可区分。
10. **扫描错误被静默吞掉。** 只有 `debugPrint`（:56、:117），用户看到的是「没有找到可播放的音频文件」而不是权限/IO 错误。
11. **两处目录选择逻辑重复实现。** `settings_page.dart:472-549` 与 `local_songs_page.dart:47-112` 是近乎相同的代码，改一处容易漏另一处。
12. **文件名解析对多 `" - "` 的处理**：`parts.sublist(1).join(' - ')`（:99）会把后续段落重新拼回标题，因此 `A - B - C.mp3` → `artist = A`、`title = B - C`。
13. **重复扫描不去重。** `_songs` 每次整体替换，同一文件若被多个路径引用（如符号链接目录，虽然 `followLinks: false` 已限制）不会产生重复，但**没有按路径去重的显式逻辑**。

---

## 5. 待办与关联

### 5.1 待办

| 项 | 说明 | 优先级 |
|---|---|---|
| 扫描结果持久化 | 把 `_songs` 写入 `CacheService` 或独立索引文件，冷启动先出结果再增量校验 mtime | 高 |
| 增量扫描 | 按目录 mtime / 文件 mtime 比对，只处理变化项 | 高 |
| 元数据读取 | 引入标签解析（如 `audio_metadata_reader` / `just_audio` 的标签能力，待评估）替代文件名启发式 | 中 |
| 本地 LUFS 计算 | 与音量均衡联动，见 `KA-Music-项目状态.md` §4.4 | 中 |
| 扫描隔离 | 把目录遍历放到 `Isolate.run`，通过 `SendPort` 回传分批结果 | 中 |
| 目录选择去重 | 抽出公共函数供设置页与本地音乐页共用 | 低 |
| 扩展名白名单外置 | 把 5 种后缀抽成常量表，便于后续扩展 `.opus` / `.aac` | 低 |
| 错误可见化 | 扫描异常时在 UI 上给出提示，而非仅 `debugPrint` | 低 |

### 5.2 关联文档

- 播放链路如何消费 `SongSource.local`：`控制器层-PlayerController.md`
- 本地音乐页与设置页在 UI 清单中的位置：`UI层-页面与组件清单.md`
- `settings.local_music_dir` 在持久化键总表中的登记：`../04-数据与接口/本地存储与配置项清单.md`
- `Song` 模型字段定义：`../04-数据与接口/数据模型参考.md`
- 文件选择与构建告警：`../05-平台与原生/`
