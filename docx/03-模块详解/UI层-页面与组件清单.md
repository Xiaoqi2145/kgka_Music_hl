# UI 层 · 页面与组件清单

> 文档编号：KA-03-14
> 级别：L2 📖
> 状态：现行
> 关联代码：lib/ui/pages/（20 个文件）、lib/ui/widgets/（14 个文件）、lib/ui/adaptive_layout.dart、lib/ui/app_theme.dart
> 最近更新：2026-09-21
> 变更触发条件：新增/删除/重命名页面或组件、单个文件行数变化超过 30%、导航入口或出口变化、巨型文件拆分时

---

## 1. 一句话结论（TL;DR）

UI 层共 **36 个 Dart 文件 / 19471 行**（非空口径），占 `lib/` 的约 64.8%；其中 `player_page.dart`（3298 行）、`home_page.dart`（1712 行）、`playlist_detail_page.dart`（1651 行）三个文件合计 6661 行，**占 UI 层的 34.2%**，是架构解耦的首要目标。全部页面中仅 `SettingsPage` 与 `AudioInterruptionSettingsPage` 是 `StatelessWidget`，导航全部使用 `Navigator 1.0` 的 `MaterialPageRoute`，无命名路由。

> **行数口径**：本文档采用**非空行**口径（统计时排除纯空白行）。`../01-项目总览/目录结构与文件地图.md` 采用 **LF 含空行**口径，两者不可直接比较。`player_page.dart` 按非空口径为 3298 行，其 **LF 总行数为 3544 行**；§5 结构树中的「行区间」是文件真实行号，与本节口径无关。

---

## 2. 现状（统计概览）

| 分组 | 文件数 | 行数 | 占比（占 UI 层） |
|---|---|---|---|
| `lib/ui/pages/` | 20 | 16481 | 84.6% |
| `lib/ui/widgets/` | 14 | 2726 | 14.0% |
| `lib/ui/adaptive_layout.dart` | 1 | 76 | 0.4% |
| `lib/ui/app_theme.dart` | 1 | 188 | 1.0% |
| **合计** | **36** | **19471** | 100% |

三个巨型文件（`player_page.dart` 3298 + `home_page.dart` 1712 + `playlist_detail_page.dart` 1651 = 6661）单独占 UI 层的 34.2%。

---

## 3. 设计说明 · 页面清单

### 3.1 页面基本信息

| 文件（`lib/ui/pages/`） | 行数 | 公开类 | 类型 | 主要职责 |
|---|---|---|---|---|
| `player_page.dart` | 3298 | `PlayerPage` | Stateful | 播放页：竖屏封面/歌词双页 + 横屏布局、逐字歌词、队列面板、歌词候选预览 |
| `home_page.dart` | 1712 | `HomePage` | Stateful | 首页：推荐（每日推荐 + 精选歌单）与电台两个 Tab，含搜索入口 |
| `playlist_detail_page.dart` | 1651 | `PlaylistDetailPage` | Stateful | 歌单/专辑详情：分页加载、搜索、排序、收藏/删除、后台队列扩展 |
| `library_page.dart` | 1189 | `LibraryPage` | Stateful | 我的：账号行、快捷卡（我喜欢/云盘/已下载/本地/历史）、歌单三 Tab（创建/收藏/专辑）+ 多选删除 |
| `settings_page.dart` | 1179 | `SettingsPage` | **Stateless** | 设置总入口：账号/播放/本地/网络/缓存/个性化/应用七组，含缓存管理 BottomSheet |
| `login_page.dart` | 1177 | `LoginPage` | Stateful | 登录：手机号验证码 + 扫码两个 Tab、多账号选择、API 地址设置 |
| `search_page.dart` | 967 | `SearchPage` | Stateful | 搜索：酷狗单源、搜索联想、热搜榜、搜索历史 |
| `cloud_drive_page.dart` | 737 | `CloudDrivePage` | Stateful | 云盘音乐：容量条、分页列表、操作 |
| `artist_detail_page.dart` | 697 | `ArtistDetailPage` | Stateful | 歌手详情：头图、简介、歌曲分页加载 |
| `personalization_settings_page.dart` | 609 | `PersonalizationSettingsPage` | Stateful | 个性化：8 预设色、背景图选择/透明度/预览/移除 |
| `about_page.dart` | 579 | `AboutPage` | Stateful | 关于：版本卡、更新日志解析（`update.md`）、检查更新、仓库链接 |
| `playback_history_page.dart` | 410 | `PlaybackHistoryPage` | Stateful | 播放历史（上限 500 条）、清空、跳歌手 |
| `downloaded_songs_page.dart` | 398 | `DownloadedSongsPage` | Stateful | 已下载 / 播放缓存两个 Tab |
| `playback_stats_page.dart` | 375 | `PlaybackStatsPage` | Stateful | 播放统计：累计次数、时长、Top 10 歌手/歌曲 |
| `desktop_lyrics_settings_page.dart` | 374 | `DesktopLyricsSettingsPage` | Stateful | 桌面歌词设置：透明度、字号、文字/背景色、行为项 |
| `local_songs_page.dart` | 373 | `LocalSongsPage` | Stateful | 本地音乐：目录选择/清除、检索、重新扫描、列表播放 |
| `comment_page.dart` | 234 | `CommentPage` | Stateful | 歌曲评论分页列表 |
| `app_shell.dart` | 208 | `AppShell` | Stateful | 根壳：首页/我的双 Tab（`BottomNavigationBar` 或 `NavigationRail`）+ 悬浮 MiniPlayer |
| `album_shop_page.dart` | 205 | `AlbumShopPage` | Stateful | 新碟上架网格 + 滚动加载更多 |
| `audio_interruption_settings_page.dart` | 109 | `AudioInterruptionSettingsPage` | **Stateless** | 后台打断机制：阻止打断 + 自动恢复两个开关 |

