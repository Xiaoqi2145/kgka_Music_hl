import 'dart:async';

/// 把播放列表变更排成一条串行链。
///
/// **为什么需要**：`dropArmedNext` / `promoteArmedNext` 的「长度守卫 + 移除」
/// 是两步。若两步之间被一次 `setAudioSources([单个])` 插入，`removeAt(0)`
/// 就会作用在**刚加载的唯一音源**上，把播放列表清空——比残留第三子源更严重：
/// 控制器随后把 `_activePlaylistSource` 指向已不存在的音源，
/// `_ownsLoadedSource` / `_ownsPlaybackWindow` 将永远为 false，进度与歌词
/// 冻结到下一次加载。
///
/// 本类把「检查 + 变更」整体串行化，使其对其它变更原子。单测覆盖在本文件
/// 的对应测试中（真实 `MusicAudioHandler` 依赖平台通道，无法在单测里实例化）。
class PlaylistMutationSerializer {
  Future<void> _chain = Future<void>.value();

  /// 排队执行 [action]，返回它自己的结果。
  ///
  /// 链本身吞掉错误：一次失败不得让后续所有变更都无法开始。
  Future<T> run<T>(Future<T> Function() action) {
    final result = _chain.then((_) => action());
    _chain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
