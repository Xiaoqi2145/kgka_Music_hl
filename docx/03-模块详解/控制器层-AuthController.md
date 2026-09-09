# 控制器层 · AuthController

> 文档编号：KA-03-10
> 级别：L2 📖
> 状态：现行
> 关联代码：lib/controllers/auth_controller.dart（516 行，主） + lib/ui/pages/login_page.dart（1177 行） + lib/services/music_api.dart + lib/core/api_client.dart + lib/services/cache_service.dart + lib/services/vip_background_task.dart + lib/models/music_models.dart + lib/main.dart
> 最近更新：2026-09-09
> 变更触发条件：新增或修改登录方式、改动 session 持久化键、改动登录态字段或登出清理范围、改动 CacheService 用户缓存键前缀、改动二维码轮询策略时

---

## 1. 一句话结论（TL;DR）

`AuthController` 是全局登录态的唯一持有者，用 **4 个 SharedPreferences 键**（`ka_music_token` / `ka_music_t1` / `ka_music_session_id` / `ka_music_user_id`）承载登录凭据，通过 `restore()` 实现「先读本地缓存立即渲染、再后台静默刷新」；支持手机号验证码与扫码两种登录入口，**没有定时 token 刷新机制**——`refreshToken()` 仅在 `restore()`、`refreshSession()`、`loginWithSession()` 三处被调用。

---

## 2. 现状

### 2.1 基本信息

| 项 | 值 | 锚点 |
|---|---|---|
| 文件 | `lib/controllers/auth_controller.dart` | — |
| 行数 | 516 行（口径：PowerShell `Measure-Object -Line`，约等于非空行；文件总行数含空行为 577） | — |
| 基类 | `ChangeNotifier` | `auth_controller.dart:13` |
| 构造参数 | `AuthController(MusicApi _api, CacheService _cacheService)` | `auth_controller.dart:14` |
| 装配点 | `_KaMusicAppState.initState()` 中 `_auth = AuthController(_api, _cacheService)` | `main.dart:92` |
| 启动恢复调用 | `_auth.restore()`（未 await，非阻塞） | `main.dart:100` |
| UI 订阅点 | `main.dart` 的 `home` 用 `AnimatedBuilder(animation: _auth)` 决定显示 `LoginPage` 还是 `AppShell` | `main.dart:158-175` |
| 内部持有的后台任务 | `late final VipBackgroundTask _vipBackgroundTask = VipBackgroundTask(_api)` | `auth_controller.dart:25` |

### 2.2 公开状态字段

| 字段 | 类型 | 初值 | 语义 | 锚点 |
|---|---|---|---|---|
| `isRestoring` | `bool` | `true` | 启动恢复中；为 true 时 UI 不跳登录页 | `auth_controller.dart:27` |
| `isLoading` | `bool` | `false` | 请求进行中（驱动按钮 loading 态） | `auth_controller.dart:28` |
| `errorMessage` | `String?` | `null` | 最近一次错误文案，成功时清空 | `auth_controller.dart:29` |
| `session` | `LoginSession?` | `null` | 当前登录会话 | `auth_controller.dart:30` |
| `profile` | `UserProfile?` | `null` | 用户资料（昵称、头像） | `auth_controller.dart:31` |
| `playlists` | `List<PlaylistSummary>` | `const []` | 用户全部歌单（含我喜欢、收藏专辑） | `auth_controller.dart:32` |
| `_likedHashes` | `Set<String>`（私有） | `{}` | 我喜欢歌曲的 hash 集合 | `auth_controller.dart:34` |

### 2.3 派生只读成员

| 成员 | 返回 | 判定规则 | 锚点 |
|---|---|---|---|
| `isLoggedIn` | `bool` | `session?.isValid == true` | `auth_controller.dart:36` |
| `isLiked(Song)` | `bool` | `_likedHashes.contains(song.hash)` | `auth_controller.dart:38` |
| `likedCount` | `int` | 优先取「我喜欢」歌单的 `songCount`，为空时回退 `_likedHashes.length` | `auth_controller.dart:40-46` |
| `likedPlaylist` | `PlaylistSummary?` | `playlists` 中第一个 `isLikedPlaylist` | `auth_controller.dart:77-84` |
| `createdPlaylists` | `List<PlaylistSummary>` | 非收藏专辑 且 `isCreatedPlaylist` | `auth_controller.dart:86-93` |
| `collectedPlaylists` | `List<PlaylistSummary>` | 非我喜欢、非收藏专辑、非自建 | `auth_controller.dart:95-104` |
| `collectedAlbums` | `List<PlaylistSummary>` | `isCollectedAlbum` | `auth_controller.dart:106-108` |
| `findUserPlaylist(PlaylistSummary)` | `PlaylistSummary?` | 依次比对 `id`、`listId`、`sourceGlobalId` | `auth_controller.dart:110-121` |
| `isPlaylistInLibrary(PlaylistSummary)` | `bool` | `findUserPlaylist(...) != null` | `auth_controller.dart:123-125` |
| `canEditPlaylist(PlaylistSummary)` | `bool` | 库内项或自身 `isCreatedPlaylist` | `auth_controller.dart:127-130` |

