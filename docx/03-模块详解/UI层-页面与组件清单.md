# UI 层 · 页面与组件清单

> 文档编号：KA-03-14
> 级别：L2 📖
> 状态：现行
> 关联代码：lib/ui/pages/（20 个文件）、lib/ui/widgets/（13 个文件）、lib/ui/adaptive_layout.dart、lib/ui/app_theme.dart
> 最近更新：2026-09-09
> 变更触发条件：新增/删除/重命名页面或组件、单个文件行数变化超过 30%、导航入口或出口变化、巨型文件拆分时

---

## 1. 一句话结论（TL;DR）

UI 层共 **35 个 Dart 文件 / 19306 行**，占 `lib/` 的约 65.4%；其中 `player_page.dart`（3290 行）、`home_page.dart`（1705 行）、`playlist_detail_page.dart`（1633 行）三个文件合计 6628 行，**占 UI 层的 34.3%**，是架构解耦的首要目标。全部页面中仅 `SettingsPage` 与 `AudioInterruptionSettingsPage` 是 `StatelessWidget`，导航全部使用 `Navigator 1.0` 的 `MaterialPageRoute`，无命名路由。

> **行数口径**：本文档与 `../01-项目总览/目录结构与文件地图.md`、`控制器层-PlayerController.md` 一致，采用 PowerShell `Measure-Object -Line` 口径（约等于非空行数）。`player_page.dart` 按此口径为 3290 行，其**文件总行数（含空行）为 3536 行**；§5 结构树中的「行区间」是文件真实行号，与本节口径无关。

---

## 2. 现状（统计概览）

| 分组 | 文件数 | 行数 | 占比（占 UI 层） |
|---|---|---|---|
| `lib/ui/pages/` | 20 | 16443 | 85.2% |
| `lib/ui/widgets/` | 13 | 2647 | 13.7% |
| `lib/ui/adaptive_layout.dart` | 1 | 65 | 0.3% |
| `lib/ui/app_theme.dart` | 1 | 151 | 0.8% |
| **合计** | **35** | **19306** | 100% |

三个巨型文件（`player_page.dart` 3290 + `home_page.dart` 1705 + `playlist_detail_page.dart` 1633 = 6628）单独占 UI 层的 34.3%。

---

## 3. 设计说明 · 页面清单

### 3.1 页面基本信息

| 文件（`lib/ui/pages/`） | 行数 | 公开类 | 类型 | 主要职责 |
|---|---|---|---|---|
| `player_page.dart` | 3290 | `PlayerPage` | Stateful | 播放页：竖屏封面/歌词双页 + 横屏布局、逐字歌词、队列面板、歌词候选预览 |
| `home_page.dart` | 1705 | `HomePage` | Stateful | 首页：推荐（每日推荐 + 精选歌单）与电台两个 Tab，含搜索入口 |
| `playlist_detail_page.dart` | 1633 | `PlaylistDetailPage` | Stateful | 歌单/专辑详情：分页加载、搜索、排序、收藏/删除、后台队列扩展 |
| `library_page.dart` | 1189 | `LibraryPage` | Stateful | 我的：账号行、快捷卡（我喜欢/云盘/已下载/本地/历史）、歌单三 Tab（创建/收藏/专辑）+ 多选删除 |
| `settings_page.dart` | 1182 | `SettingsPage` | **Stateless** | 设置总入口：账号/播放/本地/网络/缓存/个性化/应用七组，含缓存管理 BottomSheet |
| `login_page.dart` | 1177 | `LoginPage` | Stateful | 登录：手机号验证码 + 扫码两个 Tab、多账号选择、API 地址设置 |
| `cloud_drive_page.dart` | 737 | `CloudDrivePage` | Stateful | 云盘音乐：容量条、分页列表、操作 |
| `artist_detail_page.dart` | 697 | `ArtistDetailPage` | Stateful | 歌手详情：头图、简介、歌曲分页加载 |
| `personalization_settings_page.dart` | 587 | `PersonalizationSettingsPage` | Stateful | 个性化：8 预设色、背景图选择/透明度/预览/移除 |
| `about_page.dart` | 574 | `AboutPage` | Stateful | 关于：版本卡、更新日志解析（`update.md`）、检查更新、仓库链接 |
| `playback_history_page.dart` | 413 | `PlaybackHistoryPage` | Stateful | 播放历史（上限 200 条）、清空、跳歌手 |
| `downloaded_songs_page.dart` | 399 | `DownloadedSongsPage` | Stateful | 已下载 / 播放缓存两个 Tab |
| `playback_stats_page.dart` | 379 | `PlaybackStatsPage` | Stateful | 播放统计：累计次数、时长、Top 10 歌手/歌曲 |
| `desktop_lyrics_settings_page.dart` | 375 | `DesktopLyricsSettingsPage` | Stateful | 桌面歌词设置：透明度、字号、文字/背景色、行为项 |
| `local_songs_page.dart` | 328 | `LocalSongsPage` | Stateful | 本地音乐：目录选择/清除、检索、重新扫描、列表播放 |
| `comment_page.dart` | 230 | `CommentPage` | Stateful | 歌曲评论分页列表 |
| `album_shop_page.dart` | 205 | `AlbumShopPage` | Stateful | 新碟上架网格 + 滚动加载更多 |
| `app_shell.dart` | 194 | `AppShell` | Stateful | 根壳：首页/我的双 Tab（`BottomNavigationBar` 或 `NavigationRail`）+ 悬浮 MiniPlayer |
| `audio_interruption_settings_page.dart` | 110 | `AudioInterruptionSettingsPage` | **Stateless** | 后台打断机制：阻止打断 + 自动恢复两个开关 |

