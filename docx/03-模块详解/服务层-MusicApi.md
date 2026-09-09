# 服务层 · MusicApi

> 文档编号：KA-03-02
> 级别：L2 📖
> 状态：现行
> 关联代码：lib/services/music_api.dart（1626 非空行 / 1762 总行，主） + lib/core/api_client.dart、lib/models/music_models.dart、lib/models/app_version.dart、lib/controllers/auth_controller.dart、lib/controllers/player_controller.dart
> 最近更新：2026-09-08
> 变更触发条件：新增/删除后端端点、改动请求参数或返回模型、新增音源（跨平台）、改动登录流程或歌词解析策略时

---

## 1. 一句话结论（TL;DR）

MusicApi 是**唯一把 HTTP 响应翻译成领域模型**的地方：45 个公开方法（另有 1 个 getter）覆盖 39 个 KuGou 端点（`api.json` 共 149 个端点）与 2 个网易云端点，全部方法都是「薄封装 + 兼容解析」，**自身不做任何缓存**。
跨平台搜索只影响搜索列表：网易云结果用 `hash = ne_<id>` 标记来源，播放地址由 `PlayerController` 直接拼 `music.163.com` 外链，**不经过 `songUrl`**，也不参与音量均衡。
所有写操作走 `ApiClient.post`（不可重试），所有读取走 `ApiClient.get`（可重试 2 次）；`api.json` **未声明任何 securitySchemes**，因此「是否需登录」只能按端点语义与调用时机推断，标注为待核实。

---

## 2. 现状

### 2.1 文件构成

| 区段 | 行号 | 内容 |
|---|---|---|
| `MusicApi` 类 | `lib/services/music_api.dart:10-867` | 45 个公开方法 + 1 个 getter（`clientSessionId`）+ 6 个私有辅助 |
| `_orderUserPlaylistsForDisplay` | `lib/services/music_api.dart:869-876` | 顶层函数，用户歌单展示排序 |
| `parseLyrics` | `lib/services/music_api.dart:878-903` | **顶层公开函数**，KRC/LRC 解析入口（被 `player_controller` 与 `test/lyric_metadata_test.dart` 使用） |
| 歌词解析私有实现 | `lib/services/music_api.dart:905-1762` | 元数据行识别、标题卡识别、翻译/音译轨对齐、调试日志 |

### 2.2 依赖与装配

| 项 | 说明 | 锚点 |
|---|---|---|
| 构造 | `MusicApi(this._client)`，只依赖 `ApiClient` | `lib/services/music_api.dart:11` |
| 装配点 | `final api = MusicApi(client);` | `lib/main.dart:31` |
| 注入方式 | 通过构造函数传给各页面与控制器（手动 DI） | `lib/main.dart:91-95` |
| 注册提示常量 | `_registerHint = '若没有账号请先在酷狗音乐概念版App注册'` | `lib/services/music_api.dart:13` |
| 会话出口 | `clientSessionId` 暴露 `ApiClient.sessionId` | `lib/services/music_api.dart:18` |

### 2.3 会话注入（`setSession`，`music_api.dart:20-38`）

| 入参 | 行为 | 锚点 |
|---|---|---|
| `null` | 清空 `token` / `t1` / `sessionId` | `21-25` |
| 非 null | 写 `token`、`t1` | `27-28` |
| `session.sessionId` 非空 | 写 `ApiClient.sessionId` | `34-37` |
| `session.sessionId` 为 `null` 或空 | **不覆盖**，保留 `_processResponse` 从响应头抓到的值 | `29-37` |

> 该「null 不覆盖」是登录态能否续上的关键：扫码登录返回的 `LoginSession` 只有 `token`，`sessionId` 来自登录响应头（`music_api.dart:28-33` 注释、`lib/controllers/auth_controller.dart:295-297`）。

---

## 3. 设计说明

### 3.1 登录链路