### 3.2 页面依赖与导航

| 页面 | 依赖的控制器 / 服务 | 导航入口 | 导航出口 |
|---|---|---|---|
| `AppShell` | `MusicApi`、`AuthController`、`PlayerController`、`CacheService`、`DownloadController`、`ThemeController`、`LocalMusicController` | `main.dart:165`（登录后） | `HomePage`、`LibraryPage`（`IndexedStack`，:80）；Android 返回键 → `MethodChannel('kgka_music_hl/screen').moveTaskToBack`（:201-208） |
| `HomePage` | `MusicApi`、`AuthController`、`PlayerController`、`CacheService` | `app_shell.dart:53` | `SearchPage`（:488）、`ArtistDetailPage`（:197）、`AlbumShopPage`（:210）、`PlaylistDetailPage`（`openPlaylistDetail` :175） |
| `LibraryPage` | `MusicApi`、`AuthController`、`PlayerController`、`DownloadController`、`ThemeController`、`LocalMusicController` | `app_shell.dart:59` | `SettingsPage`（:70）、`DownloadedSongsPage`（:196）、`CloudDrivePage`（:206）、`LocalSongsPage`（:371）、`PlaybackHistoryPage`（:388）、`PlaylistDetailPage`（:57） |
| `LoginPage` | `AuthController`、`MusicApi`、`AppConfig` | `main.dart:193`（`!isRestoring && !isLoggedIn`） | 无（登录成功由 `AuthController` 通知，`main.dart` 自动切到 `AppShell`） |
| `SettingsPage` | `MusicApi`、`AuthController`、`PlayerController`、`ThemeController`、`LocalMusicController`、`CacheService?`、`DownloadController?`、`AppUpdateService`、`ArtworkCacheService` | `library_page.dart:70` | `PlaybackStatsPage`（:177）、`PlaybackHistoryPage`（:189）、`AudioInterruptionSettingsPage`（:205）、`DesktopLyricsSettingsPage`（:243）、`PersonalizationSettingsPage`（:311）、`AboutPage`（:348）、`AudioEffectsPage`（经 `showAudioEffectsSheet`） |
| `PersonalizationSettingsPage` | `ThemeController` | `settings_page.dart:311` | `_FullBackgroundPreview`（:147，`fullscreenDialog: true`） |
| `PlayerPage` | `PlayerController`、`AuthController`、`ThemeController.instance`、`MethodChannel('kgka_music_hl/screen')`、`SharedPreferences`（歌词字号） | `mini_player.dart:65` | `DesktopLyricsSettingsPage`（:352）、`ArtistDetailPage`（:618）、`_LyricCandidatePreviewPage`（:2032）、`CommentPage`（:3491） |
| `PlaylistDetailPage` | `MusicApi`、`AuthController`、`PlayerController`、自建 `CacheService()`（:119） | `openPlaylistDetail`（:26）——竖屏 `push` 整页；横屏 `showGeneralDialog` 右侧面板（宽度 `62%`，clamp 420~820）；`importPlaylistById`（:781） | `ArtistDetailPage`（:669） |
| `AlbumShopPage` | `MusicApi`、`AuthController`、`PlayerController` | `home_page.dart:210` | `PlaylistDetailPage`（:81，构造临时 `PlaylistSummary`） |
| `ArtistDetailPage` | `MusicApi`、`AuthController`、`PlayerController` | `home_page.dart:244`、`player_page.dart:624`、`playlist_detail_page.dart:700`、`playback_history_page.dart:82`、`cloud_drive_page.dart:142`、`search_page.dart:182` | 无 |
| `SearchPage` | `MusicApi`、`AuthController`、`PlayerController`、`SearchHistoryService` | `home_page.dart:488` | `ArtistDetailPage`（:182） |
| `CommentPage` | `MusicApi`、`mixsongid` 参数 | `player_page.dart:3491`（`song.albumAudioId ?? song.id`） | 无 |
| `CloudDrivePage` | `MusicApi`、`AuthController`、`PlayerController` | `library_page.dart:206` | `ArtistDetailPage`（:142） |
| `DownloadedSongsPage` | `MusicApi`、`AuthController`、`PlayerController`、`DownloadController` | `library_page.dart:196` | 无 |
| `LocalSongsPage` | `PlayerController`、`LocalMusicController`、`file_picker` | `library_page.dart:371` | 无 |
| `PlaybackHistoryPage` | `MusicApi`、`AuthController`、`PlayerController` | `settings_page.dart:189`、`library_page.dart:388` | `ArtistDetailPage`（:82） |
| `PlaybackStatsPage` | `PlayerController`（`getPlaybackStats` / `clearPlaybackStats`） | `settings_page.dart:177` | 无 |
| `AudioInterruptionSettingsPage` | `PlayerController` | `settings_page.dart:205` | 无 |
| `DesktopLyricsSettingsPage` | `PlayerController`、`DesktopLyricsSettings`（来自 `DesktopLyricsService`） | `settings_page.dart:243`、`player_page.dart:352` | 无 |
| `AboutPage` | `MusicApi`、`AppUpdateService`、资源 `update.md`、`url_launcher` | `settings_page.dart:348` | 外部浏览器（GitHub 仓库，:15-17、:51-59） |