`LoginSession.isValid` 的定义是 **`token` 非空 或 `sessionId` 非空**（`music_models.dart:20-22`），并不要求 `t1` 存在。

### 2.4 持久化键

| 键 | 常量 | 写入位置 | 清除位置 |
|---|---|---|---|
| `ka_music_token` | `_tokenKey`（:16） | `restore` :220、`refreshSession` :275、`loginWithSession` :293/:318、`login` :363 | `logout` :399、`_clearSession` :540 |
| `ka_music_t1` | `_t1Key`（:17） | `restore` :221、`refreshSession` :276、`loginWithSession` :294/:319、`login` :364 | `logout` :400、`_clearSession` :541 |
| `ka_music_session_id` | `_sessionIdKey`（:18） | `loginWithSession` :297/:320、`login` :366 | **仅 `logout` :401** |
| `ka_music_user_id` | `_userIdKey`（:19） | `restore` :222、`refreshSession` :277、`loginWithSession` :298/:321、`login` :367 | `logout` :402、`_clearSession` :542 |
| `ka_music_liked_hashes` | `_likedHashesKey`（:22） | `_persistLikedHashes` :429 | `logout` :405、`_clearSession` :545 |
| `ka_music_cached_playlists_{userId}` | `_playlistCachePrefix`（:20） | 迁移期读取，见 §3.7 | `logout` :403、`_clearSession` :543 |
| `ka_music_playlist_empty_count_{userId}` | `_playlistEmptyCountPrefix`（:21） | `_loadUserPlaylistsWithCache` :449/:455 | `logout` :404、`_clearSession` :544 |

派生键（Getter，依赖 `session?.userId`，缺省回退字符串 `default`）：

| Getter | 拼装结果 | 锚点 |
|---|---|---|
| `_playlistCacheKey` | `ka_music_cached_playlists_{userId}` | `auth_controller.dart:520-522` |
| `_playlistEmptyCountKey` | `ka_music_playlist_empty_count_{userId}` | `auth_controller.dart:524-526` |
| `_userCacheKey` | `cache_user_{userId}` | `auth_controller.dart:528` |
| `_playlistCacheKeyV2` | `cache_user_playlists_{userId}` | `auth_controller.dart:530-531` |

---

## 3. 设计说明

### 3.1 `restore()` 恢复流程

入口 `AuthController.restore()`（`auth_controller.dart:192-249`），步骤严格按顺序：

| 步 | 动作 | 失败/异常处理 | 锚点 |
|---|---|---|---|
| 1 | 读 4 个持久化键，构造 `LoginSession`（`nickname`/`avatarUrl` 不参与恢复） | — | :194-201 |
| 2 | `!restored.isValid` 直接 `return`（token 与 sessionId 都为空） | 未登录，UI 进登录页 | :203-205 |
| 3 | 赋 `session` 并 `_api.setSession(restored)` | — | :207-208 |
| 4 | 调 `_api.refreshToken()`（`POST /login/token`） | 捕获全部异常并**静默忽略**，继续用本地 token | :210-225 |
| 5 | 若后端返回的 `userId` 与本地存的 `userId` 不一致 → `_clearSession()` 并 `return`（防串号） | — | :212-217 |
| 6 | 用刷新结果覆盖 `session` 并回写 token / t1 / userId（**不回写 sessionId**） | — | :218-222 |
| 7 | `playlists = await _loadCachedPlaylists()` | 走缓存，不请求网络 | :227 |
| 8 | `await _loadLikedHashes()` | 解析失败静默忽略 | :228 |
| 9 | 读 `cache_user_{userId}` 得到 `profile` | 缓存未命中则 `profile` 保持 null | :230-237 |
| 10 | `isRestoring = false` + `notifyListeners()`（**缓存已就绪，先渲染**） | — | :239-240 |
| 11 | `await refreshProfile(silent: true)`（网络刷新资料 + 歌单 + 我喜欢） | `_run` 内捕获，写 `errorMessage` | :241 |
| 12 | `_vipBackgroundTask.schedule(session)` | 内部自行捕获 | :242 |
| 13 | `finally`：再次 `isRestoring = false` + `notifyListeners()` | — | :245-248 |

