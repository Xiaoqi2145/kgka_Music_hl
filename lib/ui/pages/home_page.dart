import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../app_theme.dart';
import '../widgets/artwork.dart';
import '../widgets/listenable_selector.dart';
import '../widgets/skeleton_box.dart';
import '../widgets/music_formatters.dart';
import '../widgets/now_playing_badge.dart';
import '../widgets/preparing_indicator.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import 'artist_detail_page.dart';
import 'playlist_detail_page.dart';
import 'search_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.cache,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final CacheService cache;

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
                        child: _RadioSection(
                          api: widget.api,
                          player: widget.player,
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
    required this.sectionIndex,
    required this.onSectionChanged,
    required this.onDailyPlay,
    required this.api,
    required this.player,
  });

  final AuthController auth;
  final DailyRecommend daily;
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
                _DailyBanner(daily: daily, onPlay: onDailyPlay),
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
  const _DailyBanner({required this.daily, required this.onPlay});

  final DailyRecommend daily;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final songs = daily.songs;
    final covers = dailyBannerCovers(daily);
    final headline = songs.isEmpty ? '献给此刻迈步的你' : songs.first.title;
    // 首曲下方只留歌手；曲目数挪到顶部与日期并排，读起来是一行"元信息"，
    // 不再把两件不相干的事（谁唱的 / 一共几首）挤在同一行里。
    final caption = songs.isEmpty
        ? '今天还没有推荐，稍后再来看看'
        : songs.first.artist;
    final dateLabel = dailyBannerDateLabel(daily.title);
    final countLabel = songs.isEmpty ? null : '${songs.length}首';

    return Padding(
      padding: const EdgeInsets.only(right: 18),
      child: Semantics(
        button: true,
        label: '每日推荐，$headline',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPlay,
          child: SizedBox(
            height: dailyBannerHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF2F6DF6), Color(0xFF1B3FA8)],
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (covers.isEmpty)
                      const Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: EdgeInsets.only(right: 18),
                          child: Icon(
                            Icons.graphic_eq_rounded,
                            size: 96,
                            color: Color(0x33FFFFFF),
                          ),
                        ),
                      )
                    else if (covers.length == 1)
                      Image.network(
                        covers.first,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      )
                    else
                      // 两首歌的封面左右并置成一张拼贴：只铺一首会让「每日推荐」
                      // 看起来像某一张专辑的入口，两首歌的封面才读得出"这是一批歌"。
                      Row(
                        children: [
                          for (final url in covers)
                            Expanded(
                              child: Image.network(
                                url,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const SizedBox.shrink(),
                              ),
                            ),
                        ],
                      ),
                    // 两张封面之间会形成一条贯穿整张卡的竖向接缝。用一道柔和的
                    // 暗色过渡带把它压下去，读起来是暗角而不是一条被切开的分界线。
                    if (covers.length > 1)
                      Align(
                        alignment: Alignment.center,
                        child: FractionallySizedBox(
                          widthFactor: .2,
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.black.withValues(alpha: 0),
                                  Colors.black.withValues(alpha: .30),
                                  Colors.black.withValues(alpha: 0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.black.withValues(alpha: .42),
                            Colors.black.withValues(alpha: .70),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: .22),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  child: const Text(
                                    '每日推荐',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: .4,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                dateLabel,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: .86),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (countLabel != null) ...[
                                const SizedBox(width: 8),
                                Text(
                                  countLabel,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: .64),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const Spacer(),
                          Padding(
                            padding: const EdgeInsets.only(right: 56),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  headline,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 21,
                                    height: 1.2,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  caption,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: .84),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: _BannerPlayButton(onTap: onPlay),
                    ),
                  ],
                ),
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

  final VoidCallback onTap;

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
          color: Colors.white.withValues(alpha: .94),
          shadows: const [
            Shadow(
              color: Color(0x99000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
      ),
    );
  }
}

/// 每日推荐 Banner 的高度。
///
/// 此前这里是两张正方形卡，高度随宽度在 140–200 之间浮动，一屏里既占掉
/// 大量纵向空间、又因为尺寸随屏宽变化而让首屏节奏不稳定。Banner 用固定
/// 高度 + 横向铺满，首屏结构在任何宽度下都一致。
@visibleForTesting
const double dailyBannerHeight = 168;

