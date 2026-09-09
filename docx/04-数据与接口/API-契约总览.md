# API 契约总览

> 文档编号：KA-04-02
> 级别：L1 📌
> 状态：现行
> 关联代码：`lib/config/app_config.dart`（base URL 与路径拼接） + `lib/core/api_client.dart`（传输/重试/解包） + `lib/services/music_api.dart`（端点封装） + 项目根目录 `api.json`（OpenAPI 3.1.1）
> 最近更新：2026-09-08
> 变更触发条件：新增/删除端点、改动 base URL 解析、改动鉴权头、改动成功/失败判定键、改动重试与超时策略、新增分页参数

---

## 一句话结论（TL;DR）

App 只走一条 HTTP 通道：`MusicApi` → `ApiClient` → `AppConfig.apiUri`；`ApiClient` 自动剥离响应体顶层 `data` 节点（`api_client.dart:160-168`），**业务成功与否只认 `status == 1`**（`music_api.dart:578-580`），而当前**只有登录链路**真正检查了这个判定。
新增接口必须走本文 §10 的 8 步流程，且不得手改 `API-端点清单.md` / `API-Schema索引.md`（自动生成）。

---

## 1. 契约总览（事实）

| 项 | 值 | 锚点 |
|---|---|---|
| OpenAPI 版本 | 3.1.1 | `api.json:2` |
| 文档标题 / 版本 | `KuGou Music API` / `v1` | `api.json:3-7` |
| OpenAPI `servers` | `https://localhost:7293/` | `api.json:8-12` |
| 端点总数（method × path） | 149 | `API-端点清单.md:9` |
| Schema 总数 | 111 | `API-Schema索引.md:4` |
| 标签分组 | 19（Album / Artist / Captcha / Comment / Discovery / ExternalPlaylist / Fm / Login / Lyric / MediaCatalog / PlayList / Rank / Register / Report / Search / Song / User / Youth / ApplicationInfo） | `api.json` `tags` |
| App 默认 base URL | `https://music.api.hoilai.cn` | `app_config.dart:10` |
| 编译期覆盖变量 | `KA_MUSIC_API_BASE_URL`（`String.fromEnvironment`） | `app_config.dart:14-17` |
| 运行时覆盖键 | `settings.custom_api_base_url`（SharedPreferences） | `app_config.dart:12`、`:65-95` |
| 已废弃域名（自动清除） | `https://music.api.hoilai.com` | `app_config.dart:11`、`:71`、`:88` |
| MusicApi 封装的端点 | 39 | `music_api.dart`（见 §8） |

> **注意**：`api.json` 的 `servers` 是本地调试地址，与 App 默认 base URL 不同。文档里的服务器地址**不能**当作 App 实际请求地址。

---

## 2. base URL 解析规则（`AppConfig.apiUri`）

`app_config.dart:97-112` 是**唯一**的 URL 拼装入入口：

```dart
static Uri apiUri(String path, [Map<String, Object?> query = const {}]) {
  final base = Uri.parse(effectiveBaseUrl);
  final cleanPath = path.startsWith('/') ? path.substring(1) : path;
  final normalizedBasePath = base.path.endsWith('/') ? base.path : '${base.path}/';
  return base.replace(
    path: '$normalizedBasePath$cleanPath',
    queryParameters: {
      for (final entry in query.entries)
        if (entry.value != null && entry.value.toString().isNotEmpty)
          entry.key: entry.value.toString(),
    },
  );
}
```

| 规则 | 行为 | 举例（base = `https://music.api.hoilai.cn`） |
|---|---|---|
| 前导斜杠 | `path` 以 `/` 开头时去掉一个 | `'/song/url'` → `song/url` |
| base 路径补尾斜杠 | `base.path` 不以 `/` 结尾则补 | 空 path → `'/'` |
| 拼接 | `base.path + cleanPath` | 空 base path → `'/song/url'` |
| 带子路径的 base | 保留子路径 | base `https://x/api` → `https://x/api/song/url` |
| **空值过滤** | `null` 或 `toString().isEmpty` 的参数**整条丢弃** | `{'hash': 'AB', 'album_id': null}` → 只发 `hash=AB` |
| 值转换 | 一律 `toString()` | `page: 1` → `page=1`；`free_part: false` → `free_part=false` |
| 编码 | 由 `Uri.replace` 负责 | 关键词自动百分号编码 |