注意第 10 步与第 13 步会**重复置位并重复通知**，属于「提前渲染」的有意设计：第 10 步让 UI 立刻显示已登录壳，第 13 步兜底。

### 3.2 手机号验证码登录

| 步骤 | 调用链 | 说明 | 锚点 |
|---|---|---|---|
| 发码 | `LoginPage._sendCode` → `AuthController.sendCode(mobile)` → `MusicApi.sendLoginCode` → `POST /captcha/sent?mobile=` | 失败抛 `ApiException('发送验证码失败，若没有账号请先在酷狗音乐概念版App注册...')` | `login_page.dart:55-79`、`auth_controller.dart:283-285`、`music_api.dart:40-47` |
| 倒计时 | 成功且 `errorMessage == null` 时启动 60 秒 `Timer.periodic` | 每秒递减，到 0 停止 | `login_page.dart:81-98` |
| 登录 | `AuthController.login(mobile, code, {userId})` → `MusicApi.loginWithPhone` → `POST /login/cellphone`（body 含 mobile/code，可选 userId） | 登录前先 `_api.setSession(null)` 清空旧凭据 | `auth_controller.dart:342-373`、`music_api.dart:49-89` |
| 多账号分支 | 响应命中 `_requiresUserSelection(json)` → 返回 `PhoneLoginResult.accountSelection` | `requiresUserSelection => accounts.isNotEmpty` | `music_api.dart:64-76`、`music_models.dart:55` |
| 成功分支 | 写 4 个持久化键（`sessionId` 取 `_api.clientSessionId`）→ `refreshProfile(silent: true)` → 调度 VIP 任务 | — | `auth_controller.dart:358-370` |
| 多账号选择 | `LoginPage._showAccountSelection` 弹出 `_AccountSelectionSheet`，选中后带 `userId` 再次调用 `login` | 弹窗前判 `accounts.isEmpty` 直接返回 | `login_page.dart:122-143` |

`MobileLoginAccount` 的展示字段：`displayName` 依次取 `nickname` → `username` → `账号 {userId}`；`subtitle` 由 `username` 与 `AppID {appId}` 用 ` · ` 拼接，均为空时返回 null（`music_models.dart:73-88`）。

### 3.3 扫码登录

| 阶段 | 实现 | 锚点 |
|---|---|---|
| 取码 | `GET /login/qr/key` → `QrCodeInfo{key, imageUrl}`；`imageUrl` 为 `data:image/png;base64,...` | `music_api.dart:106-109`、`music_models.dart:1720-1732` |
| 二维码渲染 | `_QrImage` 识别 data URI 走 `Image.memory`，否则 `Image.network` | `login_page.dart:1116-1166` |
| 轮询 | `GET /login/qr/check?key=`，固定 2 秒间隔 | `music_api.dart:111-114`、`login_page.dart:247-256` |
| 状态码 | `0` 等待扫码 / `1` 已扫码待确认 / `2` 已过期 / `4` 登录成功 | `music_models.dart:1749-1753` |
| 成功 | 用返回的 `token/userId/nickname/pic` 组装 `LoginSession` 调 `AuthController.loginWithSession` | `login_page.dart:265-275` |
| 失败退避 | 单次请求异常计数 +1，`2 << (failures-1)` 秒后重试，上限 15 秒；连续 5 次失败停止轮询并置 `_qrExpired = true` | `login_page.dart:290-303` |
| 并发保护 | `_qrPollInFlight` 保证同一时刻只有一个在途请求 | `login_page.dart:259-261`、:304-306 |

`loginWithSession()` 的关键补偿逻辑（`auth_controller.dart:287-340`）：