| 方法签名 | 端点 | HTTP | 请求参数 | 返回模型 | 需登录 | 缓存/降级 |
|---|---|---|---|---|---|---|
| `Future<void> sendLoginCode(String mobile)` | `/captcha/sent` | POST（query） | `mobile` | 无（`void`） | 否 | 无缓存；`status != 1` 抛 `ApiException('发送验证码失败，…')` |
| `Future<PhoneLoginResult> loginWithPhone({required String mobile, required String code, String? userId})` | `/login/cellphone` | POST（body） | `mobile`、`code`、`userId`（可选，非空才发） | `PhoneLoginResult`（`session` 或 `accounts`） | 否 | 多账号时返回候选列表；成功后 `sessionId` 取 `_client.sessionId` |
| `Future<LoginSession> refreshToken()` | `/login/token` | POST（无参） | 无 | `LoginSession` | **需已持有 token** | 失败由调用方吞掉并沿用旧 token（`auth_controller.dart:223-225`） |
| `Future<void> logout()` | `/login/logout` | POST（无参） | 无 | 无 | 是 | 无 |
| `Future<QrCodeInfo> getQrCode()` | `/login/qr/key` | GET | 无 | `QrCodeInfo`（`key` / `imageUrl`） | 否 | 无 |
| `Future<QrCheckResult> checkQrStatus(String key)` | `/login/qr/check` | GET | `key` | `QrCheckResult` | 否 | 轮询由 UI 负责（2s 间隔，失败退避） |

二维码状态码（`QrCheckResult`，`lib/models/music_models.dart:1749-1753`）：

| status | 含义 | 判定属性 |
|---|---|---|
| 0 | 等待扫码 | `isWaitingForScan` |
| 1 | 已扫码待确认 | `isWaitingForConfirm` |
| 2 | 已过期 | `isExpired` |
| 4 | 登录成功（且 `token` 非空） | `isSuccess` |
| 其它 | 未定义 | 均不成立 |

登录流程差异：

| 流程 | 步骤 | 锚点 |
|---|---|---|
| 验证码登录 | `sendLoginCode` → `loginWithPhone` → `setSession` → `refreshProfile` | `lib/controllers/auth_controller.dart:283-373` |
| 多账号选择 | 后端返回 `errorCode == 34175` 且 `accounts` 非空 → 返回 `accountSelection`，UI 让用户选 `userId` 后重试 | `music_api.dart:582-590`、`lib/ui/pages/login_page.dart:115-119` |
| 扫码登录 | `getQrCode` → 每 2s `checkQrStatus` → 成功后构造 `LoginSession`（无 `t1`）→ `loginWithSession` 内补调 `refreshToken` 取 `t1` | `lib/ui/pages/login_page.dart:220-303`、`lib/controllers/auth_controller.dart:300-326` |
| 会话恢复 | 读 SharedPreferences 的 token/t1/sessionId → `setSession` → `refreshToken` 校验 userId 一致 | `lib/controllers/auth_controller.dart:192-249` |
| 登出 | `logout` → 清空本地会话与歌单缓存 | `lib/controllers/auth_controller.dart:386-409` |

### 3.2 用户与云盘