### 2.1 base URL 生效优先级

| 优先级 | 来源 | 说明 | 锚点 |
|---|---|---|---|
| 1（最高） | `_customBaseUrl`（运行时用户设置） | 非空即生效 | `app_config.dart:53` |
| 2 | `AppConfig.apiBaseUrl`（编译期） | `--dart-define=KA_MUSIC_API_BASE_URL=...` | `app_config.dart:14-17` |
| 3（兜底） | `_defaultApiBaseUrl` | 常量默认值 | `app_config.dart:10` |

自定义 base URL 的写入/清理规则（`app_config.dart:82-95`）：传入 `null`、空串、**等于编译期默认值**、或命中废弃域名列表时，一律清除持久化并回落默认值。

---

## 3. 统一响应解包与业务判定

### 3.1 解包（`api_client.dart:160-168`）

| 响应形态 | `unwrapData` 结果 |
|---|---|
| `Map` 且含非 null 的 `data` | 返回 `data` 的值（**顶层包装被剥离**） |
| `Map` 无 `data` 或 `data` 为 null | 返回整个 `Map` |
| 非 Map（数组、字符串、数字） | 原样返回 |

因此 `MusicApi` 里 `asMap(await _client.get('/user/playlist', ...))` 拿到的**就是 `data` 节点**，字段直接读 `json['info']` / `json['userid']`（`music_api.dart:125-130`）。

### 3.2 HTTP 层（`api_client.dart:138-155`）

| 情况 | 行为 |
|---|---|
| 响应头含 `x-kg-session-id` 且非空 | 写入 `ApiClient.sessionId` |
| `statusCode` 不在 200–299 | `throw ApiException(response.body, statusCode: ...)` |
| body 去空白后为空 | 返回 `null` |
| body 是合法 JSON | `jsonDecode` 后 `unwrapData` |
| body 不是合法 JSON（`FormatException`） | **返回原始字符串**（不抛错） |

### 3.3 业务成功/失败判定（`music_api.dart`）

| 判定函数 | 锚点 | 规则 |
|---|---|---|
| `_isSuccess(json)` | `music_api.dart:578-580` | `asInt(json['status']) == 1` |
| `_requiresUserSelection(json)` | `music_api.dart:582-590` | 若 `json['requiresUserSelection']` 是 `bool` 则直接用它；否则 `asInt(errorCode ?? error_code) == 34175` **且** `accounts` 非空 |
| `_failureSuffix(json)` | `music_api.dart:592-612` | 依次取 `msg` → `message` → `errmsg` → `error` → `error_msg`，命中则返回 `'：$message'`；否则取 `error_code` → `errcode` → `code` 返回 `'（错误码：$code）'`；都没有返回空串 |
| `_registerHint` | `music_api.dart:13` | `'若没有账号请先在酷狗音乐概念版App注册'`，拼接在登录类错误消息里 |

### 3.4 哪些方法真正检查了成功判定

| 方法 | 锚点 | 检查内容 |
|---|---|---|
| `sendLoginCode` | `music_api.dart:40-47` | `!_isSuccess` → `throw ApiException('发送验证码失败，$hint$suffix')` |
| `loginWithPhone` | `music_api.dart:49-89` | 先 `_requiresUserSelection`（返回多账号结果），再 `!_isSuccess` → `throw` |
| **其余全部方法** | `music_api.dart:91-866` | **不检查 `status`**，直接按字段解析；业务失败会得到空列表/默认值，不抛异常 |

> 这是当前契约最大的隐含风险：除登录外的接口，后端返回 `status != 1` 时 UI 只会看到「空数据」，不会看到错误原因。见 §11 第 1 条。

---

## 4. 鉴权与请求头

