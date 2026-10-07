# KA Music 后端 API 端点清单（自动生成）

> 文档编号：KA-04-03
> 级别：L1 📌
> 状态：现行
> 关联代码：项目根目录 api.json（脚本自动生成）
> 最近更新：2026-09-08
> 变更触发条件：api.json 更新后重新生成

> 来源：`api.json`（OpenAPI 3.1.1，title = KuGou Music API，servers = https://localhost:7293/）。
> 生成命令：`node docx/tools/gen-api-docs.js`。参数列中 `*` 表示 required=true。

## 统计

- 端点（method x path）：**149**
- 路径数：**149**
- 标签分组数：**19**

## 按标签分组的端点

### Album（4）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/album` | 专辑信息。 | `album_id*`, `fields` |
| GET | `/album/detail` | 专辑详情。 | `id*` |
| GET | `/album/shop` | 新碟上架。 | - |
| GET | `/album/songs` | 获取专辑歌曲列表。 | `id*`, `page`, `pagesize` |

### ApplicationInfo（2）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/mobile/app/versions` | 获取所有版本信息，可按平台过滤。 | `platform` |
| GET | `/mobile/app/versions/latest` | 获取指定平台的最新版本信息。 | `platform*` |

### Artist（10）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/artist/albums` | 获取歌手专辑。 | `id*`, `page`, `pagesize`, `sort` |
| GET | `/artist/audios` | 获取歌手歌曲。 | `id*`, `page`, `pagesize`, `sort` |
| GET | `/artist/detail` | 获取歌手详情。 | `id*` |
| POST | `/artist/follow` | 关注歌手。 | `id*` |
| POST | `/artist/follow/newsongs` | 获取关注歌手新歌。 | `last_album_id`, `pagesize`, `opt_sort` |
| POST | `/artist/honour` | 歌手荣誉。 | `id`, `page`, `pagesize` |
| GET | `/artist/lists` | 获取歌手列表。 | `musician`, `sextypes`, `type`, `hotsize` |
| POST | `/artist/unfollow` | 取消关注歌手。 | `id*` |
| GET | `/artist/videos` | 获取歌手MV。 | `id*`, `page`, `pagesize`, `tag` |
| GET | `/singer/list` | 获取歌手列表。 | `sextype`, `type`, `hotsize` |

### Captcha（1）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| POST | `/captcha/sent` | 发送验证码。 | `mobile*` |

### Comment（7）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/comment/album` | 获取专辑评论。 | `id*`, `page`, `pagesize` |
| GET | `/comment/count` | 获取评论数。(完全没用，用id拿评论也能拿到评论数) | `hash*`, `special_id*` |
| GET | `/comment/floor` | 楼层评论。 | `special_id*`, `tid*`, `mixsongid*`, `resource_type`, `page`, `pagesize`, `show_classify`, `show_hotword_list`, `code` |
| GET | `/comment/music` | 获取歌曲评论。 | `mixsongid*`, `page`, `pagesize` |
| GET | `/comment/music/classify` | 歌曲评论 - 根据分类返回。 | `mixsongid*`, `type_id*`, `page`, `pagesize`, `sort` |
| GET | `/comment/music/hotword` | 歌曲评论 - 根据热词返回。 | `mixsongid*`, `hot_word*`, `page`, `pagesize` |
| GET | `/comment/playlist` | 获取歌单评论。 | `id*`, `page`, `pagesize` |