| 方法签名 | 端点 | HTTP | 请求参数 | 返回模型 | 需登录 | 缓存/降级 |
|---|---|---|---|---|---|---|
| `Future<UserProfile> userDetail()` | `/user/detail` | GET | 无 | `UserProfile` | 是（`api.json` 摘要「获取当前登录用户详情」） | 无缓存；调用方 `AuthController` 用 `CacheService` 缓存 24h（`auth_controller.dart:230-237`、`379`） |
| `Future<List<PlaylistSummary>> userPlaylists({int page = 1, int pageSize = 30})` | `/user/playlist` | GET | `page`、`pagesize` | `List<PlaylistSummary>` | 是（摘要「分页获取当前登录用户歌单」） | 无缓存；过滤 `id` 为空项；展示排序见 `3.9 |
| `Future<CloudDriveResult> cloudDrive({int page = 1, int pageSize = 30})` | `/user/cloud` | GET | `page`、`pagesize` | `CloudDriveResult`（`info` + `songs`） | 是（摘要「获取用户云盘」） | 无缓存；过滤 `hash` 为空 |
| `Future<PlayUrl> cloudSongUrl(Song song)` | `/user/cloud/url` | GET | `hash`、`album_audio_id`、`audio_id`（均取 `albumAudioId`）、`name`（曲名） | `PlayUrl`（仅 `url` + `hash`，**无响度**） | 是 | 无缓存；`url` 为空时返回空串由调用方判错 |

### 3.3 发现与 FM

| 方法签名 | 端点 | HTTP | 请求参数 | 返回模型 | 需登录 | 缓存/降级 |
|---|---|---|---|---|---|---|
| `Future<List<PlaylistSummary>> recommendedPlaylists({int categoryId = 0, int page = 1})` | `/top/playlist` | GET | `category_id`、`page` | `List<PlaylistSummary>`（读 `special_list`） | 待核实 | 无缓存；过滤 `id` 为空 |
| `Future<DailyRecommend> dailyRecommend()` | `/recommend/songs` | GET | 无 | `DailyRecommend` | 待核实 | 无缓存；调用方按 30 分钟 TTL 缓存（`lib/ui/pages/home_page.dart:134`） |
| `Future<List<AlbumShopItem>> albumShop({int page = 1, int pageSize = 30})` | `/album/shop` | GET | `page`、`pagesize` | `List<AlbumShopItem>`（读 `album_list`） | 待核实 | 无缓存；过滤 `mediaId > 0` |
| `Future<List<FmStation>> fmRecommendedStations()` | `/fm/recommend` | GET | 无 | `List<FmStation>` | 待核实 | 无缓存；兼容「裸数组」或 `data` |
| `Future<List<FmClassGroup>> fmClassGroups()` | `/fm/class` | GET | 无 | `List<FmClassGroup>`（读 `class_list` 或 `data`） | 待核实 | 无缓存；`api.json` 警告「返回的 json 特别大，不建议使用」 |
| `Future<List<Song>> fmSongs(FmStation station, {int offset = -1, int size = 20})` | `/fm/songs` | GET | `fmid`、`type`、`offset`、`size` | `List<Song>`（展平 `FmSongPage.songs`） | 待核实 | 无缓存；兼容「裸数组」或 `data` |
| `Future<Map<String, FmImage>> fmImages(List<String> fmids)` | `/fm/image` | GET | `fmid`（去重后逗号连接） | `Map<String, FmImage>`（键为 `fmid`） | 待核实 | 无缓存；空入参直接返回 `{}` |

### 3.4 VIP 与时长

| 方法签名 | 端点 | HTTP | 请求参数 | 返回模型 | 需登录 | 缓存/降级 |
|---|---|---|---|---|---|---|
| `Future<VipReceiveHistory> vipReceiveHistory()` | `/youth/month/vip/record` | GET | 无 | `VipReceiveHistory` | 是 | 无缓存；由 `VipBackgroundTask` 调用（`lib/services/vip_background_task.dart:43`） |
| `Future<OneDayVipResult> dailyVip()` | `/youth/day/vip` | GET | 无 | `OneDayVipResult` | 是 | 无缓存；**写操作但用 GET**，超时会重试（见 `4.1 MA-03） |
| `Future<UpgradeVipResult> upgradeVipReward()` | `/youth/day/vip/upgrade` | GET | 无 | `UpgradeVipResult` | 是 | 无缓存；同上 |
| `Future<void> addListeningTime()` | `/listen/timeadd` | POST | 无 | 无 | 是 | 无缓存；POST 故不重试（`lib/controllers/player_controller.dart:2688`） |

### 3.5 搜索

| 方法签名 | 端点 | HTTP | 请求参数 | 返回模型 | 需登录 | 缓存/降级 |
|---|---|---|---|---|---|---|
| `Future<List<SearchHotCategory>> searchHotKeywords()` | `/search/hot` | GET | 无 | `List<SearchHotCategory>`（读 `list`） | 待核实 | 无缓存；UI 仅在进入搜索页时拉一次（`lib/ui/pages/search_page.dart:71-85`） |
| `Future<List<String>> searchSuggest(String keywords)` | `/search/suggest` | GET | `keywords` | `List<String>`（读 `music[].keyword`） | 待核实 | 无缓存；UI 300ms 防抖（`search_page.dart:104-106`） |
| `Future<List<Song>> searchSongs(String keywords, {int page = 1, int pageSize = 30})` | `/search` | GET | `keywords`、`page`、`pagesize`、`type=song` | `List<Song>` | 待核实 | 无缓存；兼容「裸数组」或 `songs` / `song` / `lists` |
| `Future<List<Song>> searchNetEaseSongs(String keywords, {int limit = 30, int offset = 0})` | 网易云 `/search` + `/song/detail` | GET（`getRaw`） | 第一步 `keywords`、`limit`、`offset`、`type=1`；第二步 `ids`（逗号连接） | `List<Song>`（`SongSource.netease`） | 否 | 无缓存；两步调用，第一步无结果直接返回 `[]` |