### 3.2 页面依赖与导航

| 页面 | 依赖的控制器 / 服务 | 导航入口 | 导航出口 |
|---|---|---|---|
| `AppShell` | `MusicApi`、`AuthController`、`PlayerController`、`CacheService`、`DownloadController`、`ThemeController`、`LocalMusicController` | `main.dart:165`（登录后） | `HomePage`、`LibraryPage`（`IndexedStack`，:80）；Android 返回键 → `MethodChannel('kgka_music_hl/screen').moveTaskToBack`（:201-208） |
| `HomePage` | `MusicApi`、`AuthController`、`PlayerController`、`CacheService` | `app_shell.dart:53` | `SearchPage`（:488）、`ArtistDetailPage`（:197）、`AlbumShopPage`（:210）、`PlaylistDetailPage`（`openPlaylistDetail` :175） |
| `LibraryPage` | `MusicApi`、`AuthController`、`PlayerController`、`DownloadController`、`ThemeController`、`LocalMusicController` | `app_shell.dart:59` | `SettingsPage`（:70）、`DownloadedSongsPage`（:196）、`CloudDrivePage`（:206）、`LocalSongsPage`（:371）、`PlaybackHistoryPage`（:388）、`PlaylistDetailPage`（:57） |
| `LoginPage` | `AuthController`、`MusicApi`、`AppConfig` | `main.dart:162`（`!isRestoring && !isLoggedIn`） | 无（登录成功由 `AuthController` 通知，`main.dart` 自动切到 `AppShell`） |
| `SettingsPage` | `MusicApi`、`AuthController`、`PlayerController`、`ThemeController`、`LocalMusicController`、`CacheService?`、`DownloadController?`、`AppUpdateService`、`ArtworkCacheService` | `library_page.dart:70` | `PlaybackStatsPage`（:177）、`PlaybackHistoryPage`（:189）、`AudioInterruptionSettingsPage`（:205）、`DesktopLyricsSettingsPage`（:243）、`PersonalizationSettingsPage`（:311）、`AboutPage`（:348）、`AudioEffectsPage`（经 `showAudioEffectsSheet`） |
| `PersonalizationSettingsPage` | `ThemeController` | `settings_page.dart:311` | `_FullBackgroundPreview`（:147，`fullscreenDialog: true`） |
| `PlayerPage` | `PlayerController`、`AuthController`、`ThemeController.instance`、`MethodChannel('kgka_music_hl/screen')`、`SharedPreferences`（歌词字号） | `mini_player.dart:65` | `DesktopLyricsSettingsPage`（:352）、`ArtistDetailPage`（:618）、`_LyricCandidatePreviewPage`（:2032）、`CommentPage`（:3491） |
| `PlaylistDetailPage` | `MusicApi`、`AuthController`、`PlayerController`、自建 `CacheService()`（:119） | `openPlaylistDetail`（:26）——竖屏 `push` 整页；横屏 `showGeneralDialog` 右侧面板（宽度 `62%`，clamp 420~820）；`importPlaylistById`（:781） | `ArtistDetailPage`（:669） |
| `AlbumShopPage` | `MusicApi`、`AuthController`、`PlayerController` | `home_page.dart:210` | `PlaylistDetailPage`（:81，构造临时 `PlaylistSummary`） |
| `ArtistDetailPage` | `MusicApi`、`AuthController`、`PlayerController` | `home_page.dart:197`、`player_page.dart:618`、`playlist_detail_page.dart:669`、`playback_history_page.dart:82`、`cloud_drive_page.dart:142`、`search_page.dart:182` | 无 |
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
| `_SongSortMode` | `defaultOrder`、`byTitle`、`byArtist`、`byAlbum` | `playlist_detail_page.dart` | :1673 |
| `_PlaylistSortMode` | `defaultOrder`、`byName`、`bySongCount`、`byCreatedTime` | `library_page.dart` | :595 |
| `ToastType`（公开） | `info`、`success`、`error` | `widgets/toast.dart` | :6 |

