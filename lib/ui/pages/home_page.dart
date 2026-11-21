import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../app_theme.dart';
import '../widgets/artwork.dart';
import '../widgets/listenable_selector.dart';
import '../widgets/skeleton_box.dart';
import '../widgets/music_formatters.dart';
import '../widgets/now_playing_badge.dart';
import '../widgets/personal_fm_section.dart';
import '../widgets/preparing_indicator.dart';
import '../widgets/song_action_sheets.dart';
import 'artist_detail_page.dart';
import 'playlist_detail_page.dart';
import 'search_page.dart';

/// 每日推荐 Banner 在自定义背景下的底色：半透明，让背景透出来。
///
/// 与「我的」页同一套做法——只做纯色半透明，不加 [BackdropFilter]。Banner
/// 位于可滚动页面的顶端，背景图开启时滚动过程中背景每帧都在变，逐个容器
/// 上模糊的代价远大于收益。未开启背景图时返回原色，行为完全不变。
@visibleForTesting
Color homeBannerCardColor(ColorScheme scheme, {required bool frosted}) {
  if (!frosted) return scheme.surfaceContainer;
  final dark = scheme.brightness == Brightness.dark;
  return scheme.surfaceContainer.withValues(alpha: dark ? .68 : .72);
}

/// 自定义背景是否生效——开关打开且确实选了图才算，与「我的」页判据一致。
@visibleForTesting
bool homeBannerFrostedActive(ThemeController theme) =>
    theme.backgroundEnabled && theme.backgroundImagePath != null;

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.cache,
    required this.theme,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final CacheService cache;
  final ThemeController theme;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static _HomeData? _cachedData;
  static String? _cachedDataOwner;

  Future<_HomeData>? _future;
  late int _observedCacheClearGeneration;
  late String _activeCacheOwner;
  var _cacheRestorePending = false;
  var _sectionIndex = 0;

  String get _currentCacheOwner =>
      widget.auth.session?.userId?.isNotEmpty == true
      ? widget.auth.session!.userId!
      : 'anonymous';

  String _cacheKeyForOwner(String owner) =>
      owner == 'anonymous' ? 'cache_home' : 'cache_user_home_$owner';

  @override
  void initState() {
    super.initState();
    _observedCacheClearGeneration = widget.cache.clearGeneration;
    _activeCacheOwner = _currentCacheOwner;
    widget.cache.addListener(_handleCacheChange);
    final cached = _cachedDataOwner == _activeCacheOwner ? _cachedData : null;
    if (cached != null) {
      _future = Future.value(cached);
      _silentRefresh();
    } else {
      _cacheRestorePending = true;
      _tryRestoreFromCache(owner: _activeCacheOwner);
    }
    widget.auth.addListener(_handleAuthChanged);
  }

  @override
  void dispose() {
    widget.auth.removeListener(_handleAuthChanged);
    widget.cache.removeListener(_handleCacheChange);
    super.dispose();
  }

  void _handleCacheChange() {
    final generation = widget.cache.clearGeneration;
    if (generation == _observedCacheClearGeneration) return;
    _observedCacheClearGeneration = generation;
    _cachedData = null;
    _cachedDataOwner = null;
    if (!mounted) return;
    setState(() => _future = null);
  }

  void _handleAuthChanged() {
    if (widget.auth.isRestoring) return;
    final owner = _currentCacheOwner;
    if (owner != _activeCacheOwner) {
      _activeCacheOwner = owner;
      _future = null;
      if (_cachedDataOwner != owner) _cachedData = null;
      _cacheRestorePending = true;
      _tryRestoreFromCache(owner: owner);
      return;
    }
    if (!widget.auth.isLoggedIn || _cacheRestorePending) return;
    if (_future == null) {
      setState(() => _future = _load());
    }
  }

  /// 后台静默刷新首页数据，统一通过 CacheService 的 SWR 语义执行。
  Future<void> _silentRefresh() async {
    try {
      await _loadHomeSWR(updateUi: true);
    } catch (_) {
      // 静默刷新失败，保持缓存数据不变。
    }
  }

  Future<_HomeData> _load() => _loadHomeSWR(forceRefresh: true);

  Future<_HomeData> _loadHomeSWR({
    bool forceRefresh = false,
    bool updateUi = false,
  }) async {
    final owner = _activeCacheOwner;
    final completion = Completer<_HomeData>();
    await widget.cache.swr<_HomeData>(
      key: _cacheKeyForOwner(owner),
      ttl: AppConfig.homeCacheTtl,
      fetch: () async {
        final results = await Future.wait([
          widget.api.dailyRecommend(),
          widget.api.recommendedPlaylists(),
        ]);
        if (owner != _currentCacheOwner) {
          throw StateError('Homepage cache owner changed during refresh');
        }
        return _HomeData(
          daily: results[0] as DailyRecommend,
          playlists: results[1] as List<PlaylistSummary>,
        );
      },
      decode: _homeDataFromCache,
      encode: (data) => {
        'daily': data.daily.toCache(),
        'playlists': data.playlists.map((p) => p.toCache()).toList(),
      },
      onData: (data) {
        if (owner != _currentCacheOwner) {
          if (!completion.isCompleted) {
            completion.completeError(
              StateError('Homepage cache owner changed during refresh'),
            );
          }
          return;
        }
        _cachedData = data;
        _cachedDataOwner = owner;
        if (!completion.isCompleted) completion.complete(data);
        if (updateUi && mounted) {
          setState(() => _future = Future.value(data));
        }
      },
      onError: (error) {
        if (!completion.isCompleted) completion.completeError(error);
      },
      forceRefresh: forceRefresh,
    );
    return completion.future;
  }

  Future<void> _tryRestoreFromCache({required String owner}) async {
    CacheResult<Map<String, dynamic>>? cached;
    try {
      cached = await widget.cache.read<Map<String, dynamic>>(
        _cacheKeyForOwner(owner),
        decode: (json) => json,
        ttl: AppConfig.homeCacheTtl,
      );
    } catch (_) {
      cached = null;
    }
    if (owner != _activeCacheOwner || !mounted) return;
    _cacheRestorePending = false;
    if (_future != null) return;
    if (cached != null) {
      final data = _homeDataFromCache(cached.data);
      _cachedData = data;
      _cachedDataOwner = owner;
      setState(() => _future = Future.value(data));
      _silentRefresh();
    } else {
      setState(() => _future = _load());
    }
  }

  _HomeData _homeDataFromCache(Map<String, dynamic> json) {
    return _HomeData(
      daily: DailyRecommend.fromCache(json['daily'] as Map<String, dynamic>),
      playlists: (json['playlists'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlaylistSummary.fromCache)
          .toList(),
    );
  }

  Future<void> _refresh() async {
    final future = _load();
    setState(() {
      _future = future;
    });
    await future;
  }

  void _openPlaylist(PlaylistSummary playlist) {
    openPlaylistDetail(
      context: context,
      api: widget.api,
      auth: widget.auth,
      player: widget.player,
      cache: widget.cache,
      playlist: playlist,
    );
  }

  void _playSong(Song song, List<Song> queue) {
    widget.player.playSong(song, queue: queue);
  }

  void _openArtist(Song song) {
    final artist = song.artists.firstWhere(
      (a) => a.name.isNotEmpty,
      orElse: () => const ArtistRef(id: '', name: ''),
    );
    if (artist.name.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailPage(
          api: widget.api,
          auth: widget.auth,
          artist: artist,
          player: widget.player,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HomeData>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data ?? _cachedData;
        return RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (data == null &&
                  (_future == null ||
                      snapshot.connectionState == ConnectionState.waiting))
                const SliverToBoxAdapter(child: _HomeSkeleton())
              else if (data == null && snapshot.hasError)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _ErrorView(
                    message: snapshot.error.toString(),
                    onRetry: _refresh,
                  ),
                )
              else ...[
                SliverToBoxAdapter(
                  child: _RecommendHeader(
                    auth: widget.auth,
                    daily: data!.daily,
                    theme: widget.theme,
                    sectionIndex: _sectionIndex,
                    onSectionChanged: (value) {
                      setState(() => _sectionIndex = value);
                    },
                    onDailyPlay: () {
                      final songs = data.daily.songs;
                      if (songs.isNotEmpty) {
                        widget.player.playSong(songs.first, queue: songs);
                      }
                    },
                    api: widget.api,
                    player: widget.player,
                  ),
                ),
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      _PersistentTabPane(
                        visible: _sectionIndex == 0,
                        child: Column(
                          children: [
                            _SongSection(
                              // 与上方 Banner 是同一份每日推荐数据，标题必须
                              // 说同一件事；否则一屏里出现两个名字、一批歌。
                              title: '今日推荐',
                              songs: data.daily.songs,
                              onPlay: _playSong,
                              isLiked: (song) => widget.auth.isLiked(song),
                              onLikeTap: (song) => widget.auth.toggleLike(song),
                              auth: widget.auth,
                              player: widget.player,
                              onViewArtist: _openArtist,
                            ),
                            _PlaylistRail(
                              playlists: data.playlists,
                              onTap: _openPlaylist,
                            ),
                          ],
                        ),
                      ),
                      _PersistentTabPane(
                        visible: _sectionIndex == 1,
                        child: PersonalFmSection(
                          auth: widget.auth,
                          player: widget.player,
                          visible: _sectionIndex == 1,
                          theme: widget.theme,
                        ),
                      ),
                    ],
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 166)),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _RecommendHeader extends StatelessWidget {
  const _RecommendHeader({
    required this.auth,
    required this.daily,
    required this.theme,
    required this.sectionIndex,
    required this.onSectionChanged,
    required this.onDailyPlay,
    required this.api,
    required this.player,
  });

  final AuthController auth;
  final DailyRecommend daily;
  final ThemeController theme;
  final int sectionIndex;
  final ValueChanged<int> onSectionChanged;
  final VoidCallback onDailyPlay;
  final MusicApi api;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        // 头部此前是一段不透明渐变、并在底部收成纯白：一旦用户开了自定义
        // 背景图，这层白就在内容区顶端拉出一条硬白边，把页面切成两半。
        // 现在顶部保留足够不透明度压住状态栏与 Tab 文字，向下淡出到全透明，
        // 与窗口背景（纯色或背景图）连成一片，不再有明确接缝。
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [
                  const Color(0xFF10233A).withValues(alpha: .94),
                  const Color(0xFF06070A).withValues(alpha: 0),
                ]
              : [
                  const Color(0xFFDCEEFF).withValues(alpha: .94),
                  const Color(0xFFF7FBFF).withValues(alpha: 0),
                ],
          stops: const [0, 1],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 0, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 18),
                child: _TopTabs(
                  auth: auth,
                  index: sectionIndex,
                  onChanged: onSectionChanged,
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(right: 18),
                child: _SmartSearch(api: api, auth: auth, player: player),
              ),
              if (sectionIndex == 0) ...[
                const SizedBox(height: 14),
                _DailyBanner(daily: daily, theme: theme, onPlay: onDailyPlay),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PersistentTabPane extends StatelessWidget {
  const _PersistentTabPane({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TickerMode(
      enabled: visible,
      child: Offstage(offstage: !visible, child: child),
    );
  }
}

class _TopTabs extends StatelessWidget {
  const _TopTabs({
    required this.auth,
    required this.index,
    required this.onChanged,
  });

  final AuthController auth;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tabs = ['推荐', '电台'];
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        return Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final entry in tabs.indexed)
                      Padding(
                        padding: const EdgeInsets.only(right: 30),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onChanged(entry.$1),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                entry.$2,
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(
                                      fontSize: 18,
                                      color: entry.$1 == index
                                          ? colorScheme.onSurface
                                          : colorScheme.onSurfaceVariant,
                                      fontWeight: entry.$1 == index
                                          ? FontWeight.w800
                                          : FontWeight.w600,
                                    ),
                              ),
                              const SizedBox(height: 6),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: entry.$1 == index ? 28 : 0,
                                height: 3,
                                decoration: BoxDecoration(
                                  color: colorScheme.primary,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // 这里原本是一个 onPressed 为空、视觉上却像入口的菜单按钮：
            // 点了没有任何反应，是首屏最容易被用户判定为"坏了"的地方。
            // 在真正的菜单功能落地前，先移除这个空壳入口。
          ],
        );
      },
    );
  }
}