### 3.6 曲目、播放地址与歌词

| 方法签名 | 端点 | HTTP | 请求参数 | 返回模型 | 需登录 | 缓存/降级 |
|---|---|---|---|---|---|---|
| `Future<PlayUrl> songUrl(Song song, {AudioQuality quality = AudioQuality.standard})` | `/song/url` | GET | `hash`、`quality`、`album_id`、`album_audio_id`、`free_part=false` | `PlayUrl`（`url` 取数组首项 + `loudness`） | 待核实 | 无缓存、无降级；降级在调用方 `PlayerController._loadNetworkSourceWithFallback`（`player_controller.dart:818-909`） |
| `Future<List<LyricLine>> lyrics(Song song, {bool Function()? isCancelled})` | `/search/lyric` + `/lyric` | GET | 见下 | `List<LyricLine>` | 待核实 | 多候选取「解析行数最多」；最多 8 个候选 × 2 种格式 |
| `Future<List<LyricCandidate>> searchLyricCandidates(Song song)` | `/search/lyric` | GET | `hash`、`album_audio_id`、`keywords`、`keyword`（均 `"曲名 歌手"`）、`duration`、`man=yes` | `List<LyricCandidate>`（按 `id:accessKey` 去重） | 待核实 | 递归收集 + 多字段兜底（`candidates`/`candidate`/`list`/`lyrics`/`items`/`info`/`data`） |
| `Future<List<LyricLine>> lyricsFromCandidate(LyricCandidate candidate)` | `/lyric` | GET | `id`、`accesskey`、`fmt`、`decode=true` | `List<LyricLine>` | 待核实 | 先 `krc` 后 `lrc`（`music_api.dart:797-801`） |

歌词请求参数细节（`_lyricByFormat`，`music_api.dart:803-866`）：

| 参数 | 取值 |
|---|---|
| `id` | 依次取 `id` / `lyrics_id` / `lyric_id` / `lyricid` |
| `accesskey` | 依次取 `accesskey` / `access_key` / `accessKey` |
| `fmt` | `krc` 或 `lrc` |
| `decode` | `true`（要求后端解码） |

歌词内容候选与打分（`music_api.dart:830-866`、`1087-1108`）：

| 候选字段 | 优先级 |
|---|---|
| `decodedContent` | 参与打分 |
| `rawContent` | 参与打分 |
| `content` | 参与打分 |
| 打分规则 | KRC 带词级时间戳 +100；KRC 行头 +60；LRC 时间戳 +40；含 `[language:` +10 |
| 并列时 | 取字符串更长的 |

### 3.7 歌单

| 方法签名 | 端点 | HTTP | 请求参数 | 返回模型 | 需登录 | 缓存/降级 |
|---|---|---|---|---|---|---|
| `Future<PlaylistSummary> playlistInfo(String id)` | `/playlist/detail` | GET | `ids=id` | `PlaylistSummary` | 待核实 | 无缓存；调用方按 24h TTL 缓存（`playlist_detail_page.dart:315`） |
| `Future<SongPage> playlistSongPage(String id, {int page = 1, int pageSize = 80})` | `/playlist/track/all` | GET | `id`、`page`、`pagesize` | `SongPage`（`songs` + `rawItemCount`） | 待核实 | 无缓存；过滤 `hash` 为空 |
| `Future<List<Song>> playlistSongs(String id, {int page = 1, int pageSize = 80, bool fetchAll = false, bool Function()? shouldCancel})` | `/playlist/track/all` | GET | 同上；`fetchAll=true` 时固定 `perPage = 200` 循环翻页 | `List<Song>` | 待核实 | 无缓存；无最大页数上限，靠 `shouldCancel` 中断；页内返回数 < 200 时停止 |
| `Future<void> createPlaylist(String name, {bool private = false})` | `/playlist/create` | POST | `name`、`type`（`private ? 1 : 0`） | 无 | 是 | 无缓存；调用方重建歌单列表（`auth_controller.dart:132-139`） |
| `Future<void> collectPlaylist({required String name, required String globalCollectionId})` | `/playlist/add` | POST | `name`、`list_create_gid` | 无 | 是 | 无缓存 |
| `Future<void> deletePlaylist(String listId)` | `/playlist/del` | POST | `listid` | 无 | 是 | 无缓存；创建/收藏的歌单同用此接口（`auth_controller.dart:151-160`） |
| `Future<void> addToPlaylist(String listId, Song song)` | `/playlist/tracks/add` | POST | 见下 | 无 | 是 | 无缓存；委托 `addSongsToPlaylist` |
| `Future<void> addSongsToPlaylist(String listId, List<Song> songs)` | `/playlist/tracks/add` | POST（body） | `listId`、`songs[]`（每项 `name` / `hash` / `albumId` / `mixSongId`） | 无 | 是 | 空列表直接返回不发请求 |
| `Future<void> removeFromPlaylist(String listId, Song song)` | `/playlist/tracks/del` | POST | `listid`、`fileids` | 无 | 是 | 无缓存；委托 `removeSongsFromPlaylist` |
| `Future<void> removeSongsFromPlaylist(String listId, List<Song> songs)` | `/playlist/tracks/del` | POST（query） | `listid`、`fileids` = 各 `song.id` 逗号连接 | 无 | 是 | `fileids` 为空则跳过 |