/// 取 Banner 上要展示的封面，最多两张。
///
/// 优先用每首歌自己的封面；歌曲封面缺失时退回到整张推荐列表的封面，
/// 再去重——两首歌共用一张图时并排铺开会出现完全相同的两块，看起来像
/// 渲染错误，所以同一张图只留一次。
@visibleForTesting
List<String> dailyBannerCovers(DailyRecommend daily) {
  final urls = <String>[];
  void add(String? url) {
    if (url == null || url.isEmpty) return;
    if (urls.contains(url)) return;
    urls.add(url);
  }

  // 优先取歌曲自己的封面；不足两张时再用整张推荐列表的封面补齐。
  for (final song in daily.songs) {
    if (urls.length >= 2) break;
    add(song.coverUrl);
  }
  add(daily.coverUrl);
  return urls.take(2).toList(growable: false);
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

class _RadioSection extends StatefulWidget {
  const _RadioSection({required this.api, required this.player});

  final MusicApi api;
  final PlayerController player;

  @override
  State<_RadioSection> createState() => _RadioSectionState();
}

class _RadioSectionState extends State<_RadioSection> {
  static Future<_RadioData>? _cachedFuture;

  late Future<_RadioData> _future;
  String? _loadingStationId;

  @override
  void initState() {
    super.initState();
    _future = _cachedFuture ??= _load();
  }

  Future<_RadioData> _load() async {
    final results = await Future.wait([
      widget.api.fmRecommendedStations(),
      widget.api.fmClassGroups(),
    ]);
    final recommended = results[0] as List<FmStation>;
    final groups = results[1] as List<FmClassGroup>;
    final imageIds =
        [...recommended, ...groups.expand((group) => group.stations.take(4))]
            .where((station) => station.artworkUrl == null)
            .map((station) => station.id)
            .toList();
    final images = await widget.api.fmImages(imageIds);

    FmStation applyImage(FmStation station) {
      final image = images[station.id];
      return image == null ? station : station.mergeImage(image);
    }

    return _RadioData(
      recommended: recommended.map(applyImage).toList(),
      groups: groups
          .map(
            (group) => FmClassGroup(
              id: group.id,
              name: group.name,
              stations: group.stations.map(applyImage).toList(),
            ),
          )
          .toList(),
    );
  }

  Future<void> _refresh() async {
    final future = _load();
    _cachedFuture = future;
    setState(() => _future = future);
    await future;
  }

  Future<void> _playStation(FmStation station) async {
    if (_loadingStationId != null) {
      return;
    }

    setState(() => _loadingStationId = station.id);
    try {
      final songs = await widget.api.fmSongs(station);
      final queue = songs.isEmpty ? station.previewSongs : songs;
      if (!mounted) {
        return;
      }
      if (queue.isEmpty) {
        Toast.info('这个电台暂时没有可播放歌曲');
        return;
      }
      widget.player.playSong(queue.first, queue: queue);
    } catch (error) {
      if (!mounted) {
        return;
      }
      Toast.error('电台加载失败：$error');
    } finally {
      if (mounted) {
        setState(() => _loadingStationId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_RadioData>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (snapshot.connectionState == ConnectionState.waiting &&
            data == null) {
          return const _RadioSkeleton();
        }
        if (data == null && snapshot.hasError) {
          return _ErrorView(
            message: snapshot.error.toString(),
            onRetry: _refresh,
          );
        }
        final radio = data ?? _RadioData.empty;

        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionHeader(
                title: '推荐电台',
                action: IconButton.filledTonal(
                  tooltip: '刷新',
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh_rounded),
                  style: IconButton.styleFrom(
                    fixedSize: const Size.square(42),
                    shape: const CircleBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (radio.recommended.isNotEmpty)
                _RadioHeroCard(
                  station: radio.recommended.first,
                  loading: _loadingStationId == radio.recommended.first.id,
                  onTap: () => _playStation(radio.recommended.first),
                ),
              if (radio.recommended.length > 1) ...[
                const SizedBox(height: 14),
                _RadioStationRail(
                  stations: radio.recommended.skip(1).toList(),
                  loadingStationId: _loadingStationId,
                  onTap: _playStation,
                ),
              ],
              for (final group in radio.groups) ...[
                const SizedBox(height: 24),
                _SectionHeader(
                  title: group.name,
                  action: Icon(
                    Icons.radio_rounded,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                _RadioStationRail(
                  stations: group.stations,
                  loadingStationId: _loadingStationId,
                  onTap: _playStation,
                ),
              ],
              if (radio.recommended.isEmpty && radio.groups.isEmpty)
                const _RadioEmpty(),
            ],
          ),
        );
      },
    );
  }
}

class _RadioHeroCard extends StatelessWidget {
  const _RadioHeroCard({
    required this.station,
    required this.loading,
    required this.onTap,
  });

  final FmStation station;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 2.08,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: loading ? null : onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (station.bannerUrl ?? station.artworkUrl case final url?)
                  Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: .08),
                        Colors.black.withValues(alpha: .72),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Spacer(),
                      Text(
                        station.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        station.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: .82),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: _RadioPlayBadge(loading: loading),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RadioStationRail extends StatelessWidget {
  const _RadioStationRail({
    required this.stations,
    required this.loadingStationId,
    required this.onTap,
  });

  final List<FmStation> stations;
  final String? loadingStationId;
  final ValueChanged<FmStation> onTap;

  @override
  Widget build(BuildContext context) {
    if (stations.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: 182,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: stations.length,
        separatorBuilder: (_, _) => const SizedBox(width: 13),
        itemBuilder: (context, index) {
          final station = stations[index];
          return _RadioStationCard(
            station: station,
            loading: loadingStationId == station.id,
            onTap: () => onTap(station),
          );
        },
      ),
    );
  }
}

class _RadioStationCard extends StatelessWidget {
  const _RadioStationCard({
    required this.station,
    required this.loading,
    required this.onTap,
  });

  final FmStation station;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 128,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: loading ? null : onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Artwork(url: station.artworkUrl, size: 128, borderRadius: 8),
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: .42),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: _RadioPlayBadge(loading: loading, compact: true),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              station.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.16,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              station.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadioPlayBadge extends StatelessWidget {
  const _RadioPlayBadge({required this.loading, this.compact = false});

  final bool loading;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 30.0 : 42.0;
    return SizedBox(
      width: size,
      height: size,
      child: loading
          ? Center(
              child: SizedBox.square(
                dimension: compact ? 16 : 20,
                child: const CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Colors.white,
                ),
              ),
            )
          : Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: compact ? 22 : 30,
              shadows: const [
                Shadow(
                  color: Color(0x99000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
    );
  }
}

class _RadioSkeleton extends StatelessWidget {
  const _RadioSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SkeletonBox(width: 112, height: 24, radius: 8),
          const SizedBox(height: 14),
          const SkeletonBox(width: double.infinity, height: 168, radius: 16),
          const SizedBox(height: 22),
          const SkeletonBox(width: 90, height: 22, radius: 8),
          const SizedBox(height: 12),
          SizedBox(
            height: 164,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: 3,
              separatorBuilder: (_, _) => const SizedBox(width: 13),
              itemBuilder: (context, index) {
                return SkeletonBox(
                  width: index == 2 ? 76 : 128,
                  height: 164,
                  radius: 10,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RadioEmpty extends StatelessWidget {
  const _RadioEmpty();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 46, 10, 70),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.radio_rounded,
              size: 42,
              color: colorScheme.primary.withValues(alpha: .72),
            ),
            const SizedBox(height: 12),
            Text(
              '暂无电台内容',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

// ignore: unused_element
class _RadioUnsupported extends StatelessWidget {
  const _RadioUnsupported();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 54, 28, 166),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.radio_rounded,
            size: 42,
            color: colorScheme.primary.withValues(alpha: .72),
          ),
          const SizedBox(height: 14),
          Text(
            '电台暂不支持',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            '等接口准备好后再接入这个频道。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 166),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SkeletonBox(width: 54, height: 26, radius: 8),
                const SizedBox(width: 26),
                const SkeletonBox(width: 42, height: 26, radius: 8),
                const Spacer(),
                SkeletonBox.circle(size: 38),
                const SizedBox(width: 12),
                SkeletonBox.circle(size: 34),
              ],
            ),
            const SizedBox(height: 28),
            const SkeletonBox(width: double.infinity, height: 44, radius: 9),
            const SizedBox(height: 14),
            const SkeletonBox(
              width: double.infinity,
              height: dailyBannerHeight,
              radius: 16,
            ),
            const SizedBox(height: 28),
            const SkeletonBox(width: 128, height: 24, radius: 8),
            const SizedBox(height: 18),
            for (var index = 0; index < 6; index++) ...[
              Row(
                children: [
                  const SkeletonBox(width: 58, height: 58, radius: 8),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        SkeletonBox(
                          width: double.infinity,
                          height: 16,
                          radius: 6,
                        ),
                        SizedBox(height: 8),
                        SkeletonBox(width: 140, height: 14, radius: 6),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
            ],
          ],
        ),
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

class _RadioData {
  const _RadioData({required this.recommended, required this.groups});

  static const empty = _RadioData(recommended: [], groups: []);

  final List<FmStation> recommended;
  final List<FmClassGroup> groups;
}