### Discovery（14）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/ai/recommend` | AI 推荐。 | `album_audio_id*` |
| GET | `/brush` | 刷刷。 | `song_pool_id`, `mode` |
| POST | `/everyday/history` | 历史推荐。 | `mode`, `platform`, `history_name`, `date` |
| GET | `/pc/diantai` | banner。 | - |
| GET | `/personal/fm` | 获取私人FM推荐 / 上报电台播放行为 (为什么这个接口这么麻烦酷) | `hash`, `songid`, `playtime`, `action`, `mode`, `songPoolId`, `isOverplay`, `remainSongCnt` |
| GET | `/recommend/songs` | 获取每日推荐歌曲。 | - |
| GET | `/top/album` | 新碟上架。 | `page`, `pagesize` |
| GET | `/top/card` | 歌曲推荐。 | `card_id` |
| GET | `/top/ip` | 编辑精选。 | - |
| GET | `/top/playlist` | 歌单推荐 | `category_id`, `page` |
| GET | `/top/song` | 新歌速递 | `type`, `page` |
| GET | `/yueku` | 乐库。 | - |
| GET | `/yueku/banner` | 乐库 banner。 | - |
| GET | `/yueku/fm` | 乐库电台。 | - |

### ExternalPlaylist（1）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| POST | `/playlist/external/parse` | 解析网易云 / QQ 音乐歌单分享链接，返回歌单名和歌曲名称列表。 | - |

### Fm（4）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/fm/class` | 电台。（会返回所有电台数据，返回的json特别大，不建议使用） | - |
| GET | `/fm/image` | 电台 - 图片。 | `fmid*` |
| GET | `/fm/recommend` | 电台 - 推荐。 | - |
| GET | `/fm/songs` | 电台 - 音乐列表。 | `fmid*`, `type`, `offset`, `size` |

### Login（5）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| POST | `/login/cellphone` | 登录。 | - |
| POST | `/login/logout` | 退出登录。 | - |
| GET | `/login/qr/check` | 二维码登录 - 二维码检测扫码状态接口。 | `key*` |
| GET | `/login/qr/key` | 二维码登录 - 二维码 key 生成接口。 | - |
| POST | `/login/token` | 刷新登录。 | - |

### Lyric（2）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/lyric` | 获取歌词。 | `id*`, `accesskey*`, `fmt`, `decode` |
| GET | `/search/lyric` | 歌词搜索。 | `hash`, `album_audio_id`, `keywords`, `man` |

### MediaCatalog（25）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/ip` | 编辑精选数据。 | `id*`, `type`, `page`, `pagesize` |
| GET | `/ip/detail` | 编辑精选详情。 | `id*` |
| GET | `/ip/playlist` | 编辑精选歌单。 | `id*`, `page`, `pagesize` |
| GET | `/ip/zone` | 编辑精选专区。 | - |
| GET | `/ip/zone/home` | 编辑精选专区详情。 | `id*` |
| GET | `/longaudio/album/audios` | 听书 - 专辑音乐列表。 | `album_id*`, `page`, `pagesize` |
| GET | `/longaudio/album/detail` | 听书 - 专辑详情。 | `album_id*` |
| GET | `/longaudio/daily/recommend` | 听书 - 每日推荐。 | `page`, `pagesize` |
| GET | `/longaudio/rank/recommend` | 听书 - 排行榜推荐。 | - |
| GET | `/longaudio/vip/recommend` | 听书 - VIP 推荐。 | - |
| GET | `/longaudio/week/recommend` | 听书 - 每周推荐。 | - |
| GET | `/scene/audio/list` | 获取场景音乐音乐列表。 | `id*`, `module_id*`, `tag*`, `page`, `pagesize` |
| GET | `/scene/collection/list` | 获取场景音乐歌单列表。 | `tag_id*`, `page`, `pagesize` |
| GET | `/scene/lists` | 场景音乐列表。 | - |
| GET | `/scene/lists/v2` | 获取场景音乐讨论区。 | `id*`, `page`, `pagesize`, `sort` |
| GET | `/scene/module` | 场景音乐详情。 | `id*` |
| GET | `/scene/module/info` | 获取场景音乐模块 Tag。 | `id*`, `module_id*` |
| GET | `/scene/music` | 场景音乐资源列表。 | `id`, `page`, `pagesize` |
| GET | `/scene/video/list` | 获取场景音乐视频列表。 | `tag_id*`, `page`, `pagesize` |
| GET | `/theme/music` | 获取主题音乐。 | `ids*` |
| GET | `/theme/music/detail` | 获取主题音乐详情。 | `id*` |
| GET | `/theme/playlist` | 主题歌单。 | - |
| GET | `/theme/playlist/track` | 获取主题歌单所有歌曲。 | `theme_id*` |
| GET | `/video/detail` | 获取视频详情。 | `id*` |
| GET | `/video/url` | 获取视频 URL。 | `hash*` |