### 3.3 页面内私有枚举

| 枚举 | 值 | 所在文件 | 锚点 |
|---|---|---|---|
| `_SongSortMode` | `defaultOrder`、`byTitle`、`byArtist`、`byAlbum` | `playlist_detail_page.dart` | :1692 |
| `_PlaylistSortMode` | `defaultOrder`、`byName`、`bySongCount`、`byCreatedTime` | `library_page.dart` | :595 |
| `ToastType`（公开） | `info`、`success`、`error` | `widgets/toast.dart` | :6 |

---

## 4. 设计说明 · 组件清单

| 文件（`lib/ui/widgets/`） | 行数 | 公开 API | 用途 | 复用位置 |
|---|---|---|---|---|
| `mini_player.dart` | 520 | `MiniPlayer` | 悬浮迷你播放器 + 队列面板（竖屏 BottomSheet / 横屏右侧 `showGeneralDialog`） | `app_shell.dart:86`；内联于 `album_shop_page.dart`、`artist_detail_page.dart`、`cloud_drive_page.dart`、`playback_history_page.dart`、`search_page.dart`、`playlist_detail_page.dart` |
| `audio_effects_sheet.dart` | 500 | `showAudioEffectsSheet()`、`AudioEffectsPage` | 音效页：均衡器多段、低音增强、曲线绘制 | `settings_page.dart:164`、`player_page.dart:311` |
| `app_update_widgets.dart` | 340 | `AppUpdateBanner`、`showAppUpdateDialog()` | 更新提示横幅与更新对话框（含轻量 Markdown 渲染） | 当前无实例化点（见 TD-55） |
| `song_action_sheets.dart` | 315 | `SongSheetAction`、`showSongActionSheet()`、`showAddToPlaylistSheet()`、`addSongToQueueWithFeedback()` | 歌曲操作面板（宫格 + 列表两种形态）、添加到歌单、加入队列 | 首页、歌单详情、歌手详情、云盘、搜索、播放历史、播放页 |
| `sleep_timer_sheet.dart` | 229 | `showSleepTimerSheet()` | 定时播放面板（剩余时间展示、预设时长芯片） | `player_page.dart:334` |
| `toast.dart` | 213 | `Toast`、`ToastType` | 全局 Toast，挂在根 Navigator 的 Overlay，不依赖调用处 context | 全项目；`navigatorKey` 绑定在 `main.dart:142` |
| `artwork.dart` | 156 | `Artwork` | 封面组件：磁盘缓存 → `Image.file`，含 Shimmer 占位与渐变兜底 | 几乎所有列表与详情页 |
| `playback_speed_sheet.dart` | 150 | `showPlaybackSpeedSheet()` | 倍速面板（0.5x ~ 3.0x，吸附步进） | `player_page.dart:299` |
| `now_playing_badge.dart` | 99 | `NowPlayingBadge` | 正在播放的 3 柱跳动指示器（`CustomPainter`） | 本地音乐、歌单详情、歌手详情、云盘、播放历史、搜索 |
| `audio_quality_sheet.dart` | 85 | `showAudioQualitySheet()` | 音质选择面板（标准/高品/无损） | `settings_page.dart:371`、`player_page.dart:400` |
| `cached_artwork_image.dart` | 61 | `CachedArtworkImage`（`ImageProvider`） | 把 `ArtworkCacheService` 磁盘缓存包装成 `ImageProvider` | `player_page.dart` 的 `_ArtworkBackground` |
| `skeleton_box.dart` | 27 | `SkeletonBox`、`SkeletonBox.circle` | 骨架屏矩形/圆形占位块 | 首页、歌单详情、歌手详情、云盘 |
| `preparing_indicator.dart` | 26 | `PreparingIndicator` | 音源解析/替换中的加载指示器（提交前的唯一中间态反馈） | `home_page.dart:949`、`playlist_detail_page.dart:1538`、`mini_player.dart:136` |
| `music_formatters.dart` | 5 | `formatPlayCount(int?)` | 播放量格式化：`≥10000` 显示「x.x 万次播放」，null 显示「精选歌单」 | 首页、歌单详情 |