| 请求头 | 取值来源 | 何时出现 | 锚点 |
|---|---|---|---|
| `Accept` | 固定 `application/json` | 始终 | `api_client.dart:59` |
| `Content-Type` | 固定 `application/json` | 始终（GET 也带） | `api_client.dart:60` |
| `X-Kg-Session-Id` | 先由 `token` 写入 | `token != null` | `api_client.dart:63-66` |
| `X-Kg-Session-Id` | 再由 `sessionId` **覆盖** | `sessionId != null` | `api_client.dart:70-72` |
| `t1` | `t1` | `t1 != null` | `api_client.dart:67-69` |
| `Authorization` | **已注释，未启用** | 永不 | `api_client.dart:64` |

会话写回链路：

| 环节 | 行为 | 锚点 |
|---|---|---|
| 响应头 `x-kg-session-id` | 自动保存到 `ApiClient.sessionId` | `api_client.dart:139-142` |
| `MusicApi.setSession(null)` | 清空 `token` / `t1` / `sessionId` | `music_api.dart:21-25` |
| `MusicApi.setSession(session)` | 写 `token` / `t1`；**`sessionId` 为空时不覆盖**（保留响应头里的值） | `music_api.dart:27-37` |
| 登录成功返回 | `LoginSession.sessionId` 取 `_client.sessionId` | `music_api.dart:80-88`、`:91-100` |
| `MusicApi.clientSessionId` | 只读暴露 `_client.sessionId` | `music_api.dart:18` |


---

## 5. 重试、超时与并发

`ApiClient._sendWithRetry`（`api_client.dart:78-135`）：

| 参数 | 值 | 说明 |
|---|---|---|
| `maxRetries` | 2（共最多 3 次尝试） | `api_client.dart:80` |
| `allowRetry`（GET） | `true` | `get` 未传该参数，用默认值 |
| `allowRetry`（POST） | **`false`** | `post({allowRetry = false})`（`api_client.dart:45`）→ **POST 默认不重试** |
| 单次尝试超时 | 15 秒 | `api_client.dart:83` |
| 总体 deadline | 45 秒 | `api_client.dart:84` |
| 可重试状态码 | 500 / 502 / 503 / 504 | `api_client.dart:96-101` |
| 退避基数 | `500ms × 2^attempt` | `api_client.dart:127` |
| `Retry-After` | 秒 × 1000，clamp 到 0–15000ms | `api_client.dart:125-128` |
| 抖动 | 随机 0–249ms | `api_client.dart:129` |
| 触发重试的异常 | `TimeoutException`、`http.ClientException` | `api_client.dart:107-112` |
| 直接抛出、不重试 | `FormatException` | `api_client.dart:113-114` |
| 重试耗尽 | `throw ApiException('请求失败，已重试 2 次')` | `api_client.dart:117` |
| deadline 用尽 | `throw TimeoutException('API request deadline exceeded')` | `api_client.dart:90`、`:133` |

> 幂等性约定：GET 默认可重试，POST 必须显式传 `allowRetry: true` 才会重试；当前 `MusicApi` **没有任何** POST 调用传了该参数。

---

## 6. 错误码与状态语义

| 位置 | 字段 | 取值 | 含义 | 处理锚点 |
|---|---|---|---|---|
| HTTP | `statusCode` | 非 200–299 | 传输层失败，抛 `ApiException(statusCode)` | `api_client.dart:143-145` |
| 业务 | `status` | `1` | 成功（唯一判定条件） | `music_api.dart:578-580` |
| 登录 | `errorCode` / `error_code` | `34175` + `accounts` 非空 | 同一手机号多账号，需用户选择 | `music_api.dart:582-590` |
| 登录 | `requiresUserSelection` | `true` | 同上（新契约显式布尔，优先于错误码） | `api.json:8419-8421` |
| 二维码 | `status` | 0 / 1 / 2 / 4 | 等待扫码 / 已扫码待确认 / 已过期 / 登录成功 | `music_models.dart:1749-1753` |
| 播放地址 | `PlayUrlData.err_code` | 整数 | 错误码（**App 内未读取**） | `api.json:9226-9234` |
| 播放地址 | `PlayUrlData.priv_status` | 整数 | 权限状态（**App 内未读取**） | `api.json:9217-9225` |
| 云盘曲目 | `PrivilegeLiteData.privilege` | 8 / 10 | 8=免费，10=VIP/付费（**App 内未读取**） | `api.json` `PrivilegeLiteData` |