### PlayList（16）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| POST | `/playlist/add` | 收藏歌单。 | `name*`, `list_create_gid*` |
| POST | `/playlist/create` | 新建歌单。 | `name*`, `type` |
| POST | `/playlist/del` | 取消收藏 / 删除歌单。 | `listid*` |
| GET | `/playlist/detail` | 获取歌单详情。 | `ids*` |
| GET | `/playlist/effect` | 音效歌单。 | `page`, `pagesize` |
| GET | `/playlist/similar` | 相似歌单。 | `ids*` |
| GET | `/playlist/tags` | 获取歌单标签分类。 | - |
| GET | `/playlist/track/all` | 获取歌单全部歌曲。 | `id*`, `page`, `pagesize` |
| GET | `/playlist/track/all/new` | - | `listid*`, `page`, `pagesize` |
| POST | `/playlist/tracks/add` | 对歌单添加歌曲 | - |
| POST | `/playlist/tracks/del` | 对歌单删除歌曲 | `listid*`, `fileids*` |
| GET | `/sheet/collection` | 推荐曲谱。 | `position` |
| GET | `/sheet/collection/detail` | 曲谱合集详情。 | `collection_id*`, `page` |
| GET | `/sheet/detail` | 曲谱详情。 | `id*`, `source*` |
| GET | `/sheet/hot` | 曲谱合集。 | `opern_type` |
| GET | `/sheet/list` | 歌曲曲谱。 | `album_audio_id*`, `opern_type`, `page`, `pagesize` |

### Rank（3）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/rank/audio` | 获取榜单歌曲 | `rankid*`, `page`, `pagesize` |
| GET | `/rank/info` | 排行榜信息。 | `rankid*`, `rank_cid`, `album_img`, `zone` |
| GET | `/rank/list` | 获取所有榜单 | `withsong` |

### Register（1）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/register/dev` | 初始化设备标识。 | - |

### Report（3）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| POST | `/lastest/songs/listen` | 获取继续播放信息（对应手机版首页显示继续播放入口）。 | `pagesize` |
| POST | `/listen/timeadd` | 累加听歌时长。 | - |
| POST | `/playhistory/upload` | 提交听歌历史。(没什么用，历史记录存本地比较好) | `mxid`, `time`, `pc` |

### Search（8）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/search` | 搜索。 | `keywords*`, `page`, `pagesize`, `type` |
| GET | `/search/album` | 搜索专辑。 | `keywords*`, `page` |
| GET | `/search/complex` | 综合搜索。 | `keywords*`, `page`, `pagesize` |
| GET | `/search/default` | 默认搜索关键词。 | - |
| GET | `/search/hot` | 热搜列表。 | - |
| GET | `/search/mixed` | 综合搜索。 | `keyword*` |
| GET | `/search/special` | 搜索歌单。 | `keywords*`, `page` |
| GET | `/search/suggest` | 搜索建议。 | `keywords*`, `albumTipCount`, `correctTipCount`, `mvTipCount`, `musicTipCount` |