class _SmartSearch extends StatelessWidget {
  const _SmartSearch({
    required this.api,
    required this.auth,
    required this.player,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;

  void _openSearch(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchPage(api: api, auth: auth, player: player),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: () => _openSearch(context),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: .08)
                    : Colors.white.withValues(alpha: .92),
                borderRadius: BorderRadius.circular(12),
                // 深色模式下白 56% 的描边比内容本身还亮，抢走了搜索框的层次；
                // 改用主题分隔色，只在浅色模式保留高光边。
                border: Border.all(
                  color: isDark
                      ? colorScheme.outlineVariant
                      : Colors.white.withValues(alpha: .56),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '搜索歌曲，歌手',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          // 占位文字不该比正文更抢眼：w700 → w500。
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 每日推荐 Banner。
///
/// 取代此前并排的两张方形卡（「猜你喜欢」+「新碟上架」）。前者与下方列表
/// 指向同一批每日推荐歌曲，同一份内容在一屏内被曝光了两次；后者与音乐
/// 推荐无关，只是借首屏黄金位做一个商城入口。Banner 把日期、今日首曲与
/// 播放入口收进一张横向卡片，只保留一次呈现。
class _DailyBanner extends StatelessWidget {
  const _DailyBanner({
    required this.daily,
    required this.theme,
    required this.onPlay,
  });

  final DailyRecommend daily;
  final ThemeController theme;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final songs = daily.songs;
    final metrics = dailyBannerMetrics(MediaQuery.sizeOf(context).width - 36);
    final items = dailyBannerItems(daily).take(metrics.columns).toList();

    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(right: 18),
        child: _BannerEmpty(height: metrics.height, theme: theme),
      );
    }

    final dateLabel = dailyBannerDateLabel(daily.title);
    final metaLabel = dailyBannerMetaLabel(dateLabel, songs.length);

    return Padding(
      padding: const EdgeInsets.only(right: 18),
      child: SizedBox(
        height: metrics.height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items) ...[
              if (item != items.first) const SizedBox(width: 12),
              Expanded(
                child: _BannerCard(
                  item: item,
                  metaLabel: metaLabel,
                  theme: theme,
                  compact: metrics.compact,
                  onPlay: item == items.first ? onPlay : null,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Banner 单张卡片：左侧封面（正方形，永不裁切），右侧信息。
class _BannerCard extends StatelessWidget {
  const _BannerCard({
    required this.item,
    required this.metaLabel,
    required this.theme,
    required this.compact,
    required this.onPlay,
  });

  final BannerItem item;
  final String metaLabel;
  final ThemeController theme;
  final bool compact;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: theme,
      builder: (context, _) => _buildCard(context),
    );
  }

  Widget _buildCard(BuildContext context) {
    final cover = item.coverUrl;
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      button: onPlay != null,
      label: '每日推荐，${item.title}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPlay,
        child: DecoratedBox(
          // 不再使用品牌蓝渐变填充：首屏其它卡片（歌单、电台）都是中性底色
          // + 灰黑文字，Banner 独自撑一块高饱和蓝面会显得像是另一个应用的
          // 插入件。这里统一到中性底色；开启自定义背景图后改为半透明，
          // 让背景透出来（参数与「我的」页快捷卡一致）。
          decoration: BoxDecoration(
            color: homeBannerCardColor(
              colorScheme,
              frosted: homeBannerFrostedActive(theme),
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 封面用正方形，且宽度不超过卡片的一半：固定正方形在高窄卡上
                // 会把右侧信息区挤到只剩几个像素，这一层夹取让两种极端都不会溢出。
                LayoutBuilder(
                  builder: (context, constraints) {
                    // 封面恒定正方形，但不允许超过卡片一半宽：极窄的卡上
                    // 固定正方形会把右侧信息区压到只剩几个像素。
                    final side = constraints.maxHeight.isFinite
                        ? constraints.maxHeight.clamp(
                            0.0,
                            constraints.maxWidth * .5,
                          )
                        : constraints.maxWidth * .5;
                    return SizedBox(
                      width: side,
                      child: _BannerCoverStack(cover: cover),
                    );
                  },
                ),
                Expanded(
                  child: _BannerInfo(
                    title: item.title,
                    artist: item.artist,
                    metaLabel: metaLabel,
                    compact: compact,
                    onPlay: onPlay,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Banner 左侧的正方形封面。
class _BannerCoverStack extends StatelessWidget {
  const _BannerCoverStack({required this.cover});

  final String cover;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(
          cover,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Center(
            child: Icon(
              Icons.graphic_eq_rounded,
              size: 44,
              color: Color(0x40FFFFFF),
            ),
          ),
        ),
      ],
    );
  }
}

class _BannerInfo extends StatelessWidget {
  const _BannerInfo({
    required this.title,
    required this.artist,
    required this.metaLabel,
    required this.compact,
    required this.onPlay,
  });

  final String title;
  final String artist;
  final String metaLabel;
  final bool compact;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 文字层级对齐首页其它区块：元信息 onSurfaceVariant、
          // 标题 onSurface、歌手 onSurfaceVariant。
          Text(
            metaLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: .2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colorScheme.onSurface,
              fontSize: compact ? 15 : 18,
              height: 1.25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Align(
            alignment: Alignment.centerRight,
            child: _BannerPlayButton(onTap: onPlay),
          ),
        ],
      ),
    );
  }
}

class _BannerEmpty extends StatelessWidget {
  const _BannerEmpty({required this.height, required this.theme});

  final double height;
  final ThemeController theme;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: theme,
      builder: (context, _) => _buildCard(context),
    );
  }

  Widget _buildCard(BuildContext context) {
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: homeBannerCardColor(
            Theme.of(context).colorScheme,
            frosted: homeBannerFrostedActive(theme),
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '今天还没有推荐，稍后再来看看',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Banner 右下角的播放图标。
///
/// 这里刻意不画圆形底色：它只是一枚提示「这张卡可以播放」的图标，真正的
/// 点击热区是整个 Banner。白底圆按钮在深色封面上会变成一个高对比度的实体
/// 按钮，抢走首曲标题的注意力；无底图标 + 一层阴影就能保证在任意封面上可见。
class _BannerPlayButton extends StatelessWidget {
  const _BannerPlayButton({required this.onTap});

  /// 只有可播放的那张卡会传回调；其余卡片为 null，图标仅作视觉提示。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          Icons.play_arrow_rounded,
          size: 34,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// 每日推荐 Banner 的自适应尺寸。
///
/// 旧实现是「宽度铺满 + 高度写死 168」。手机竖屏下卡片约 2.1:1 尚可，
/// 但平板横屏内容区能到 1100+ 宽，同样 168 高就变成 6.6:1：方形封面塞进
/// 3.3:1 的槽位，BoxFit.cover 只裁不拉，上下各切掉 35%，画面主体直接
/// 消失——这就是"平板畸变"的真正来源。
///
/// 现在高度按宽度推算并夹在合理区间，且宽度超过阈值时改为左右各一张卡：
/// 单张卡内部封面固定正方形、信息在右侧，封面比例恒定 1:1，永远不裁主体。
@visibleForTesting
class DailyBannerMetrics {
  const DailyBannerMetrics({
    required this.height,
    required this.columns,
    required this.compact,
  });

  /// Banner 整体高度（逻辑像素）。
  final double height;

  /// 并排展示几张卡片：窄屏 1 张，宽屏 2 张。
  final int columns;

  /// 单卡是否处于紧凑形态（文字更小、标题单行）。
  final bool compact;

  @override
  bool operator ==(Object other) =>
      other is DailyBannerMetrics &&
      other.height == height &&
      other.columns == columns &&
      other.compact == compact;

  @override
  int get hashCode => Object.hash(height, columns, compact);
}

/// 根据可用宽度推算 Banner 尺寸。
///
/// [availableWidth] 是内容区宽度（屏宽减去左右内边距）。
@visibleForTesting
DailyBannerMetrics dailyBannerMetrics(double availableWidth) {
  if (!availableWidth.isFinite || availableWidth <= 0) {
    return const DailyBannerMetrics(height: 168, columns: 1, compact: false);
  }

  // 两张卡并排的下限：每张卡至少要有「正方形封面 + 可读的文字区」。
  // 低于这个宽度时两张卡会把文字压成几个字，不如回到单张。
  const twoColumnMinWidth = 640.0;
  final columns = availableWidth >= twoColumnMinWidth ? 2 : 1;

  // 单张卡宽 = 可用宽度减去卡间距后的均分。
  final cardWidth = columns == 2 ? (availableWidth - 12) / 2 : availableWidth;

  // 卡高跟随卡片宽度变化，保证单卡内部仍然是「左封面 + 右信息」的横向比例，
  // 而不是被拉成一条细线。夹在 148–188 之间：低于 148 文字放不下两行，
  // 高于 188 首屏会被 Banner 吃掉太多。
  final height = (cardWidth * 0.42).clamp(148.0, 188.0);

  // 双栏时每张卡只有半宽，文字区更窄，降级为紧凑排版。
  final compact = columns == 2 || availableWidth < 340;

  return DailyBannerMetrics(
    height: height.roundToDouble(),
    columns: columns,
    compact: compact,
  );
}

/// Banner 上要展示的条目。
///
/// 每条对应一首歌曲：标题用歌名、副标题用歌手、封面用该曲封面。
/// 封面缺失的条目会被跳过——没有封面的卡在拼贴里就是一块纯色，不如不展示。
@visibleForTesting
List<BannerItem> dailyBannerItems(DailyRecommend daily) {
  final items = <BannerItem>[];
  final seenCovers = <String>{};

  for (final song in daily.songs) {
    final cover = song.coverUrl;
    if (cover == null || cover.isEmpty) continue;
    if (!seenCovers.add(cover)) continue;
    items.add(
      BannerItem(title: song.title, artist: song.artist, coverUrl: cover),
    );
    if (items.length >= 2) break;
  }

  // 一首封面都没有时退回整张推荐列表的封面，保证至少有一张卡可展示。
  if (items.isEmpty && daily.coverUrl != null && daily.coverUrl!.isNotEmpty) {
    final first = daily.songs.isEmpty ? null : daily.songs.first;
    items.add(
      BannerItem(
        title: first?.title ?? '每日推荐',
        artist: first?.artist ?? '献给此刻迈步的你',
        coverUrl: daily.coverUrl!,
      ),
    );
  }

  return items;
}

/// Banner 顶部的元信息行：日期 + 曲目数。
@visibleForTesting
String dailyBannerMetaLabel(String dateLabel, int songCount) {
  if (songCount <= 0) return dateLabel;
  return '$dateLabel   $songCount首';
}

/// Banner 上的一条推荐（对应一首每日推荐歌曲）。
class BannerItem {
  const BannerItem({
    required this.title,
    required this.artist,
    required this.coverUrl,
  });

  final String title;
  final String artist;
  final String coverUrl;

  @override
  bool operator ==(Object other) =>
      other is BannerItem &&
      other.title == title &&
      other.artist == artist &&
      other.coverUrl == coverUrl;

  @override
  int get hashCode => Object.hash(title, artist, coverUrl);
}

/// 把「每日推荐 2026-11-17」这类标题里的日期取出来，只保留 M月d日。
///
/// 标题本身不再整句上屏：Banner 左上角已有「每日推荐」标签，再重复一遍
/// 会挤占首曲标题的空间。
@visibleForTesting
String dailyBannerDateLabel(String title, {DateTime? now}) {
  final match = RegExp(r'(\d{4})[-/](\d{1,2})[-/](\d{1,2})').firstMatch(title);
  if (match != null) {
    return '${match.group(2)}月${match.group(3)}日';
  }
  final today = now ?? DateTime.now();
  return '${today.month}月${today.day}日';
}

@visibleForTesting
int homeSongPageSize(bool isWide) => isWide
    ? _SongSectionState._widePerPage
    : _SongSectionState._portraitPerPage;

class _SongSection extends StatefulWidget {
  const _SongSection({
    required this.title,
    required this.songs,
    required this.onPlay,
    required this.isLiked,
    required this.onLikeTap,
    required this.auth,
    required this.player,
    required this.onViewArtist,
  });

  final String title;
  final List<Song> songs;
  final void Function(Song song, List<Song> queue) onPlay;
  final bool Function(Song song) isLiked;
  final void Function(Song song) onLikeTap;
  final AuthController auth;
  final PlayerController player;
  final void Function(Song song) onViewArtist;

  @override
  State<_SongSection> createState() => _SongSectionState();
}

class _SongSectionState extends State<_SongSection> {
  static const _portraitPerPage = 5;
  static const _widePerPage = 6;
  late final PageController _pageController;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.songs.isEmpty) {
      return const SizedBox.shrink();
    }

    final size = MediaQuery.sizeOf(context);
    final isWide = size.shortestSide >= 600;
    final perPage = homeSongPageSize(isWide);
    final rowCount = isWide ? (perPage / 2).ceil() : perPage;
    final pageCount = (widget.songs.length / perPage).ceil();

    return AnimatedBuilder(
      animation: widget.auth,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          child: Column(
            children: [
              _SectionHeader(
                title: widget.title,
                action: IconButton.filledTonal(
                  tooltip: '播放',
                  onPressed: () =>
                      widget.onPlay(widget.songs.first, widget.songs),
                  icon: const Icon(Icons.play_arrow_rounded),
                  style: IconButton.styleFrom(
                    fixedSize: const Size.square(42),
                    shape: const CircleBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: rowCount * 76.0,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: pageCount,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, pageIndex) {
                    final start = pageIndex * perPage;
                    final end = (start + perPage).clamp(0, widget.songs.length);
                    final pageSongs = widget.songs.sublist(start, end);

                    if (isWide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                for (var i = 0; i < pageSongs.length; i += 2)
                                  _HomeSongRow(
                                    song: pageSongs[i],
                                    queue: widget.songs,
                                    onPlay: widget.onPlay,
                                    isLiked: widget.isLiked(pageSongs[i]),
                                    onLikeTap: () =>
                                        widget.onLikeTap(pageSongs[i]),
                                    auth: widget.auth,
                                    player: widget.player,
                                    onViewArtist: () =>
                                        widget.onViewArtist(pageSongs[i]),
                                  ),
                              ],
                            ),
                          ),
                          if (pageSongs.length > 1) ...[
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                children: [
                                  for (var i = 1; i < pageSongs.length; i += 2)
                                    _HomeSongRow(
                                      song: pageSongs[i],
                                      queue: widget.songs,
                                      onPlay: widget.onPlay,
                                      isLiked: widget.isLiked(pageSongs[i]),
                                      onLikeTap: () =>
                                          widget.onLikeTap(pageSongs[i]),
                                      auth: widget.auth,
                                      player: widget.player,
                                      onViewArtist: () =>
                                          widget.onViewArtist(pageSongs[i]),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      );
                    }

                    return Column(
                      children: [
                        for (final song in pageSongs)
                          _HomeSongRow(
                            song: song,
                            queue: widget.songs,
                            onPlay: widget.onPlay,
                            isLiked: widget.isLiked(song),
                            onLikeTap: () => widget.onLikeTap(song),
                            auth: widget.auth,
                            player: widget.player,
                            onViewArtist: () => widget.onViewArtist(song),
                          ),
                      ],
                    );
                  },
                ),
              ),
              if (pageCount > 1) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(pageCount, (i) {
                    final active = i == _page;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: active ? 16 : 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: active
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(
                                context,
                              ).colorScheme.outline.withValues(alpha: .3),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    );
                  }),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 首页歌曲行真正关心的播放态。
///
/// 每一行原本都 `AnimatedBuilder(animation: player)` 订阅整个播放器，播放器的
/// 数十个 `notifyListeners()` 调用点会让 5 行一起重建。这里只取行用到的三个
/// 字段，值不变不重建。
class _HomeSongActivity {
  const _HomeSongActivity({
    required this.active,
    required this.preparing,
    required this.playing,
  });

  final bool active;
  final bool preparing;
  final bool playing;

  @override
  bool operator ==(Object other) =>
      other is _HomeSongActivity &&
      other.active == active &&
      other.preparing == preparing &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(active, preparing, playing);
}

class _HomeSongRow extends StatelessWidget {
  const _HomeSongRow({
    required this.song,
    required this.queue,
    required this.onPlay,
    required this.isLiked,
    required this.onLikeTap,
    required this.auth,
    required this.player,
    required this.onViewArtist,
  });

  final Song song;
  final List<Song> queue;
  final void Function(Song song, List<Song> queue) onPlay;
  final bool isLiked;
  final VoidCallback onLikeTap;
  final AuthController auth;
  final PlayerController player;
  final VoidCallback onViewArtist;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListenableSelector<PlayerController, _HomeSongActivity>(
      listenable: player,
      selector: (_, player) => _HomeSongActivity(
        active: song.hash.isNotEmpty && player.currentSong?.hash == song.hash,
        preparing: player.isPreparingSong(song),
        playing: player.isPlaying,
      ),
      builder: (context, activity) {
        final active = activity.active;
        final preparing = activity.preparing;
        final activeColor = colorScheme.primary;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onPlay(song, queue),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Stack(
                  children: [
                    Artwork(url: song.coverUrl, size: 58, borderRadius: 8),
                    if (active || preparing)
                      Positioned(
                        right: 5,
                        bottom: 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: .88),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: preparing
                                ? PreparingIndicator(
                                    color: activeColor,
                                    size: 14,
                                  )
                                : NowPlayingBadge(
                                    active: active,
                                    playing: activity.playing,
                                    color: activeColor,
                                    size: 14,
                                  ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: active ? activeColor : null,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: active
                              ? activeColor.withValues(alpha: .72)
                              : colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  onPressed: onLikeTap,
                  icon: Icon(
                    isLiked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: isLiked ? AppTheme.musicRed : colorScheme.outline,
                    size: 27,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  tooltip: '更多',
                  onPressed: () {
                    showSongActionSheet(
                      context: context,
                      song: song,
                      actions: [
                        SongSheetAction(
                          icon: Icons.queue_music_rounded,
                          title: '下一首播放',
                          onTap: () => addSongToQueueWithFeedback(
                            context: context,
                            player: player,
                            song: song,
                          ),
                        ),
                        SongSheetAction(
                          icon: Icons.playlist_add_rounded,
                          title: '添加到歌单',
                          onTap: () => showAddToPlaylistSheet(
                            context: context,
                            auth: auth,
                            song: song,
                          ),
                        ),
                        SongSheetAction(
                          icon: Icons.person_rounded,
                          title: '查看歌手',
                          onTap: onViewArtist,
                        ),
                        if (player.downloadController != null)
                          SongSheetAction(
                            icon: player.downloadController!.isDownloaded(song)
                                ? Icons.download_done_rounded
                                : Icons.download_rounded,
                            title: player.downloadController!.isDownloaded(song)
                                ? '已下载'
                                : '下载',
                            onTap: () => player.downloadController!
                                .downloadWithOptions(song, player.audioQuality),
                          ),
                      ],
                    );
                  },
                  icon: const Icon(Icons.more_horiz_rounded),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PlaylistRail extends StatelessWidget {
  const _PlaylistRail({required this.playlists, required this.onTap});

  final List<PlaylistSummary> playlists;
  final ValueChanged<PlaylistSummary> onTap;

  @override
  Widget build(BuildContext context) {
    if (playlists.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _SectionHeader(
              title: '推荐歌单',
              action: const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 204,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              scrollDirection: Axis.horizontal,
              itemCount: playlists.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final playlist = playlists[index];
                return _PlaylistCard(
                  playlist: playlist,
                  onTap: () => onTap(playlist),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.action});

  final String title;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        action,
      ],
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({required this.playlist, required this.onTap});

  final PlaylistSummary playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 128,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Artwork(url: playlist.coverUrl, size: 128, borderRadius: 10),
            const SizedBox(height: 9),
            SizedBox(
              height: 42,
              child: Text(
                playlist.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.16,
                ),
              ),
            ),
            Text(
              playlist.subtitle ?? formatPlayCount(playlist.playCount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 首页首屏骨架：Banner 与两行列表的占位，避免加载时整页空白。
class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(18, 0, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(width: double.infinity, height: 168, radius: 18),
          SizedBox(height: 24),
          SkeletonBox(width: 120, height: 18, radius: 6),
          SizedBox(height: 12),
          SkeletonBox(width: double.infinity, height: 76, radius: 12),
          SizedBox(height: 10),
          SkeletonBox(width: double.infinity, height: 76, radius: 12),
          SizedBox(height: 10),
          SkeletonBox(width: double.infinity, height: 76, radius: 12),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.wifi_off_rounded,
            size: 44,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 14),
          Text('暂时连接不上音乐服务', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

class _HomeData {
  const _HomeData({required this.daily, required this.playlists});

  final DailyRecommend daily;
  final List<PlaylistSummary> playlists;
}