> 除上表外，`api.json` **没有**定义错误码枚举表（`api.json` 中 `error_code` 的 `description` 仅为「错误码。」，见 `api.json:6835`、`:9232`）。任何具体错误码语义都属于**待核实**，不得凭猜测写入代码分支。

---

## 7. 分页约定

`MusicApi` 各分页方法的默认值（全部为 1-based `page`）：

| 方法（锚点） | 端点 | 参数 | 默认值 | 说明 |
|---|---|---|---|---|
| `userPlaylists` `music_api.dart:121` | `/user/playlist` | `page` / `pagesize` | 1 / 30 | 返回后重排：前 2 项固定，其余逆序（`_orderUserPlaylistsForDisplay`，`:869-876`） |
| `recommendedPlaylists` `:186` | `/top/playlist` | `category_id` / `page` | 0 / 1 | **无 `pagesize`** |
| `albumShop` `:208` | `/album/shop` | `page` / `pagesize` | 1 / 30 | 过滤 `mediaId > 0` |
| `fmSongs` `:242` | `/fm/songs` | `fmid` / `type` / `offset` / `size` | −1 / 电台 `type` / 20 | `offset = -1` 表示「服务端决定起点」 |
| `artistAudios` `:314` | `/artist/audios` | `id` / `page` / `pagesize` / `sort` | 1 / 30 / `hot` | `sort` 为字符串 |
| `albumSongPage` `:346` | `/album/songs` | `id` / `page` / `pagesize` | 1 / 30 | 返回 `SongPage`（含 `rawItemCount`） |
| `musicComments` `:388` | `/comment/music` | `mixsongid` / `page` / `pagesize` | 1 / 30 | |
| `playlistSongPage` `:444` | `/playlist/track/all` | `id` / `page` / `pagesize` | 1 / 80 | |
| `playlistSongs(fetchAll: true)` `:408` | `/playlist/track/all` | `page` / `pagesize` | 每页 **200** | 循环直到 `rawItemCount < 200` 或空页或 `shouldCancel()` 返回 true（`:427-440`） |
| `cloudDrive` `:491` | `/user/cloud` | `page` / `pagesize` | 1 / 30 | |
| `searchSongs` `:634` | `/search` | `keywords` / `page` / `pagesize` / `type` | 1 / 30 / `song` | |
| `searchSuggest` `:622` | `/search/suggest` | `keywords` | — | 返回字符串列表，无分页 |
| `searchHotKeywords` `:614` | `/search/hot` | — | — | 无分页 |

**翻页终止判定**：仅 `playlistSongs(fetchAll: true)` 有自动翻页逻辑，用 `songPage.rawItemCount < perPage` 判断（`music_api.dart:438`）——注意它比较的是**原始条目数**而非解析后条数，因为解析会静默丢弃无效曲目。

---

## 8. MusicApi 方法 ↔ 端点 ↔ 模型对照表