### Song（14）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/audio` | 获取音乐相关信息。 | `hash*` |
| GET | `/audio/accompany/matching` | 获取音乐伴奏信息。 | `hash*`, `fileName*`, `mixId*` |
| GET | `/audio/ktv/total` | 获取音乐 K 歌数量。 | `songId*`, `songHash*`, `singerName*` |
| POST | `/audio/match` | 听歌识曲。使用 multipart/form-data 上传原始 PCM 音频文件。 | - |
| GET | `/audio/related` | 获取更多音乐版本。 | `album_audio_id*`, `page`, `pagesize`, `sort`, `type`, `show_type`, `show_detail` |
| GET | `/images` | 获取歌手和专辑图片。 | `hash*`, `album_id`, `album_audio_id`, `count` |
| GET | `/images/audio` | 获取歌曲图片。 | `hash*`, `audio_id`, `album_audio_id`, `filename`, `count` |
| GET | `/kmr/audio` | 获取音乐专辑/歌手信息。 | `album_audio_id*`, `fields` |
| GET | `/kmr/audio/mv` | 获取歌曲 MV。 | `album_audio_id*`, `fields` |
| GET | `/privilege/lite` | 获取音乐详情。 | `hash*`, `album_id` |
| GET | `/song/climax` | 获取歌曲高潮部分。 | `hash*` |
| GET | `/song/ranking` | 歌曲详情 - 歌曲成绩单。 | `album_audio_id*` |
| GET | `/song/ranking/filter` | 歌曲详情 - 歌曲成绩单详情。 | `album_audio_id*`, `page`, `pagesize` |
| GET | `/song/url` | 获取歌曲播放地址。 | `hash*`, `quality`, `album_id`, `album_audio_id`, `free_part` |

### User（13）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/favorite/count` | 歌曲收藏数。 | `mixsongids*` |
| POST | `/server/now` | 获取服务器时间。 | - |
| GET | `/user/cloud` | 获取用户云盘。 | `page`, `pagesize` |
| GET | `/user/cloud/url` | 获取用户云盘音乐 URL。 | `hash*`, `album_audio_id`, `audio_id`, `name` |
| GET | `/user/detail` | 获取当前登录用户详情。 | - |
| GET | `/user/follow` | 获取用户关注歌手。 | - |
| GET | `/user/follow/message` | 获取关注歌手消息。 | `id*`, `pagesize` |
| GET | `/user/history` | 获取用户最近听歌历史。 | - |
| GET | `/user/listen` | 获取用户听歌历史排行。 | - |
| GET | `/user/playlist` | 分页获取当前登录用户歌单。 | `page`, `pagesize` |
| GET | `/user/video/collect` | 获取用户收藏的视频。 | `page`, `pagesize` |
| GET | `/user/video/love` | 获取用户喜欢的视频。 | `pagesize` |
| GET | `/user/vip/detail` | 获取当前登录用户 VIP 信息。 | - |

### Youth（16）

| Method | Path | 说明 | 参数 |
|---|---|---|---|
| GET | `/youth/channel/all` | 频道 - 获取用户所有频道。 | `page`, `pagesize` |
| GET | `/youth/channel/amway` | 频道 - 频道安利。 | `global_collection_id*` |
| POST | `/youth/channel/detail` | 频道 - 详情。 | `global_collection_id*` |
| POST | `/youth/channel/similar` | 频道 - 相似频道。 | `channel_id*` |
| GET | `/youth/channel/song` | 频道 - 音乐故事。 | `global_collection_id*`, `page`, `pagesize` |
| GET | `/youth/channel/song/detail` | 频道 - 音乐故事详情。 | `global_collection_id*`, `fileid*` |
| POST | `/youth/channel/sub` | 频道 - 订阅。 | `global_collection_id*`, `t` |
| GET | `/youth/day/vip` | 领取当天 VIP，不可多领。 | - |
| GET | `/youth/day/vip/upgrade` | 升级到概念版VIP。 | - |
| GET | `/youth/dynamic` | 动态。 | - |
| GET | `/youth/dynamic/recent` | 动态 - 最常访问。 | - |
| POST | `/youth/listen/song` | - | `mixsongid` |
| GET | `/youth/month/vip/record` | 获取VIP 领取记录。 | - |
| GET | `/youth/union/vip` | - | - |
| GET | `/youth/user/song` | 获取用户公开的音乐。 | `userid*`, `page`, `pagesize`, `type` |
| POST | `/youth/vip` | 领取 VIP。 | - |

## 端点全量索引（按路径排序）