1. 写 `token` / `t1` / `sessionId` / `userId`，其中 `sessionId` 取 `_api.clientSessionId`（`ApiClient` 已从登录响应头 `x-kg-session-id` 自动保存，见 `api_client.dart:139-142`）。
2. 扫码返回的 `QrCheckResult` **只有 token、没有 t1**，而 `/user/detail` 等接口需要 `t1` 头；因此当 `session.t1` 为空时主动调一次 `_api.refreshToken()`，并把结果与扫码返回的 `nickname`/`avatarUrl` 合并。
3. 若 `session.nickname` 非空，先构造临时 `UserProfile(nickname, avatarUrl)` 让 UI 立即显示，随后 `refreshProfile(silent: true)` 覆盖。

### 3.4 token 刷新

| 场景 | 方法 | 行为 | 锚点 |
|---|---|---|---|
| 启动恢复 | `restore()` 内联 | 失败静默，保留本地 token | :210-225 |
| 手动/外部 | `refreshSession()` | 失败静默，保留现有 session | :261-281 |
| 扫码登录缺 t1 | `loginWithSession()` 内联 | 失败静默，继续用原 token | :303-326 |

**没有**定时器、没有 401 拦截重试、没有「token 即将过期」预刷新。两处刷新都会做「后端 userId 与本地 userId 不一致则清空会话」的串号防护（:212-217、:267-272）。

### 3.5 登出清理

`logout()`（`auth_controller.dart:386-409`）用 `try/finally` 保证即使 `_api.logout()` 抛错也会本地清理：

| 清理对象 | 内容 | 锚点 |
|---|---|---|
| 内存 | `session` / `profile` 置 null，`playlists` 置空，`_likedHashes` 清空 | :394-397 |
| API 客户端 | `_api.setSession(null)` → 清空 `token`/`t1`/`sessionId` | :398、`music_api.dart:20-26` |
| SharedPreferences | 7 个键（含 `_sessionIdKey`） | :399-405 |
| CacheService | `_clearSession()` 内的 `_cacheService.clearUserCache(null)` | :546 |