| MusicApi 方法 | 锚点 | HTTP | 端点 | 返回模型 | 关键行为 |
|---|---|---|---|---|---|
| `clientSessionId` | `:18` | — | — | `String?` | 只读暴露 `ApiClient.sessionId` |
| `setSession` | `:20` | — | — | void | `null` 清空；`sessionId` 空则不覆盖 |
| `sendLoginCode` | `:40` | POST | `/captcha/sent` | void | 校验 `status`，失败抛错 |
| `loginWithPhone` | `:49` | POST | `/login/cellphone` | `PhoneLoginResult` | 先判多账号，再判 `status` |
| `refreshToken` | `:91` | POST | `/login/token` | `LoginSession` | 注入 `_client.sessionId` |
| `logout` | `:102` | POST | `/login/logout` | void | 忽略响应体 |
| `getQrCode` | `:106` | GET | `/login/qr/key` | `QrCodeInfo` | |
| `checkQrStatus` | `:111` | GET | `/login/qr/check` | `QrCheckResult` | 参数 `key` |
| `userDetail` | `:116` | GET | `/user/detail` | `UserProfile` | |
| `userPlaylists` | `:121` | GET | `/user/playlist` | `List<PlaylistSummary>` | `fromUser` + 展示重排 |
| `recommendedPlaylists` | `:186` | GET | `/top/playlist` | `List<PlaylistSummary>` | `fromRecommend` |
| `dailyRecommend` | `:203` | GET | `/recommend/songs` | `DailyRecommend` | |
| `albumShop` | `:208` | GET | `/album/shop` | `List<AlbumShopItem>` | 过滤 `mediaId > 0` |
| `fmRecommendedStations` | `:222` | GET | `/fm/recommend` | `List<FmStation>` | 响应可能是数组或 `{data:[]}` |
| `fmClassGroups` | `:232` | GET | `/fm/class` | `List<FmClassGroup>` | 过滤空分组 |
| `fmSongs` | `:242` | GET | `/fm/songs` | `List<Song>` | 多页 `FmSongPage` 展开为一维 |
| `fmImages` | `:264` | GET | `/fm/image` | `Map<String, FmImage>` | `fmid` 去重后逗号连接；空集合直接返回 `{}` |
| `vipReceiveHistory` | `:281` | GET | `/youth/month/vip/record` | `VipReceiveHistory` | |
| `dailyVip` | `:286` | GET | `/youth/day/vip` | `OneDayVipResult` | |
| `upgradeVipReward` | `:291` | GET | `/youth/day/vip/upgrade` | `UpgradeVipResult` | |
| `addListeningTime` | `:296` | POST | `/listen/timeadd` | void | 忽略响应体 |
| `latestAppVersion` | `:300` | GET | `/mobile/app/versions/latest` | `AppVersionInfo` | `platform` = 枚举 `apiValue` |
| `artistDetail` | `:309` | GET | `/artist/detail` | `ArtistDetail` | `id` 由调用方传入模型 |
| `artistAudios` | `:314` | GET | `/artist/audios` | `List<Song>` | `fromArtistAudio`；过滤 `hash` 空 |
| `albumSongPage` | `:346` | GET | `/album/songs` | `SongPage` | `fromAlbum`；`rawItemCount` 为原始条数 |
| `musicComments` | `:388` | GET | `/comment/music` | `MusicCommentResponse` | |
| `playlistInfo` | `:403` | GET | `/playlist/detail` | `PlaylistSummary` | `fromDetail`，参数名是 `ids` |
| `playlistSongs` | `:408` | GET | `/playlist/track/all` | `List<Song>` | `fetchAll` 时自动翻页 |
| `playlistSongPage` | `:444` | GET | `/playlist/track/all` | `SongPage` | `fromPlaylist` |
| `songUrl` | `:465` | GET | `/song/url` | `PlayUrl` | 传 `hash`/`quality`/`album_id`/`album_audio_id`/`free_part` |
| `cloudDrive` | `:491` | GET | `/user/cloud` | `CloudDriveResult` | 过滤 `hash` 空 |
| `cloudSongUrl` | `:506` | GET | `/user/cloud/url` | `PlayUrl` | **手工组装**，`loudness` 恒为 null |
| `createPlaylist` | `:520` | POST | `/playlist/create` | void | `type` = 私密 1 / 公开 0 |
| `collectPlaylist` | `:527` | POST | `/playlist/add` | void | 参数走 query |
| `deletePlaylist` | `:537` | POST | `/playlist/del` | void | 参数 `listid` |
| `addToPlaylist` / `addSongsToPlaylist` | `:541` / `:545` | POST | `/playlist/tracks/add` | void | body = `{listId, songs[]}` |
| `removeFromPlaylist` / `removeSongsFromPlaylist` | `:553` / `:557` | POST | `/playlist/tracks/del` | void | `fileids` 逗号连接 `song.id` |
| `searchHotKeywords` | `:614` | GET | `/search/hot` | `List<SearchHotCategory>` | |
| `searchSuggest` | `:622` | GET | `/search/suggest` | `List<String>` | 取 `music[].keyword` |
| `searchSongs` | `:634` | GET | `/search` | `List<Song>` | `type=song`；响应可能是数组 |
| `lyrics` | `:722` | GET | `/search/lyric` + `/lyric` | `List<LyricLine>` | 最多试 8 个候选，取行数最多者 |
| `searchLyricCandidates` | `:752` | GET | `/search/lyric` | `List<LyricCandidate>` | 递归收集 + `id:accessKey` 去重 |
| `lyricsFromCandidate` | `:797` | GET | `/lyric` | `List<LyricLine>` | 先 `krc`，为空再 `lrc` |
| `_lyricByFormat` | `:803` | GET | `/lyric` | `List<LyricLine>` | 私有；`decode: true` |
| `parseLyrics`（顶层函数） | `:878` | — | — | `List<LyricLine>` | KRC/LRC 解析 + 翻译/音译合并 |