---

## 5. 设计说明 · 巨型文件内部结构与可拆分点

> 本节「行区间」为文件真实行号（与 §2 的行数口径不同）。

### 5.1 `player_page.dart`（3298 行非空，文件真实行号 1-3544）

```
PlayerPage (:31)
└─ _PlayerPageState (:41, with WidgetsBindingObserver)
   └─ TickerMode → AnimatedBuilder(player) (:122-141)
      └─ _PlayerBody (:383)                       ← 竖屏/横屏分叉点
         ├─ _ArtworkBackground (:674) → CachedArtworkImage + 模糊 + 渐变
         │  └─ _FallbackBackground (:760)
         ├─ _TopBar (:1374) → _GlassIconButton (:3446)
         ├─ 竖屏：PageView(_pageController)
         │  ├─ _PosterPlayerPage (:1477)          第 0 页
         │  │  ├─ _PosterLyricPreview (:1583) → _MarqueeSingleLine (:1730) → _LyricText (:2969)
         │  │  ├─ _CommentEntry (:3475) → CommentPage
         │  │  ├─ _Progress (:3235)
         │  │  └─ _Controls (:3318)
         │  └─ _LyricPlayerPage (:1834)           第 1 页
         │     ├─ _LyricViewport (:2396)          滚动/对齐/拉伸核心
         │     │  ├─ _LyricText (:2969)
         │     │  └─ _KaraokeLinePainter (:3117, CustomPainter)
         │     └─ _GlassIconButton ×4
         ├─ 横屏：_LandscapePlayerContent (:777)
         │  ├─ _LandscapeHeader (:848) → _LandscapeHeaderButton (:951)
         │  ├─ _LandscapeArtworkShowcase (:990)
         │  └─ _LandscapeRightPanel (:1128)
         │     ├─ _LandscapeLyricPanel (:1171) → _LandscapeLyricLine (:1303)
         │     ├─ _Progress (:3235)
         │     └─ _Controls (:3318)
         └─ _PageDots (:3517)
独立路由页：_LyricCandidatePreviewPage (:2049) → _CandidateLyricPreview (:2293) / _LyricPreviewError (:2370)
动画曲线：_LyricScrollCurve (:1561)、_LyricLineTensionCurve (:1572)
顶层函数：_playerMoreActions (:279-400)、_showAudioQualityPicker (:402-418)
```

