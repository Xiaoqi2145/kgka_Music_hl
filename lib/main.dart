import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';

import 'config/app_config.dart';
import 'controllers/auth_controller.dart';
import 'controllers/download_controller.dart';
import 'controllers/player_controller.dart';
import 'controllers/local_music_controller.dart';
import 'controllers/theme_controller.dart';
import 'core/api_client.dart';
import 'services/artwork_cache_service.dart';
import 'services/cache_service.dart';
import 'services/download_service.dart';
import 'services/music_audio_handler.dart';
import 'services/music_api.dart';
import 'ui/adaptive_layout.dart';
import 'ui/app_theme.dart';
import 'ui/pages/app_shell.dart';
import 'ui/pages/login_page.dart';
import 'ui/widgets/toast.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.loadCustomBaseUrl();

  final client = ApiClient();
  final api = MusicApi(client);
  final audioHandler = await AudioService.init(
    builder: MusicAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'kgka_music_hl.playback',
      androidNotificationChannelName: 'KA Music 播放控制',
      androidStopForegroundOnPause: false,
    ),
  );

  final themeController = ThemeController();
  await themeController.load();

  runApp(
    KaMusicApp(
      client: client,
      api: api,
      audioHandler: audioHandler,
      themeController: themeController,
    ),
  );
}

class KaMusicApp extends StatefulWidget {
  const KaMusicApp({
    super.key,
    required this.client,
    required this.api,
    required this.audioHandler,
    required this.themeController,
  });

  final ApiClient client;
  final MusicApi api;
  final MusicAudioHandler audioHandler;
  final ThemeController themeController;

  @override
  State<KaMusicApp> createState() => _KaMusicAppState();
}

class _KaMusicAppState extends State<KaMusicApp> with WidgetsBindingObserver {
  late final ApiClient _client;
  late final MusicApi _api;
  late final CacheService _cacheService;
  late final DownloadService _downloadService;
  late final DownloadController _downloads;
  late final AuthController _auth;
  late final PlayerController _player;
  late final ThemeController _theme;
  late final LocalMusicController _localMusic;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.client;
    _api = widget.api;
    _cacheService = CacheService();
    _downloadService = DownloadService();
    _downloads = DownloadController(_downloadService, _api);
    _auth = AuthController(_api, _cacheService);
    _localMusic = LocalMusicController();
    _player = PlayerController(_api, widget.audioHandler)
      ..downloadController = _downloads
      ..cacheService = _cacheService;
    // 接续上次退出时的播放会话（队列 + 当前歌曲 + 进度，不自动播放）。
    unawaited(_player.restorePlaybackSession());
    _theme = widget.themeController;
    _auth.restore();
    _downloads.initialize();
    // 加载缩略图缓存上限并扫描一次缓存目录，超额时按 LRU 淘汰。
    unawaited(ArtworkCacheService.instance.initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _auth.dispose();
    _player.dispose();
    _downloads.dispose();
    _localMusic.dispose();
    _downloadService.dispose();
    _client.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        _player.setAppForeground(true);
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _player.setAppForeground(false);
        unawaited(_player.flushPersistence());
    }
  }

  @override
  Widget build(BuildContext context) {
    _theme.applyOrientations(AdaptiveLayout.isTablet(context));
    return AnimatedBuilder(
      animation: _theme,
      builder: (context, _) {
        return MaterialApp(
          title: AppConfig.appName,
          debugShowCheckedModeBanner: false,
          navigatorKey: Toast.navigatorKey,
          themeMode: ThemeMode.system,
          theme: AppTheme.light(
            seedColor: _theme.seedColor,
            transparentBackground: _theme.backgroundEnabled,
          ),
          darkTheme: AppTheme.dark(
            seedColor: _theme.seedColor,
            transparentBackground: _theme.backgroundEnabled,
          ),
          builder: (context, child) {
            return _AppBackground(
              themeController: _theme,
              child: _SystemUiOverlay(child: child ?? const SizedBox.shrink()),
            );
          },
          home: AnimatedBuilder(
            animation: _auth,
            builder: (context, _) {
              if (!_auth.isRestoring && !_auth.isLoggedIn) {
                return LoginPage(auth: _auth, api: _api);
              }

              return AppShell(
                api: _api,
                auth: _auth,
                player: _player,
                cache: _cacheService,
                downloads: _downloads,
                theme: _theme,
                localMusic: _localMusic,
              );
            },
          ),
        );
      },
    );
  }
}