| Path | Method | Tag | 说明 |
|---|---|---|---|
| `/ai/recommend` | GET | Discovery | AI 推荐。 |
| `/album` | GET | Album | 专辑信息。 |
| `/album/detail` | GET | Album | 专辑详情。 |
| `/album/shop` | GET | Album | 新碟上架。 |
| `/album/songs` | GET | Album | 获取专辑歌曲列表。 |
| `/artist/albums` | GET | Artist | 获取歌手专辑。 |
| `/artist/audios` | GET | Artist | 获取歌手歌曲。 |
| `/artist/detail` | GET | Artist | 获取歌手详情。 |
| `/artist/follow` | POST | Artist | 关注歌手。 |
| `/artist/follow/newsongs` | POST | Artist | 获取关注歌手新歌。 |
| `/artist/honour` | POST | Artist | 歌手荣誉。 |
| `/artist/lists` | GET | Artist | 获取歌手列表。 |
| `/artist/unfollow` | POST | Artist | 取消关注歌手。 |
| `/artist/videos` | GET | Artist | 获取歌手MV。 |
| `/audio` | GET | Song | 获取音乐相关信息。 |
| `/audio/accompany/matching` | GET | Song | 获取音乐伴奏信息。 |
| `/audio/ktv/total` | GET | Song | 获取音乐 K 歌数量。 |
| `/audio/match` | POST | Song | 听歌识曲。使用 multipart/form-data 上传原始 PCM 音频文件。 |
| `/audio/related` | GET | Song | 获取更多音乐版本。 |
| `/brush` | GET | Discovery | 刷刷。 |
| `/captcha/sent` | POST | Captcha | 发送验证码。 |
| `/comment/album` | GET | Comment | 获取专辑评论。 |
| `/comment/count` | GET | Comment | 获取评论数。(完全没用，用id拿评论也能拿到评论数) |
| `/comment/floor` | GET | Comment | 楼层评论。 |
| `/comment/music` | GET | Comment | 获取歌曲评论。 |
| `/comment/music/classify` | GET | Comment | 歌曲评论 - 根据分类返回。 |
| `/comment/music/hotword` | GET | Comment | 歌曲评论 - 根据热词返回。 |
| `/comment/playlist` | GET | Comment | 获取歌单评论。 |
| `/everyday/history` | POST | Discovery | 历史推荐。 |
| `/favorite/count` | GET | User | 歌曲收藏数。 |
| `/fm/class` | GET | Fm | 电台。（会返回所有电台数据，返回的json特别大，不建议使用） |
| `/fm/image` | GET | Fm | 电台 - 图片。 |
| `/fm/recommend` | GET | Fm | 电台 - 推荐。 |
| `/fm/songs` | GET | Fm | 电台 - 音乐列表。 |
| `/images` | GET | Song | 获取歌手和专辑图片。 |
| `/images/audio` | GET | Song | 获取歌曲图片。 |
| `/ip` | GET | MediaCatalog | 编辑精选数据。 |
| `/ip/detail` | GET | MediaCatalog | 编辑精选详情。 |
| `/ip/playlist` | GET | MediaCatalog | 编辑精选歌单。 |
| `/ip/zone` | GET | MediaCatalog | 编辑精选专区。 |
| `/ip/zone/home` | GET | MediaCatalog | 编辑精选专区详情。 |
| `/kmr/audio` | GET | Song | 获取音乐专辑/歌手信息。 |
| `/kmr/audio/mv` | GET | Song | 获取歌曲 MV。 |
| `/lastest/songs/listen` | POST | Report | 获取继续播放信息（对应手机版首页显示继续播放入口）。 |
| `/listen/timeadd` | POST | Report | 累加听歌时长。 |
| `/login/cellphone` | POST | Login | 登录。 |
| `/login/logout` | POST | Login | 退出登录。 |
| `/login/qr/check` | GET | Login | 二维码登录 - 二维码检测扫码状态接口。 |
| `/login/qr/key` | GET | Login | 二维码登录 - 二维码 key 生成接口。 |
| `/login/token` | POST | Login | 刷新登录。 |
| `/longaudio/album/audios` | GET | MediaCatalog | 听书 - 专辑音乐列表。 |
| `/longaudio/album/detail` | GET | MediaCatalog | 听书 - 专辑详情。 |
| `/longaudio/daily/recommend` | GET | MediaCatalog | 听书 - 每日推荐。 |
| `/longaudio/rank/recommend` | GET | MediaCatalog | 听书 - 排行榜推荐。 |
| `/longaudio/vip/recommend` | GET | MediaCatalog | 听书 - VIP 推荐。 |
| `/longaudio/week/recommend` | GET | MediaCatalog | 听书 - 每周推荐。 |
| `/lyric` | GET | Lyric | 获取歌词。 |
| `/mobile/app/versions` | GET | ApplicationInfo | 获取所有版本信息，可按平台过滤。 |
| `/mobile/app/versions/latest` | GET | ApplicationInfo | 获取指定平台的最新版本信息。 |
| `/pc/diantai` | GET | Discovery | banner。 |
| `/personal/fm` | GET | Discovery | 获取私人FM推荐 / 上报电台播放行为 (为什么这个接口这么麻烦酷) |
| `/playhistory/upload` | POST | Report | 提交听歌历史。(没什么用，历史记录存本地比较好) |
| `/playlist/add` | POST | PlayList | 收藏歌单。 |
| `/playlist/create` | POST | PlayList | 新建歌单。 |
| `/playlist/del` | POST | PlayList | 取消收藏 / 删除歌单。 |
| `/playlist/detail` | GET | PlayList | 获取歌单详情。 |
| `/playlist/effect` | GET | PlayList | 音效歌单。 |
| `/playlist/external/parse` | POST | ExternalPlaylist | 解析网易云 / QQ 音乐歌单分享链接，返回歌单名和歌曲名称列表。 |
| `/playlist/similar` | GET | PlayList | 相似歌单。 |
| `/playlist/tags` | GET | PlayList | 获取歌单标签分类。 |
| `/playlist/track/all` | GET | PlayList | 获取歌单全部歌曲。 |
| `/playlist/track/all/new` | GET | PlayList | - |
| `/playlist/tracks/add` | POST | PlayList | 对歌单添加歌曲 |
| `/playlist/tracks/del` | POST | PlayList | 对歌单删除歌曲 |
| `/privilege/lite` | GET | Song | 获取音乐详情。 |
| `/rank/audio` | GET | Rank | 获取榜单歌曲 |
| `/rank/info` | GET | Rank | 排行榜信息。 |
| `/rank/list` | GET | Rank | 获取所有榜单 |
| `/recommend/songs` | GET | Discovery | 获取每日推荐歌曲。 |
| `/register/dev` | GET | Register | 初始化设备标识。 |
| `/scene/audio/list` | GET | MediaCatalog | 获取场景音乐音乐列表。 |
| `/scene/collection/list` | GET | MediaCatalog | 获取场景音乐歌单列表。 |
| `/scene/lists` | GET | MediaCatalog | 场景音乐列表。 |
| `/scene/lists/v2` | GET | MediaCatalog | 获取场景音乐讨论区。 |
| `/scene/module` | GET | MediaCatalog | 场景音乐详情。 |
| `/scene/module/info` | GET | MediaCatalog | 获取场景音乐模块 Tag。 |
| `/scene/music` | GET | MediaCatalog | 场景音乐资源列表。 |
| `/scene/video/list` | GET | MediaCatalog | 获取场景音乐视频列表。 |
| `/search` | GET | Search | 搜索。 |
| `/search/album` | GET | Search | 搜索专辑。 |
| `/search/complex` | GET | Search | 综合搜索。 |
| `/search/default` | GET | Search | 默认搜索关键词。 |
| `/search/hot` | GET | Search | 热搜列表。 |
| `/search/lyric` | GET | Lyric | 歌词搜索。 |
| `/search/mixed` | GET | Search | 综合搜索。 |
| `/search/special` | GET | Search | 搜索歌单。 |
| `/search/suggest` | GET | Search | 搜索建议。 |
| `/server/now` | POST | User | 获取服务器时间。 |
| `/sheet/collection` | GET | PlayList | 推荐曲谱。 |
| `/sheet/collection/detail` | GET | PlayList | 曲谱合集详情。 |
| `/sheet/detail` | GET | PlayList | 曲谱详情。 |
| `/sheet/hot` | GET | PlayList | 曲谱合集。 |
| `/sheet/list` | GET | PlayList | 歌曲曲谱。 |
| `/singer/list` | GET | Artist | 获取歌手列表。 |
| `/song/climax` | GET | Song | 获取歌曲高潮部分。 |
| `/song/ranking` | GET | Song | 歌曲详情 - 歌曲成绩单。 |
| `/song/ranking/filter` | GET | Song | 歌曲详情 - 歌曲成绩单详情。 |
| `/song/url` | GET | Song | 获取歌曲播放地址。 |
| `/theme/music` | GET | MediaCatalog | 获取主题音乐。 |
| `/theme/music/detail` | GET | MediaCatalog | 获取主题音乐详情。 |
| `/theme/playlist` | GET | MediaCatalog | 主题歌单。 |
| `/theme/playlist/track` | GET | MediaCatalog | 获取主题歌单所有歌曲。 |
| `/top/album` | GET | Discovery | 新碟上架。 |
| `/top/card` | GET | Discovery | 歌曲推荐。 |
| `/top/ip` | GET | Discovery | 编辑精选。 |
| `/top/playlist` | GET | Discovery | 歌单推荐 |
| `/top/song` | GET | Discovery | 新歌速递 |
| `/user/cloud` | GET | User | 获取用户云盘。 |
| `/user/cloud/url` | GET | User | 获取用户云盘音乐 URL。 |
| `/user/detail` | GET | User | 获取当前登录用户详情。 |
| `/user/follow` | GET | User | 获取用户关注歌手。 |
| `/user/follow/message` | GET | User | 获取关注歌手消息。 |
| `/user/history` | GET | User | 获取用户最近听歌历史。 |
| `/user/listen` | GET | User | 获取用户听歌历史排行。 |
| `/user/playlist` | GET | User | 分页获取当前登录用户歌单。 |
| `/user/video/collect` | GET | User | 获取用户收藏的视频。 |
| `/user/video/love` | GET | User | 获取用户喜欢的视频。 |
| `/user/vip/detail` | GET | User | 获取当前登录用户 VIP 信息。 |
| `/video/detail` | GET | MediaCatalog | 获取视频详情。 |
| `/video/url` | GET | MediaCatalog | 获取视频 URL。 |
| `/youth/channel/all` | GET | Youth | 频道 - 获取用户所有频道。 |
| `/youth/channel/amway` | GET | Youth | 频道 - 频道安利。 |
| `/youth/channel/detail` | POST | Youth | 频道 - 详情。 |
| `/youth/channel/similar` | POST | Youth | 频道 - 相似频道。 |
| `/youth/channel/song` | GET | Youth | 频道 - 音乐故事。 |
| `/youth/channel/song/detail` | GET | Youth | 频道 - 音乐故事详情。 |
| `/youth/channel/sub` | POST | Youth | 频道 - 订阅。 |
| `/youth/day/vip` | GET | Youth | 领取当天 VIP，不可多领。 |
| `/youth/day/vip/upgrade` | GET | Youth | 升级到概念版VIP。 |
| `/youth/dynamic` | GET | Youth | 动态。 |
| `/youth/dynamic/recent` | GET | Youth | 动态 - 最常访问。 |
| `/youth/listen/song` | POST | Youth | - |
| `/youth/month/vip/record` | GET | Youth | 获取VIP 领取记录。 |
| `/youth/union/vip` | GET | Youth | - |
| `/youth/user/song` | GET | Youth | 获取用户公开的音乐。 |
| `/youth/vip` | POST | Youth | 领取 VIP。 |
| `/yueku` | GET | Discovery | 乐库。 |
| `/yueku/banner` | GET | Discovery | 乐库 banner。 |
| `/yueku/fm` | GET | Discovery | 乐库电台。 |