> 歌单「导入」不调任何导入接口：`PlaylistDetailPage.importPlaylistById` 只是 `playlistInfo(id)` + 打开详情页（`lib/ui/pages/playlist_detail_page.dart:781-802`）。

### 3.8 歌手、专辑、评论与版本

| 方法签名 | 端点 | HTTP | 请求参数 | 返回模型 | 需登录 | 缓存/降级 |
|---|---|---|---|---|---|---|
| `Future<ArtistDetail> artistDetail(String id)` | `/artist/detail` | GET | `id` | `ArtistDetail` | 待核实 | 无缓存 |
| `Future<List<Song>> artistAudios(String id, {int page = 1, int pageSize = 30, String sort = 'hot'})` | `/artist/audios` | GET | `id`、`page`、`pagesize`、`sort` | `List<Song>` | 待核实 | 无缓存；兼容 `data`/`songs`/`song`/`list`/`info` + `_firstListValue` 递归兜底 |
| `Future<SongPage> albumSongPage(String id, {int page = 1, int pageSize = 30})` | `/album/songs` | GET | `id`、`page`、`pagesize` | `SongPage` | 待核实 | 无缓存；兼容 `songs`/`data`/`info` + 递归兜底 |
| `Future<MusicCommentResponse> musicComments(String mixsongid, {int page = 1, int pageSize = 30})` | `/comment/music` | GET | `mixsongid`、`page`、`pagesize` | `MusicCommentResponse` | 待核实 | 无缓存 |
| `Future<AppVersionInfo> latestAppVersion(AppUpdatePlatform platform)` | `/mobile/app/versions/latest` | GET | `platform`（`android`/`ios`/`hm`） | `AppVersionInfo` | 否 | 无缓存；版本比较见 `lib/models/app_version.dart:35-38` |

### 3.9 响应兼容与兜底策略汇总

| 策略 | 触发条件 | 锚点 |
|---|---|---|
| 成功判定 | 仅 `status == 1` 视为成功 | `music_api.dart:578-580` |
| 多账号判定 | `requiresUserSelection == true` 或 `errorCode == 34175` 且有 `accounts` | `music_api.dart:582-590` |
| 错误文案拼接 | 依次取 `msg` / `message` / `errmsg` / `error` / `error_msg`，否则取 `error_code` / `errcode` / `code` | `music_api.dart:592-612` |
| 裸数组 / `data` 双形态 | `fm/recommend`、`fm/songs`、`fm/image`、`search` | `223-224`、`253`、`270`、`656-661` |
| 未知字段名列表 | `artist/audios`、`album/songs` 依次探测 `data`/`songs`/`song`/`list`/`info`，再递归找第一个数组 | `329-338`、`357-364`、`373-386` |
| 用户歌单展示排序 | 前 2 条保持原序，第 3 条起整体反转 | `869-876` |
| 歌词候选去重 | 键 `"<id>:<accessKey>"` | `790-794` |
| 歌词格式降级 | `krc` 无内容则取 `lrc` | `797-801` |
| 歌词行数最优 | 候选中取解析行数最多的 | `741-749` |

### 3.10 跨平台搜索差异与音源切换