---

## 9. 端点覆盖情况

| 项 | 数量 | 说明 |
|---|---|---|
| `api.json` 声明端点 | 149 | 见 `API-端点清单.md` |
| `MusicApi` 已封装 | 39 | 见 §8 |
| 未封装 | 110 | 见 `API-端点清单.md`（如 `/album`、`/album/detail`、`/artist/albums`、`/artist/videos`、`/artist/lists`、`/comment/album`、`/comment/floor`、`/singer/list` 等） |

权威来源：`API-端点清单.md`（按 19 个 tag 分组，含 method/path/summary/query 参数与 required 标记）与 `API-Schema索引.md`（111 个 schema 的属性清单）。两份文档由脚本从 `api.json` 自动生成，**禁止手工编辑**，端点变化时重新生成即可。

---

## 10. 新增一个接口的 8 步标准流程

| 步 | 动作 | 产出/检查点 |
|---|---|---|
| 1 | 在 `api.json` 定位端点：确认 method、路径、参数（query/body）与响应 schema；对照 `API-端点清单.md` 的 required 标记与 `API-Schema索引.md` 的字段名 | 记录端点路径与 schema 名 |
| 2 | 在 `lib/models/` 复用或新增模型：字段用 `asString` / `asInt` / `asList` / `asMap`；嵌套对象用 `is Map` 判型；每个可空字段给出默认值 | 模型类 + `fromJson`（必要时 `toCache`/`fromCache`） |
| 3 | 在 `MusicApi` 新增方法：`Future<X> name(...)`，GET 用 `_client.get(path, query)`，POST 用 `_client.post(path, query:, body:)`；空值参数交给 `AppConfig.apiUri` 自动过滤 | 方法体不拼接 URL 字符串 |
| 4 | 解包：`asMap(await ...)`；若响应可能是裸数组，按 `raw is List ? raw : asList(json['k'] ?? _firstListValue(json))` 兜底 | 兼容两种响应形态 |
| 5 | 若需要判定业务失败，用 `_isSuccess(json)` 并 `throw ApiException('中文提示' + _failureSuffix(json))`（当前仅登录链路如此） | 明确错误文案 |
| 6 | 若需要缓存，在对应 Controller 用 `CacheService.swr`（`cache_service.dart:208`），key 用 `cache_` 前缀（`cache_service.dart:47-53`），TTL 从 `AppConfig` 取 | 缓存 key 与 TTL 有据可查 |
| 7 | 更新文档：本文 §8 对照表；若引入新字段/模型，同步 `数据模型参考.md`；端点清单/Schema 索引重新生成 | 文档与代码同提交 |
| 8 | 验证：`flutter analyze` 通过；手工跑通登录态与匿名态各一次；无自动化用例时在 PR 描述写明验证步骤与真实响应片段 | 可复现的验证记录 |

> 反例（禁止）：直接把 URL 写死成字符串、跳过 `AppConfig.apiUri`；用 `try/catch` 吞掉 `ApiException` 后返回空列表；手改 `API-端点清单.md`。