---

## 4. 设计说明 · 组件清单

| 文件（`lib/ui/widgets/`） | 行数 | 公开 API | 用途 | 复用位置 |
|---|---|---|---|---|
| `mini_player.dart` | 503 | `MiniPlayer` | 悬浮迷你播放器 + 队列面板（竖屏 BottomSheet / 横屏右侧 `showGeneralDialog`） | `app_shell.dart:87`；内联于 `album_shop_page.dart`、`artist_detail_page.dart`、`cloud_drive_page.dart`、`playback_history_page.dart`、`search_page.dart`、`playlist_detail_page.dart` |
| `audio_effects_sheet.dart` | 500 | `showAudioEffectsSheet()`、`AudioEffectsPage` | 音效页：均衡器多段、低音增强、曲线绘制 | `settings_page.dart:164`、`player_page.dart:311` |
| `app_update_widgets.dart` | 340 | `AppUpdateBanner`、`showAppUpdateDialog()` | 更新提示横幅与更新对话框（含轻量 Markdown 渲染） | `about_page.dart` |
| `song_action_sheets.dart` | 308 | `SongSheetAction`、`showSongActionSheet()`、`showAddToPlaylistSheet()`、`addSongToQueueWithFeedback()` | 歌曲操作面板（宫格 + 列表两种形态）、添加到歌单、加入队列 | 首页、歌单详情、歌手详情、云盘、搜索、播放历史、播放页 |
| `sleep_timer_sheet.dart` | 219 | `showSleepTimerSheet()` | 定时播放面板（剩余时间展示、预设时长芯片） | `player_page.dart:334` |
| `toast.dart` | 194 | `Toast`、`ToastType` | 全局 Toast，挂在根 Navigator 的 Overlay，不依赖调用处 context | 全项目；`navigatorKey` 绑定在 `main.dart:142` |
| `artwork.dart` | 156 | `Artwork` | 封面组件：磁盘缓存 → `Image.file`，含 Shimmer 占位与渐变兜底 | 几乎所有列表与详情页 |
| `playback_speed_sheet.dart` | 150 | `showPlaybackSpeedSheet()` | 倍速面板（0.5x ~ 3.0x，吸附步进） | `player_page.dart:299` |
| `now_playing_badge.dart` | 99 | `NowPlayingBadge` | 正在播放的 3 柱跳动指示器（`CustomPainter`） | 本地音乐、歌单详情、歌手详情、云盘、播放历史、搜索 |
| `audio_quality_sheet.dart` | 85 | `showAudioQualitySheet()` | 音质选择面板（标准/高品/无损） | `settings_page.dart:371`、`player_page.dart:400` |
| `cached_artwork_image.dart` | 61 | `CachedArtworkImage`（`ImageProvider`） | 把 `ArtworkCacheService` 磁盘缓存包装成 `ImageProvider` | `player_page.dart` 的 `_ArtworkBackground` |
| `skeleton_box.dart` | 27 | `SkeletonBox`、`SkeletonBox.circle` | 骨架屏矩形/圆形占位块 | 首页、歌单详情、歌手详情、云盘 |
| `music_formatters.dart` | 5 | `formatPlayCount(int?)` | 播放量格式化：`≥10000` 显示「x.x 万次播放」，null 显示「精选歌单」 | 首页、歌单详情 |