可拆分点：

| 拆分单元 | 行区间 | 约行数 | 建议去向 |
|---|---|---|---|
| `_LyricViewport` + 滚动/对齐算法 | 2396-2968 | 573 | `lib/ui/widgets/lyrics/lyric_viewport.dart` |
| `_LyricText` + `_KaraokeLinePainter`（逐字歌词绘制） | 2969-3234 | 266 | `lib/ui/widgets/lyrics/karaoke_line.dart` |
| `_Progress` + `_Controls` + `_GlassIconButton` + `_PageDots` | 3235-3544 | 310 | `lib/ui/widgets/player/player_controls.dart` |
| `_Landscape*` 家族 | 777-1373 | 597 | `lib/ui/pages/player/player_landscape.dart` |
| `_PosterPlayerPage` + `_PosterLyricPreview` + `_MarqueeSingleLine` | 1477-1833 | 357 | `lib/ui/pages/player/player_poster.dart` |
| `_LyricPlayerPage` | 1834-2048 | 215 | `lib/ui/pages/player/player_lyrics.dart` |
| `_LyricCandidatePreviewPage` 家族 | 2049-2395 | 347 | `lib/ui/pages/player/lyric_candidate_preview.dart` |
| `_playerMoreActions`（顶层函数，构造操作面板项） | 279-400 | 122 | `lib/ui/widgets/player/player_actions.dart` |
| `_PlayerBody` 本体保留 | 383-673 | 291 | 仅保留竖/横屏分叉与页面状态 |

### 5.2 `home_page.dart`（1712 行非空，文件真实行号 1-1819）

```
HomePage (:21)
└─ _HomePageState (:39)
   └─ FutureBuilder<_HomeData> → RefreshIndicator → CustomScrollView (:229-305)
      ├─ _HomeSkeleton (:1690)
      ├─ _ErrorView (:1761)
      ├─ _RecommendHeader (:309)
      │  ├─ _TopTabs (:398)                     推荐 / 电台
      │  ├─ _SmartSearch (:475) → SearchPage
      │  └─ _FeatureShelf (:533) → _FeatureCard (:604)
      ├─ _PersistentTabPane(visible: _sectionIndex == 0) (:383)
      │  ├─ _SongSection (:701) → _HomeSongRow (:888)
      │  │  └─ _SectionHeader (:1110)
      │  └─ _PlaylistRail (:1064) → _PlaylistCard (:1136)
      └─ _PersistentTabPane(visible: _sectionIndex == 1)
         └─ _RadioSection (:1181)
            ├─ _RadioHeroCard (:1348) → _RadioPlayBadge (:1547)
            ├─ _RadioStationRail (:1436) → _RadioStationCard (:1472)
            └─ _RadioSkeleton (:1585) / _RadioEmpty (:1622) / _RadioUnsupported (:1653)
数据容器：_HomeData (:1800)、_RadioData (:1812)
静态缓存：_HomePageState._cachedData (:40)、_RadioSectionState._cachedFuture (:1192)
```

可拆分点：