| 维度 | 酷狗（默认） | 网易云 |
|---|---|---|
| 入口方法 | `searchSongs` | `searchNetEaseSongs` |
| 请求路径 | `AppConfig.effectiveBaseUrl/search` | `https://wyy.music.api.hoilai.cn/search` + `/song/detail` |
| 客户端 | `ApiClient.get`（带鉴权头） | `ApiClient.getRaw`（**不带任何鉴权头**） |
| 请求次数 | 1 次 | 2 次（先取 id 列表，再批量取详情） |
| 分页参数 | `page` / `pagesize` | `limit` / `offset` |
| `Song.hash` | 后端返回的酷狗 hash | `'ne_<id>'`（`lib/models/music_models.dart:2000`） |
| `Song.source` | `SongSource.kugou` | `SongSource.netease` |
| 播放地址 | `MusicApi.songUrl`（`/song/url`） | 不走 API：`https://music.163.com/song/media/outer/url?id=<id>.mp3`（`lib/controllers/player_controller.dart:861-866`、`1253-1254`、`1864-1868`） |
| 响度/音量均衡 | 有 `volume` 数据 | 无（`_hydrateLocalLoudnessOnce` 直接 return，`player_controller.dart:790-792`） |
| 收藏/歌单写入 | 支持 | 不支持（UI 隐藏操作，`lib/ui/pages/search_page.dart:833`） |
| 歌手页 | 支持 | 不支持（`search_page.dart:171-174` 提示「其他平台歌曲暂不支持查看歌手」） |
| 评论/歌词 | 支持 | 歌词不支持（`player_page.dart:569` 判定非酷狗源） |

音源切换逻辑（`lib/ui/pages/search_page.dart`）：

| 项 | 事实 | 锚点 |
|---|---|---|
| 平台枚举 | `enum _SearchPlatform { kugou, netease }` | `35` |
| 默认平台 | `_platform = _SearchPlatform.kugou` | `48` |
| 切换行为 | 若已搜索过则用当前关键词自动重搜 | `156-164` |
| 搜索分发 | `_platform == netease ? searchNetEaseSongs : searchSongs` | `127-129` |
| 结果标记 | 非酷狗源显示「网易云」/「外部」徽标 | `996-999` |
| 热词/建议 | 始终走酷狗端点，与平台选择无关 | `73`、`111` |
| 搜索历史 | `SearchHistoryService` 本地存储，两平台共用 | `89`、`132` |

### 3.11 谁在缓存 MusicApi 的结果

MusicApi **不含任何缓存**；SWR 与 TTL 由调用方通过 `CacheService` 实现：

| 数据 | 缓存位置 | TTL | 锚点 |
|---|---|---|---|
| 每日推荐 / 首页 | `home_page` | `homeCacheTtl = 30 分钟` | `lib/ui/pages/home_page.dart:134`、`lib/config/app_config.dart:31` |
| 歌单/专辑详情 | `playlist_detail_page` | `playlistDetailTtl = 24 小时` | `lib/ui/pages/playlist_detail_page.dart:315`、`438`、`lib/config/app_config.dart:32` |
| 用户信息 + 歌单列表 | `AuthController` | `userProfileTtl = 24 小时` | `lib/controllers/auth_controller.dart:233`、`476`、`lib/config/app_config.dart:33` |
| 歌词 | `PlayerController._fetchLyrics` | 数据缓存键 `cache_lyric_v9_<key>`，`ttl: null`（不过期）；本地音乐优先读同名 `.lrc` 文件 | `lib/controllers/player_controller.dart:1601-1614`、`1595-1599` |
| 搜索历史 | `SearchHistoryService` | 无 TTL（本地列表） | `lib/services/search_history_service.dart` |

---

## 4. 约束与坑