---

## 5. 设计说明 · 巨型文件内部结构与可拆分点

> 本节「行区间」为文件真实行号（与 §2 的行数口径不同）。

### 5.1 `player_page.dart`（3290 行，文件真实行号 1-3536）

```
PlayerPage (:31)
└─ _PlayerPageState (:41, with WidgetsBindingObserver)
   └─ TickerMode → AnimatedBuilder(player) (:122-141)
      └─ _PlayerBody (:377)                       ← 竖屏/横屏分叉点
         ├─ _ArtworkBackground (:668) → CachedArtworkImage + 模糊 + 渐变
         │  └─ _FallbackBackground (:754)
         ├─ _TopBar (:1367) → _GlassIconButton (:3438)
         ├─ 竖屏：PageView(_pageController)
         │  ├─ _PosterPlayerPage (:1470)          第 0 页
         │  │  ├─ _PosterLyricPreview (:1576) → _MarqueeSingleLine (:1722) → _LyricText (:2961)
         │  │  ├─ _CommentEntry (:3467) → CommentPage
         │  │  ├─ _Progress (:3227)
         │  │  └─ _Controls (:3310)
         │  └─ _LyricPlayerPage (:1826)           第 1 页
         │     ├─ _LyricViewport (:2388)          滚动/对齐/拉伸核心
         │     │  ├─ _LyricText (:2961)
         │     │  └─ _KaraokeLinePainter (:3109, CustomPainter)
         │     └─ _GlassIconButton ×4
         ├─ 横屏：_LandscapePlayerContent (:771)
         │  ├─ _LandscapeHeader (:842) → _LandscapeHeaderButton (:945)
         │  ├─ _LandscapeArtworkShowcase (:984)
         │  └─ _LandscapeRightPanel (:1122)
         │     ├─ _LandscapeLyricPanel (:1165) → _LandscapeLyricLine (:1296)
         │     ├─ _Progress (:3227)
         │     └─ _Controls (:3310)
         └─ _PageDots (:3509)
独立路由页：_LyricCandidatePreviewPage (:2041) → _CandidateLyricPreview (:2285) / _LyricPreviewError (:2362)
动画曲线：_LyricScrollCurve (:1554)、_LyricLineTensionCurve (:1564)
顶层函数：_playerMoreActions (:273-375)、_showAudioQualityPicker (:396-412)
```

可拆分点：

| 拆分单元 | 行区间 | 约行数 | 建议去向 |
|---|---|---|---|
| `_LyricViewport` + 滚动/对齐算法 | 2388-2960 | 573 | `lib/ui/widgets/lyrics/lyric_viewport.dart` |
| `_LyricText` + `_KaraokeLinePainter`（逐字歌词绘制） | 2961-3226 | 266 | `lib/ui/widgets/lyrics/karaoke_line.dart` |
| `_Progress` + `_Controls` + `_GlassIconButton` + `_PageDots` | 3227-3536 | 310 | `lib/ui/widgets/player/player_controls.dart` |
| `_Landscape*` 家族 | 771-1366 | 596 | `lib/ui/pages/player/player_landscape.dart` |
| `_PosterPlayerPage` + `_PosterLyricPreview` + `_MarqueeSingleLine` | 1470-1825 | 356 | `lib/ui/pages/player/player_poster.dart` |
| `_LyricPlayerPage` | 1826-2040 | 215 | `lib/ui/pages/player/player_lyrics.dart` |
| `_LyricCandidatePreviewPage` 家族 | 2041-2387 | 347 | `lib/ui/pages/player/lyric_candidate_preview.dart` |
| `_playerMoreActions`（顶层函数，构造操作面板项） | 273-375 | 103 | `lib/ui/widgets/player/player_actions.dart` |
| `_PlayerBody` 本体保留 | 377-667 | 291 | 仅保留竖/横屏分叉与页面状态 |

### 5.2 `home_page.dart`（1705 行，文件真实行号 1-1812）