| 拆分单元 | 行区间 | 约行数 | 建议去向 |
|---|---|---|---|
| `_RadioSection` 家族 | 1181-1689 | 509 | `lib/ui/widgets/home/radio_section.dart`（注意自带静态缓存 `_cachedFuture`） |
| `_RecommendHeader` 家族（含 `_TopTabs`、`_SmartSearch`、`_FeatureShelf`、`_FeatureCard`） | 309-700 | 392 | `lib/ui/widgets/home/home_header.dart` |
| `_SongSection` + `_PlaylistRail` + `_PlaylistCard` + `_SectionHeader` | 701-1180 | 480 | `lib/ui/widgets/home/home_sections.dart` |
| `_HomeSongRow` | 888-1063 | 176 | 与 `playlist_detail_page._SongRow`、`cloud_drive_page._CloudSongRow`、`artist_detail_page._ArtistSongRow` 合并为公共歌曲行组件 |
| 骨架屏与错误态 | 1690-1819 | 130 | 与各页骨架屏统一到 `lib/ui/widgets/skeletons/` |

### 5.3 `playlist_detail_page.dart`（1651 行非空，文件真实行号 1-1747）

```
openPlaylistDetail (:27)   ← 竖屏 push / 横屏 showGeneralDialog 右面板
PlaylistDetailPage (:102)
└─ _PlaylistDetailPageState (:125)
   └─ CustomScrollView
      ├─ SliverAppBar(background: _HeroHeader (:1105))
      ├─ _PlaylistDetailSkeleton (:1196) → _PlaylistSkeletonSongRow
      ├─ _DetailError (:1652)
      ├─ _Actions (:1251)            播放全部 / 随机 / 搜索 / 排序 / 更多
      ├─ _SearchEmpty (:1348)
      ├─ _SongRow (:1451)
      └─ _LoadMoreFooter (:1377)
BottomSheet 私有件：_ActionOption (:1054)、_ActionOptionTile (:1069)、_SortOptionTile (:1694)
枚举：_SongSortMode (:1692)    常量：_fullSongsCacheSuffix = '_full' (:24)
静态工厂：importPlaylistById (:793)
```

可拆分点：

| 拆分单元 | 行区间 | 约行数 | 建议去向 |
|---|---|---|---|
| `_SongRow` | 1451-1651 | 201 | 公共歌曲行组件（与 `_HomeSongRow` 等统一） |
| 骨架屏 / 错误态 / 加载页脚 | 1196-1250、1377-1450、1652-1691 | 169 | 统一到公共骨架与状态组件 |
| 排序/操作 BottomSheet 家族 | 1054-1104、1694-1747 | 105 | `lib/ui/widgets/playlist/playlist_action_sheets.dart` |
| `_Actions` | 1251-1347 | 97 | `lib/ui/widgets/playlist/playlist_actions_bar.dart` |
| `_HeroHeader` | 1105-1195 | 91 | `lib/ui/widgets/playlist/playlist_hero_header.dart` |
| `_PlaylistDetailPageState` 业务逻辑（加载、过滤、队列扩展） | 125-1053 | 929 | 可抽 `PlaylistDetailController`（当前是纯 State 内联，无法单测） |

---

## 6. 约束与坑