/// 全局背景图层。
///
/// 当用户启用了自定义背景图时，在所有页面内容下方显示背景图，
/// 并叠加半透明遮罩（由 [ThemeController.backgroundOpacity] 控制）。
class _AppBackground extends StatefulWidget {
  const _AppBackground({required this.themeController, required this.child});

  final ThemeController themeController;
  final Widget child;

  @override
  State<_AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<_AppBackground> {
  ImageProvider<Object>? _imageProvider;
  String? _imageCacheKey;
  ImageStream? _liveImageStream;
  ImageStreamListener? _liveImageListener;
  String? _liveImageKey;

  ImageProvider<Object> _providerFor(
    String path,
    int cacheWidth,
    int cacheHeight,
  ) {
    final key = '$path@$cacheWidth*$cacheHeight';
    if (_imageProvider != null && _imageCacheKey == key) {
      return _imageProvider!;
    }

    final provider = ResizeImage.resizeIfNeeded(
      cacheWidth,
      cacheHeight,
      FileImage(File(path)),
    );
    _imageProvider = provider;
    _imageCacheKey = key;
    _keepImageAlive(provider, key);
    return provider;
  }

  void _keepImageAlive(ImageProvider<Object> provider, String key) {
    if (_liveImageKey == key) return;
    _releaseLiveImage();

    final listener = ImageStreamListener(
      (imageInfo, _) => imageInfo.dispose(),
      onError: (_, _) {},
    );

    try {
      final stream = provider.resolve(createLocalImageConfiguration(context));
      _liveImageStream = stream;
      _liveImageListener = listener;
      _liveImageKey = key;
      stream.addListener(listener);
    } catch (_) {
      _liveImageStream = null;
      _liveImageListener = null;
      _liveImageKey = null;
    }
  }

  void _releaseLiveImage() {
    final stream = _liveImageStream;
    final listener = _liveImageListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _liveImageStream = null;
    _liveImageListener = null;
    _liveImageKey = null;
  }

  @override
  void dispose() {
    _releaseLiveImage();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.themeController,
      child: widget.child,
      builder: (context, child) {
        final path = widget.themeController.backgroundImagePath;
        final enabled = widget.themeController.backgroundEnabled;

        if (!enabled || path == null) {
          _releaseLiveImage();
          return child ?? const SizedBox.shrink();
        }

        final isDark = Theme.of(context).brightness == Brightness.dark;
        final overlayColor = isDark ? const Color(0xFF06070A) : Colors.white;
        final opacity = widget.themeController.backgroundOpacity;
        final mediaQuery = MediaQuery.of(context);
        final targetSize = mediaQuery.size * mediaQuery.devicePixelRatio;
        final imageProvider = _providerFor(
          path,
          targetSize.width.ceil(),
          targetSize.height.ceil(),
        );

        return Stack(
          children: [
            // 背景图层
            Positioned.fill(
              child: RepaintBoundary(
                child: Image(
                  image: imageProvider,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
            // 半透明遮罩（opacity 越大遮罩越透明，背景图越明显）
            Positioned.fill(
              child: ColoredBox(
                color: overlayColor.withValues(alpha: 1.0 - opacity),
              ),
            ),
            // 页面内容
            child ?? const SizedBox.shrink(),
          ],
        );
      },
    );
  }
}

class _SystemUiOverlay extends StatelessWidget {
  const _SystemUiOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: colorScheme.surface,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: child,
    );
  }
}