```
HomePage (:20)
└─ _HomePageState (:38)
   └─ FutureBuilder<_HomeData> → RefreshIndicator → CustomScrollView (:222-305)
      ├─ _HomeSkeleton (:1683)
      ├─ _ErrorView (:1754)
      ├─ _RecommendHeader (:308)
      │  ├─ _TopTabs (:397)                     推荐 / 电台
      │  ├─ _SmartSearch (:474) → SearchPage
      │  └─ _FeatureShelf (:532) → _FeatureCard (:603)
      ├─ _PersistentTabPane(visible: _sectionIndex == 0) (:382)
      │  ├─ _SongSection (:700) → _HomeSongRow (:887)
      │  │  └─ _SectionHeader (:1103)
      │  └─ _PlaylistRail (:1057) → _PlaylistCard (:1129)
      └─ _PersistentTabPane(visible: _sectionIndex == 1)
         └─ _RadioSection (:1174)
            ├─ _RadioHeroCard (:1341) → _RadioPlayBadge (:1540)
            ├─ _RadioStationRail (:1429) → _RadioStationCard (:1465)
            └─ _RadioSkeleton (:1578) / _RadioEmpty (:1615) / _RadioUnsupported (:1646)
数据容器：_HomeData (:1793)、_RadioData (:1805)
静态缓存：_HomePageState._cachedData (:39)、_RadioSectionState._cachedFuture (:1185)
```

可拆分点：

| 拆分单元 | 行区间 | 约行数 | 建议去向 |
|---|---|---|---|
| `_RadioSection` 家族 | 1174-1682 | 509 | `lib/ui/widgets/home/radio_section.dart`（注意自带静态缓存 `_cachedFuture`） |
| `_RecommendHeader` 家族（含 `_TopTabs`、`_SmartSearch`、`_FeatureShelf`、`_FeatureCard`） | 308-699 | 392 | `lib/ui/widgets/home/home_header.dart` |
| `_SongSection` + `_PlaylistRail` + `_PlaylistCard` + `_SectionHeader` | 700-1173 | 474 | `lib/ui/widgets/home/home_sections.dart` |
| `_HomeSongRow` | 887-1056 | 170 | 与 `playlist_detail_page._SongRow`、`cloud_drive_page._CloudSongRow`、`artist_detail_page._ArtistSongRow` 合并为公共歌曲行组件 |
| 骨架屏与错误态 | 1683-1812 | 130 | 与各页骨架屏统一到 `lib/ui/widgets/skeletons/` |

### 5.3 `playlist_detail_page.dart`（1633 行，文件真实行号 1-1728）

```
openPlaylistDetail (:26)   ← 竖屏 push / 横屏 showGeneralDialog 右面板
PlaylistDetailPage (:95)
└─ _PlaylistDetailPageState (:113)
   └─ CustomScrollView
      ├─ SliverAppBar(background: _HeroHeader (:1092))
      ├─ _PlaylistDetailSkeleton (:1183) → _PlaylistSkeletonSongRow (:1210)
      ├─ _DetailError (:1633)
      ├─ _Actions (:1238)            播放全部 / 随机 / 搜索 / 排序 / 更多
      ├─ _SearchEmpty (:1335)
      ├─ _SongRow (:1438)
      └─ _LoadMoreFooter (:1364)
BottomSheet 私有件：_ActionOption (:1041)、_ActionOptionTile (:1056)、_SortOptionTile (:1675)
枚举：_SongSortMode (:1673)    常量：_fullSongsCacheSuffix = '_full' (:23)
静态工厂：importPlaylistById (:781)
```

可拆分点：

| 拆分单元 | 行区间 | 约行数 | 建议去向 |
|---|---|---|---|
| `_SongRow` | 1438-1632 | 195 | 公共歌曲行组件（与 `_HomeSongRow` 等统一） |
| 骨架屏 / 错误态 / 加载页脚 | 1183-1237、1364-1437、1633-1672 | 166 | 统一到公共骨架与状态组件 |
| 排序/操作 BottomSheet 家族 | 1041-1091、1675-1728 | 105 | `lib/ui/widgets/playlist/playlist_action_sheets.dart` |
| `_Actions` | 1238-1334 | 97 | `lib/ui/widgets/playlist/playlist_actions_bar.dart` |
| `_HeroHeader` | 1092-1182 | 91 | `lib/ui/widgets/playlist/playlist_hero_header.dart` |
| `_PlaylistDetailPageState` 业务逻辑（加载、过滤、队列扩展） | 113-1039 | 927 | 可抽 `PlaylistDetailController`（当前是纯 State 内联，无法单测） |