`CacheService.clearUserCache(null)` 按前缀清理 `cache_user_` / `cache_playlist_` / `cache_album_` / `cache_artist_`，**有意保留 `cache_home`**（首页为匿名可访问内容，见 `cache_service.dart:47-61`、:124-148`）。

### 3.6 与 CacheService 的联动（登录后刷新用户缓存）

| 数据 | 缓存键 | TTL | 写 | 读 | 锚点 |
|---|---|---|---|---|---|
| 用户资料 | `cache_user_{userId}` | `AppConfig.userProfileTtl`（24 小时） | `refreshProfile` 内 `_cacheService.write` | `restore()` 第 9 步 | `auth_controller.dart:379`、:230-237 |
| 用户歌单列表 | `cache_user_playlists_{userId}` | 同上 | `_saveCachedPlaylists` | `_loadCachedPlaylists` | `auth_controller.dart:511-518`、:468-509 |

`refreshProfile({silent = false})` 的三段动作：`_api.userDetail()` → 写 `cache_user_{userId}` → `playlists = await _loadUserPlaylistsWithCache()` → `_syncLikedSongs()`（`auth_controller.dart:375-384`）。`silent: true` 时 `_run` 不置 `isLoading`、不提前 `notifyListeners()`（`auth_controller.dart:550-569`）。

### 3.7 歌单列表的缓存与空结果保护

`_loadUserPlaylistsWithCache()`（`auth_controller.dart:444-466`）的判定顺序：

| 条件 | 行为 |
|---|---|
| 网络返回非空 | `ka_music_playlist_empty_count_{userId}` 归 0，写 V2 缓存并返回网络结果 |
| 网络返回空，第 1 次 | 空计数 +1；若本地缓存非空则**返回本地缓存**（容忍后端偶发空响应） |
| 网络返回空，第 2 次及以后 | 删除旧 `_playlistCacheKey` 与 `_cacheService.remove(_playlistCacheKeyV2)`，返回 `const []` |

`_loadCachedPlaylists()`（:468-509）只做一次性旧缓存迁移：V2 命中则删除旧 key 并返回；V2 未命中则解析旧 `ka_music_cached_playlists_{userId}`，迁移写入 V2 后删除旧 key；解析失败也删除旧 key（避免反复重试阻塞登录）。

### 3.8 我喜欢歌曲的双轨同步

| 机制 | 数据源 | 触发 | 锚点 |
|---|---|---|---|
| 权威同步 | `_api.playlistSongs(likedPlaylist.id, fetchAll: true)` | `refreshProfile` → `_syncLikedSongs` | `auth_controller.dart:411-425` |
| 本地落盘 | `ka_music_liked_hashes`（JSON 数组） | `_persistLikedHashes` | :427-430 |
| 本地读取 | 解析失败静默忽略 | `_loadLikedHashes` | :432-442 |
| 乐观切换 | `toggleLike(Song)` 先改内存、再持久化；失败回滚并 `rethrow` | 由调用方决定提示 | :48-75 |

`toggleLike` 的目标歌单 ID 取 `playlist.listId` 非空则用之，否则用 `playlist.id`（`auth_controller.dart:53-55`）；`likedPlaylist` 为 null 时直接 `return`（未登录或我喜欢歌单未加载）。

### 3.9 登录页 UI 状态机

`_LoginPageState`（`login_page.dart:23-42`）的本地状态：

| 字段 | 类型 | 初值 | 作用 |
|---|---|---|---|
| `_mobileController` | `TextEditingController` | — | 手机号输入 |
| `_codeController` | `TextEditingController` | — | 验证码输入 |
| `_mobileFocus` / `_codeFocus` | `FocusNode` | — | 焦点与高亮 |
| `_mobilePattern` | `RegExp` | `^\d{11}$` | 手机号校验 |
| `_codeTimer` | `Timer?` | null | 60 秒倒计时 |
| `_sendingCode` | `bool` | false | 发码请求中 |
| `_localError` | `String?` | null | 本地校验错误（优先于 `auth.errorMessage`） |
| `_codeSeconds` | `int` | 0 | 倒计时剩余秒数，`>0` 时禁用发码按钮 |
| `_tabIndex` | `int` | 0 | 0=手机号登录，1=扫码登录 |
| `_qrCode` | `QrCodeInfo?` | null | 当前二维码 |
| `_qrStatusText` | `String` | `''` | 二维码状态文案 |
| `_qrLoading` | `bool` | false | 取码中 |
| `_qrExpired` | `bool` | false | 过期/失败，显示「刷新二维码」 |
| `_qrPollTimer` | `Timer?` | null | 轮询定时器 |
| `_qrPollInFlight` | `bool` | false | 在途请求保护 |
| `_qrPollFailures` | `int` | 0 | 连续失败次数，≥5 停止 |

状态迁移要点：

| 事件 | 迁移 | 锚点 |
|---|---|---|
| 切到扫码 Tab | `_tabIndex = 1` 并立即 `_loadQrCode()` | `login_page.dart:365-368` |
| 取码失败 | `_qrLoading = false`、`_qrStatusText = '获取二维码失败，点击重试'`、`_qrExpired = true` | :237-244 |
| 扫码成功 | 取消轮询 → `auth.loginWithSession` | :265-275 |
| 二维码过期 | 取消轮询、`_qrStatusText = '二维码已过期，点击刷新'` | :276-283 |
| 已扫码待确认 | `_qrStatusText = '扫码成功，请在手机上确认'` 并继续轮询 | :284-289 |
| 连续 5 次异常 | 取消轮询、`_qrStatusText = '网络异常，二维码轮询已暂停，请点击刷新'` | :292-298 |
| `dispose` | 取消两个 Timer 并释放控制器与焦点节点 | :45-53 |

页面同时暴露「API 服务器地址」入口（右上角 `Icons.dns_rounded`），通过 `AppConfig.saveCustomBaseUrl` 写 `settings.custom_api_base_url`，提示文案明确「重启后生效」（`login_page.dart:145-218`、`app_config.dart:82-95`）。

### 3.10 失败与错误码处理

| 层级 | 处理 | 锚点 |
|---|---|---|
| 传输层 | `ApiException(message, statusCode)`；500/502/503/504 重试，最多 2 次，单次超时 15s、总 deadline 45s | `api_client.dart:9-17`、:78-135 |
| API 层 | `sendLoginCode` / `loginWithPhone` 失败抛中文 `ApiException`，文案统一附带「若没有账号请先在酷狗音乐概念版App注册」 | `music_api.dart:13`、:45、:78 |
| 控制器层 | `_run` 捕获后 `errorMessage = _errorText(error)`：`ApiException` 取 `message`，其余 `toString()` | `auth_controller.dart:550-576` |
| UI 层 | 表单错误文案优先显示 `_localError`，其次 `auth.errorMessage`；`AnimatedSwitcher` 淡入 | `login_page.dart:377-378`、:547-564 |
| 多账号分支 | `PhoneLoginResult.errorCode` 被解析但不参与 UI 判断，仅 `message` 用于弹窗说明 | `music_api.dart:70-75`、`login_page.dart:598-604` |

`AuthController` 未按 `statusCode` 或 `error_code` 做分支处理，**所有错误都以文案形式呈现**，没有重试、没有区分「验证码错误」与「账号不存在」。

---

## 4. 约束与坑

1. **`_clearSession()` 清理的歌单缓存键可能不是当前用户的键。** 该方法在 `session = null`（:538）之后才读取 `_playlistCacheKey` / `_playlistEmptyCountKey`（:543-544），Getter 会回退到 `default` 后缀，因此 `ka_music_cached_playlists_{真实userId}` 不会被删除。`logout()` 不受影响（它在置 null 之前先缓存了 key，:392-393），但 `restore()` 的 userId 不一致分支（:215）与 `refreshSession()` 的同名分支（:270）会走到这条路径。
2. **`_clearSession()` 不删 `ka_music_session_id`**（:540-545 只删 token/t1/userId/两个歌单键/liked），而 `logout()` 删了（:401）。两条清理路径不一致。
3. **`refreshSession()` 目前没有任何调用方。** 全仓库 grep 只在定义处命中（`auth_controller.dart:261`），属于未接线能力。
4. **没有 token 过期检测与自动重登。** 一旦 token 失效，后续接口报错只体现在 `errorMessage`，用户需手动重新登录。
5. **`restore()` 的 `refreshToken` 失败被完全吞掉**（:223-225），本地 token 可能已失效但 UI 仍显示已登录。
6. **`_likedHashes` 与 `likedCount` 可能不一致**：`likedCount` 优先取歌单 `songCount`，而 `_likedHashes` 依赖 `playlistSongs(fetchAll: true)` 全量拉取；全量拉取失败时会回退本地缓存（:422-424），此时两者来自不同快照。
7. **二维码轮询固定 2 秒、无自适应加速**，仅在**异常**时退避（:300-302）。
8. **`sendCode` 无本地频率限制**，60 秒倒计时只是 UI 层约束（`login_page.dart:56`），控制器本身不做节流。
9. **`login()` 在发起前调用 `_api.setSession(null)`**（:349），意味着一次失败的手机号登录会清掉 `ApiClient` 内存中的凭据；若此时用户已登录，内存态会与 SharedPreferences 不一致（持久化键未被清）。
10. **`_playlistCacheKeyV2` 与 `CacheService` 的 `cache_user_` 前缀重叠**：`cache_user_playlists_{id}` 同时匹配 `_userCachePrefixes` 中的 `cache_user_`，因此登出时会被 `clearUserCache` 一并清掉，而 `_playlistCacheKey`（`ka_music_cached_playlists_`）不在前缀列表内，只能靠显式 `prefs.remove` 清理。

---

## 5. 待办与关联

### 5.1 待办

| 项 | 说明 | 优先级 |
|---|---|---|
| 统一会话清理路径 | 让 `_clearSession()` 与 `logout()` 删除完全相同的键集合，并在置 null 前捕获派生 key | 高 |
| 接线或删除 `refreshSession()` | 目前是死代码；若要用于「前台恢复时刷新」，需在 `main.dart` 生命周期回调中调用 | 中 |
| token 失效自动登出 | 依赖 `ApiClient` 暴露 401/鉴权错误信号，当前无此能力（待核实后端是否返回固定状态码） | 中 |
| 错误码分支 | `PhoneLoginResult.errorCode` 已解析未使用，可按错误码给出差异化文案 | 低 |
| 发码节流下沉 | 把 60 秒限制从 UI 移到控制器，避免其他入口绕过 | 低 |

### 5.2 关联文档

- 启动装配与 `restore()` 的调用时机：`../02-架构设计/启动流程与依赖装配.md`
- 用户缓存键、`clearUserCache` 前缀策略与 TTL：`服务层-缓存体系.md`
- 播放链路中 `AuthController` 的消费点（`isLiked` / `toggleLike`）：`控制器层-PlayerController.md`
- 登录页与设置页的导航关系：`UI层-页面与组件清单.md`
- 持久化键总表：`../04-数据与接口/本地存储与配置项清单.md`