| 编号 | 问题 | 锚点 | 影响 |
|---|---|---|---|
| MA-01 | `api.json` 未声明 `securitySchemes`，「需登录」只能按摘要语义推断 | `api.json`（无 `securitySchemes` 节点） | 表中「待核实」项需实测确认，否则文档会误导 |
| MA-02 | 全部 POST 走 `allowRetry = false`，网络抖动即失败，用户需手动重试 | `lib/core/api_client.dart:45` | 弱网下歌单增删、发验证码体验差 |
| MA-03 | 领取类写操作用 GET（`/youth/day/vip`、`/youth/day/vip/upgrade`），超时会被重试 2 次 | `lib/services/music_api.dart:287`、`292` | 是否幂等**待核实** |
| MA-04 | `playlistSongs(fetchAll: true)` 无最大页数上限，仅靠 `shouldCancel` 与「返回数 < 200」终止 | `music_api.dart:424-441` | 超大歌单会持续翻页；默认 `pageSize = 80` 与 `fetchAll` 的 200 不一致，易误读 |
| MA-05 | `_firstListValue` 递归找「第一个数组」，字段全未知时可能取到非歌曲列表 | `music_api.dart:373-386` | 解析出空列表而非报错，问题被静默吞掉 |
| MA-06 | `lyrics` 最坏发起 1 + 8 × 2 = 17 次请求 | `music_api.dart:740-748`、`797-801` | 首屏歌词延迟；切歌依赖 `isCancelled` 才能提前退出 |
| MA-07 | `searchLyricCandidates` 对整个响应递归收集，无深度/规模上限 | `music_api.dart:773-789` | 异常响应可能放大内存与解析耗时 |
| MA-08 | `songUrl` 无条件 `debugPrint`（未受 `kDebugMode` 保护） | `music_api.dart:479` | Release 日志污染 |
| MA-09 | 网易云不参与音量均衡、收藏、歌手页、歌词 | `player_controller.dart:790-792`、`search_page.dart:833`、`171-174` | 跨源歌曲功能不对等，UI 需持续判定 `song.source` |
| MA-10 | 网易云播放地址硬编码在 `PlayerController`，绕过 `MusicApi` | `player_controller.dart:863` | 音源扩展逻辑分散在两处 |
| MA-11 | `userPlaylists` 的展示排序（前 2 条 + 其余反转）是硬编码 hack | `music_api.dart:869-876` | 后端顺序变化时表现不可预期 |
| MA-12 | 仅覆盖 39/149 个 KuGou 端点 | `api.json` vs `music_api.dart` | 未接入端点需在 `../04-数据与接口/API-端点清单.md` 中标注 |
| MA-13 | `playlistInfo` 传参名为 `ids` 但只传单个 id | `music_api.dart:404` | 与 OpenAPI 语义（复数）不一致，易误用 |
| MA-14 | `removeSongsFromPlaylist` 用 `song.id` 作为 `fileids`，与添加时用的 `mixSongId` 不同源 | `music_api.dart:558-566`、`569-576` | 若 `id` 非酷狗 fileid，删除会静默无效（待核实） |
| MA-15 | `setSession(null)` 会清空 `sessionId`，但 `AuthController.login` 在登录前就调用它 | `music_api.dart:20-25`、`lib/controllers/auth_controller.dart:349` | 登录前旧会话被清除（符合预期，但意味着并发登录请求会互相影响） |

---

## 5. 待办与关联

| 关联文档 | 关系 |
|---|---|
| `../03-模块详解/核心层-ApiClient.md` | 传输层行为（重试/超时/请求头） |
| `../03-模块详解/服务层-下载服务.md` | `songUrl` 的消费者（下载与播放缓存） |
| `../03-模块详解/控制器层-PlayerController.md` | 音质降级、预解析、歌词加载 |
| `../03-模块详解/控制器层-AuthController.md` | 会话注入与登录编排 |
| `../04-数据与接口/API-端点清单.md` | 端点全量清单（本文件只用了 39 个） |
| `../04-数据与接口/数据模型参考.md` | 返回模型字段定义 |
| `../06-质量保障/已知问题与技术债台账.md` | MA-01~MA-15 应登记 |

待办（候选）：

| 编号 | 事项 | 依据 |
|---|---|---|
| T-MA-1 | 用真实账号实测「待核实」的登录要求，回填表格 | MA-01 |
| T-MA-2 | 把领取类接口从 GET 改为 POST，或给 `get` 增加 `allowRetry` 开关 | MA-03 |
| T-MA-3 | 把网易云播放地址解析收敛进 `MusicApi`（新增 `netEaseSongUrl`） | MA-10 |
| T-MA-4 | 为 `playlistSongs(fetchAll)` 增加页数上限与进度回调 | MA-04 |
| T-MA-5 | 为 `MusicApi` 补单测（当前 `test/` 下无 `MusicApi` 用例） | `test/` 目录 |