---

## 6. 约束与坑

1. **`SettingsPage` 是 `StatelessWidget`，全部状态靠 `AnimatedBuilder(Listenable.merge([auth, player, localMusic, theme]))` 驱动**（`settings_page.dart:62-63`）；它自身不持有 `TabController`，因此设置页没有分段导航，只有一长列。
2. **导航全部是 `MaterialPageRoute`，无命名路由、无路由表。** 无法通过字符串统一拦截或做深链接；横屏的「右面板」是用 `showGeneralDialog` 模拟的，不是路由。
3. **页面构造参数即依赖注入。** 每个页面显式接收 `MusicApi` / 控制器实例，没有 `Provider` / `InheritedWidget`；新增依赖必须逐层透传（`main.dart` → `AppShell` → 页面）。
4. **`PlaylistDetailPage` 自建了 `CacheService()`**（`playlist_detail_page.dart:119`），而其他页面用 `AppShell.cache` 传入的实例。两者共用同一磁盘目录，但**绕过了装配点**，属于依赖注入的一致性瑕疵。
5. **`PlayerPage` 在 `initState` 强制放开横屏**（`player_page.dart:52-56`），`dispose` 再按 `ThemeController.instance.landscapeEnabled` + `AdaptiveLayout.isTabletByPlatform()` 恢复（:66-78），与 `ThemeController.applyOrientations` 是两套并行逻辑。
6. **歌曲行组件重复四份**：`_HomeSongRow`（`home_page.dart:887`）、`_SongRow`（`playlist_detail_page.dart:1438`）、`_CloudSongRow`（`cloud_drive_page.dart:417`）、`_ArtistSongRow`（`artist_detail_page.dart:453`）。四者都内联了 `NowPlayingBadge`、`Artwork`、操作面板调用，改一处需改四处。
7. **骨架屏同样重复**：`_HomeSkeleton`、`_PlaylistDetailSkeleton`、`_ArtistDetailSkeleton`、`_CloudSkeleton`、`_RadioSkeleton`、`_HotSearchSkeleton`、`_SkeletonBlock` 七个实现，仅 `SkeletonBox` 是公共件。
8. **私有类型出现在公开 API 上**：`ThemeController.presetColors` 的元素类型 `_PresetColor` 是库私有（见 `控制器层-ThemeController.md` §2.3），外部只能靠类型推断遍历。
10. **`LocalSongsPage` 与 `SettingsPage` 各自实现了一份目录选择逻辑**（`local_songs_page.dart:47-112` vs `settings_page.dart:472-549`）。
11. **`AudioEffectsPage` 名义上是「sheet」，实际是整页路由**（`audio_effects_sheet.dart:10-13` 用 `Navigator.push`），文件命名与行为不一致。
12. **`music_formatters.dart` 只有 5 行**，是全项目最小的 Dart 文件；`formatPlayCount` 对 `null` 返回「精选歌单」而非空串，调用方需知道这一语义。
13. **`HomePage` 与 `_RadioSection` 用静态变量缓存数据**（`_cachedData` / `_cachedFuture`），跨实例共享；这意味着页面重建后仍可能显示上一次会话的数据，刷新依赖 `_silentRefresh`（`home_page.dart:82-108`）。

---

## 7. 待办与关联

### 7.1 待办

| 项 | 说明 | 优先级 |
|---|---|---|
| 拆分 `player_page.dart` | 按 §5.1 的 9 个单元拆出，`_PlayerBody` 只留分叉逻辑 | 高 |
| 统一歌曲行组件 | 合并 4 份 `*SongRow`，参数化「是否显示歌手/专辑/时长/操作」 | 高 |
| 统一骨架屏 | 建 `lib/ui/widgets/skeletons/` 收敛 7 个实现 | 中 |
| 抽取 `PlaylistDetailController` | 当前 927 行状态逻辑内联在 State 中，无法单测 | 中 |
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