---

## 11. 约束与坑

1. **除登录外没有业务失败判定**。`_isSuccess` 只在 `sendLoginCode` / `loginWithPhone` 里被调用（`music_api.dart:44`、`:77`）；其它接口即使返回 `status != 1` 也会被当作成功解析，UI 只能看到空列表。新增接口若依赖失败提示，必须显式加判定。
2. **POST 默认不重试**（`api_client.dart:45`）。写操作（建歌单、加曲、删曲）网络抖动即失败，需调用方自行重试。
3. **空值参数被静默丢弃**（`app_config.dart:107-109`）。`songUrl` 的 `album_id` / `album_audio_id` 为 null 时不会出现在请求里（`music_api.dart:470-476`），可能影响后端选源；不要误以为「传了 null」等价于「显式传空」。
4. **`unwrapData` 会剥离 `data`**（`api_client.dart:160-168`）。若某端点返回 `{"data": null, ...}`，会拿到整个 Map 而非 null，字段读取会全部落空——排查时先打印原始响应。
5. **非 JSON 响应被当成字符串返回**（`api_client.dart:149-154`）。网关返回 HTML 错误页时 `asMap` 得到 `{}`，表现为静默空数据。
7. **两个参数未在契约中声明**：`searchLyricCandidates` 发送 `keyword` 与 `duration`（`music_api.dart:757-758`），而 `api.json` 的 `/search/lyric` 只声明 `hash` / `album_audio_id` / `keywords` / `man`（`api.json:2183-2215`）。属历史兼容写法，改动前需抓包确认。
8. **加曲 body 与 schema 不一致**：`_songAddPayload` 发 `{name, hash, albumId, mixSongId}`（`music_api.dart:569-576`），而 `AddSongItem` 声明的是 `{hash, fileid, name}`（`api.json:6143-6164`）；`albumId` / `mixSongId` 未声明，`fileid` 未发送。
9. **`Content-Type: application/json` 对 GET 也发送**（`api_client.dart:60`）。若后续接入第三方 CDN，需确认其容忍带 body 类型头的 GET。
10. **登录态依赖响应头**：`sessionId` 只能从 `x-kg-session-id` 响应头获得（`api_client.dart:139-142`）；一旦被代理剥离，`/user/detail`、`/user/playlist` 将拿不到数据。
11. **契约不稳定信号**：多个方法对同一响应做了多键兜底（`searchSongs` 的 `songs`/`song`/`lists`，`albumSongPage` 的 `songs`/`data`/`info`/`_firstListValue`），说明后端返回形态历史上有变动；新增接口不要假设单一形态。
12. **`api.json` 的 `servers` 与 App 默认地址不同**（`api.json:8-12` 为 `https://localhost:7293/`），不要把 `servers` 当作生产地址。

---

## 12. 待办与关联

| 事项 | 说明 | 关联文档 |
|---|---|---|
| 补齐业务失败判定 | 除登录外的接口缺少 `_isSuccess` 检查，建议统一到 `ApiClient` 或 `MusicApi` 公共出口 | `../06-质量保障/已知问题与技术债台账.md` |
| 写操作重试策略 | POST 默认不重试，需明确「哪些写操作可安全重试」 | `../03-模块详解/服务层-MusicApi.md` |
| 参数契约对齐 | `/search/lyric` 的 `keyword`/`duration`、`/playlist/tracks/add` 的 `albumId`/`mixSongId` 与 `api.json` 不一致，需与后端确认后二选一 | `API-端点清单.md` |
| 端点覆盖推进 | 110 个未封装端点按需求排期，不要一次性全量接入 | `../07-推进计划/任务分解-WBS.md` |
| 缓存与鉴权细节 | `CacheService.swr` 的 TTL/Key 规范、登出清理范围 | `../03-模块详解/服务层-缓存体系.md`、`本地存储与配置项清单.md` |
| 模型字段与命名差异 | 端点返回字段的命名不一致清单 | `数据模型参考.md` §4 |