1. **`SettingsPage` 是 `StatelessWidget`，全部状态靠 `AnimatedBuilder(Listenable.merge([auth, player, localMusic, theme]))` 驱动**（`settings_page.dart:63`）；它自身不持有 `TabController`，因此设置页没有分段导航，只有一长列。
2. **导航全部是 `MaterialPageRoute`，无命名路由、无路由表。** 无法通过字符串统一拦截或做深链接；横屏的「右面板」是用 `showGeneralDialog` 模拟的，不是路由。
3. **页面构造参数即依赖注入。** 每个页面显式接收 `MusicApi` / 控制器实例，没有 `Provider` / `InheritedWidget`；新增依赖必须逐层透传（`main.dart` → `AppShell` → 页面）。
4. **`PlaylistDetailPage` 自建了 `CacheService()`**（`playlist_detail_page.dart:131`），而其他页面用 `AppShell.cache` 传入的实例。两者共用同一磁盘目录，但**绕过了装配点**，属于依赖注入的一致性瑕疵（TD-63）。
5. **`PlayerPage` 在 `initState` 强制放开横屏**（`player_page.dart:55`），`dispose` 再按 `ThemeController.instance.landscapeEnabled` + `AdaptiveLayout.isTabletByPlatform()` 恢复（:72-81），与 `ThemeController.applyOrientations` 是两套并行逻辑。
6. **歌曲行组件重复四份**：`_HomeSongRow`（`home_page.dart:888`）、`_SongRow`（`playlist_detail_page.dart:1561`）、`_CloudSongRow`（`cloud_drive_page.dart:417`）、`_ArtistSongRow`（`artist_detail_page.dart:453`）。四者都内联了 `NowPlayingBadge`、`Artwork`、操作面板调用，改一处需改四处。
7. **骨架屏同样重复**：`_HomeSkeleton`、`_PlaylistDetailSkeleton`、`_ArtistDetailSkeleton`、`_CloudSkeleton`、`_RadioSkeleton`、`_HotSearchSkeleton`、`_SkeletonBlock` 七个实现，仅 `SkeletonBox` 是公共件。
8. **私有类型出现在公开 API 上**：`ThemeController.presetColors`（`theme_controller.dart:32`）的元素类型 `_PresetColor`（:202）是库私有（见 `控制器层-ThemeController.md` §2.3），外部只能靠类型推断遍历。
9. **`LocalSongsPage` 与 `SettingsPage` 各自实现了一份目录选择逻辑**（`local_songs_page.dart:110` vs `settings_page.dart:541`，均为 `FilePicker.getDirectoryPath()`）。
10. **`AudioEffectsPage` 名义上是「sheet」，实际是整页路由**（`audio_effects_sheet.dart:10-12` 用 `Navigator.push` + `MaterialPageRoute`），文件命名与行为不一致（TD-58）。
11. **`music_formatters.dart` 只有 5 行**，是全项目最小的 Dart 文件；`formatPlayCount` 对 `null` 返回「精选歌单」而非空串，调用方需知道这一语义。
12. **`HomePage` 与 `_RadioSection` 用静态变量缓存数据**（`_cachedData` `home_page.dart:40` / `_cachedFuture` :1192），跨实例共享；这意味着页面重建后仍可能显示上一次会话的数据，刷新依赖 `_silentRefresh`（`home_page.dart:83-109`）。
13. **`PreparingIndicator` 是音源解析/替换期间唯一的中间态反馈**（`preparing_indicator.dart`，2026-09-10 随播放切换修复引入）。提交前「点击是否生效」只能靠它表达，改造时不要移除。

---

## 7. 待办与关联

### 7.1 待办

| 项 | 说明 | 优先级 |
|---|---|---|
| 拆分 `player_page.dart` | 按 §5.1 的 9 个单元拆出，`_PlayerBody` 只留分叉逻辑 | 高 |
| 统一歌曲行组件 | 合并 4 份 `*SongRow`，参数化「是否显示歌手/专辑/时长/操作」 | 高 |
| 统一骨架屏 | 建 `lib/ui/widgets/skeletons/` 收敛 7 个实现 | 中 |
| 抽取 `PlaylistDetailController` | 当前 929 行状态逻辑内联在 State 中，无法单测 | 中 |
| 拆分 `home_page.dart` | 优先拆 `_RadioSection`（509 行，且带静态缓存） | 中 |
| `PlaylistDetailPage` 改用注入的 `CacheService` | 去掉自建实例，保持装配点唯一 | 中 |
| 静态缓存改为实例级或显式失效 | `_cachedData` / `_cachedFuture` 的生命周期与登录态耦合 | 中 |
| 页面依赖改为 `InheritedWidget` 或轻量 DI | 缓解逐层透传；当前无框架约束 | 低 |
| 统一方向管理 | `player_page` 的方向恢复逻辑并入 `ThemeController` | 低 |
| 重命名 `audio_effects_sheet.dart` | 实际是整页，改名为 `audio_effects_page.dart` | 低 |

### 7.2 关联文档

- 分层与依赖规则：`../02-架构设计/分层架构与依赖规则.md`
- 装配点与依赖注入：`../02-架构设计/启动流程与依赖装配.md`
- `PlayerController` 的完整契约：`控制器层-PlayerController.md`
- `ThemeController` 与背景图层：`控制器层-ThemeController.md`
- `AuthController` 与登录页状态机：`控制器层-AuthController.md`
- `LocalMusicController` 与本地音乐页：`控制器层-LocalMusicController.md`
- `Artwork` / `CachedArtworkImage` 的数据来源：`服务层-缓存体系.md`
