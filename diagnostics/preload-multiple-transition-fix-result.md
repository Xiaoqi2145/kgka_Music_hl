# 尾段连续切换修复结果（第一阶段）

## 交付范围

依据 `preload-multiple-transition-fix-plan.md` 的第一阶段实施。默认使用单音源稳定策略，保留下一曲 URL、响度、歌词和封面的后台解析/缓存。不启用第二阶段动态无缝音源协议；暂时不承诺样本级无缝接续。原方案文档保留未改。

## 实现

- `lib/controllers/player_controller.dart`：删除预载 append、tail remove、trim 和 sequenceState 驱动的业务换歌；序列变化只记结构日志。加载操作串行化，完成确认时检查请求代次与单音源归属。
- `lib/services/transition_coordinator.dart`：每次成功加载生成独立 entryId；completion lease 绑定 entryId、seekRevision、requestRevision，并一次性消费。重复歌曲、单曲循环与 A→B→A 不按 hash 合并播放实例。
- 候选固定绑定 ownerEntryId、queueRevision、请求音质及预解析请求版本。预解析未返回时手动 next 也保留已抽出的随机候选。暂停保留有效缓存，但撤销旧导航/播放请求。
- 原生完成处理使用同一 PlaybackEvent 的位置、时长、状态，并检查当前已确认单音源、最新事件及媒体事件时间。旧独立 position/duration 回调不作为完成依据。
- 移除 750ms/220ms 位置完成兜底：现有 Dart 事件无法可靠证明带条目归属的末尾停滞，宁可等待 native completed，也不推测提前跳曲。
- `_commitPlayback` 在加载成功后统一提交歌曲、entryId、音质、归一化代次、起点、媒体通知、歌词请求、历史/统计。预解析和失败加载不提交这些展示副作用；歌词展示结果同时校验 entryId 与请求版本。响度算法和 3 秒窗口规则未修改。
- `lib/services/music_audio_handler.dart`：移除动态音源增删接口；队列/媒体元数据在控制器提交时发布。通知栏 seek 进入控制器，同样参加 seek/request 失效机制。无条目归属的运行时错误不再自动重播，避免恢复旧请求或误播新条目。
- 诊断记录事件来源、条目、候选 owner、queue/load/seek/request revision、单调计时、结构 sourceIds 和提交原因。sourceIds 是 Dart 对象身份，不冒充原生稳定媒体 ID。

## 失败测试与回归

先加入 cache-only 断言，旧代码实际得到 2 个音源而非 1，三个原场景均失败。复查另新增“旧完成解析不能阻挡新条目完成”测试，确认原全局 completion 布尔锁会失败，随后移除跨条目锁，由一次性 lease 单独去重。

`test/player_normalization_test.dart` 覆盖：

- Dart 结构先改、旧平台索引随后到达及多次结构推进，不提交歌曲/歌词/媒体通知/音量。
- 旧尾部位置、旧时长、旧 completed 快照和晚于新加载才投递的旧媒体快照，不能跳过 B。
- ready/buffering 最后 750ms 不提前跳曲。
- 按 20:18:27.231、34.236、49.384 时间点注入事件，仅在真实 completed 后提交；这是控制器时间线回归，不是原设备声学记录重演。
- 7 秒和 15 秒延迟 API 响应模拟（测试实际等待相应时长），响应完成仍只缓存。
- seek/previewSeek、next、previous、pause、换队列、换音质与迟到响应。
- 同曲重复队列项、单曲循环、随机固定候选、预解析未返回时 next。
- 统一 load ack 提交、暂停中取消加载、预解析 URL 加载失败后回退、已开始 next URL 解析时换队列、歌词乱序返回。

`test/transition_coordinator_test.dart` 覆盖独立条目和一次性 completion、旧 A/B lease、30 轮模拟完成、30 轮 seek 往返及不同导航意图撤销。模拟次数不能折算为实机验收次数。

## 最终验证

- `flutter test`：**82 项通过**，约 25 秒。
- 修改的 5 个 Dart 文件定向 `dart analyze`：**No issues found**。
- `flutter analyze --no-fatal-infos`：退出 0，无 error/warning；仓库其他文件仍有 **10 条既有 info 级 lint**（api_client、music_api、playback_history_service、login_page）。严格的 `flutter analyze` 不能称为全仓零提示。
- `git diff --check`：通过；仅 Git 的 LF/CRLF 提示。
- `flutter build apk --release --target-platform android-arm64`：成功，22.5 MB；有 file_picker 的未来 KGP 兼容性警告，不影响本次构建。

APK：`build/app/outputs/flutter-apk/app-release.apk`

大小：23,607,691 字节。SHA-256：`DB0C73EA2BE1C3E12F0CDC8DBAC949472A4733F2FA3653411BB500DCFDFCBE6A`。

## 实机短时检查

已对连接设备 23049RAD8C 进行 `adb install -r` 保留数据覆盖安装，结果 Success。`com.hoilai.mm.music/.MainActivity` 冷启动 Status ok，TotalTime 620ms。进程 PID 11357，已查看播放器封面/歌词/进度截图。

`preload-stable-transition-events.log` 中可确认：

- 20:48:54.020：显式加载提交 entry=1。
- 20:49:19.801 → 19.855：entry=1 seek start/ack，期间 sourceIds 稳定，不产生新 committed。
- 20:50:02.177：entry=1 native_completed。
- 20:50:02.233：恰好一次 reason=native_completed 的 entry=2 提交。之前的结构通知没有业务提交。
- 20:50:41.293 → 41.373：entry=2 seek start/ack，entry 不变。

这只是一段短时设备事件观察，不能证明声学切歌起点、所有缓存/网络路径或连续 UI 零闪动。所提取事件中没有 FATAL EXCEPTION/Unhandled Exception。原始 smoke 日志另出现歌词磁盘缓存文件名过长的非致命警告，截图中的歌词仍能显示；该缓存键问题未纳入本次切歌修复。

## 未完成的长期验收 / 明确边界

- **未完成 30 次实机自然尾切 + 30 次实机尾部往返拖动。**
- **未完成冷/热缓存和真实慢网络的完整实机矩阵、屏幕录像与声学关联。**
- **未完成至少 10 小时运行验证。**
- just_audio 仍不提供第二阶段要求的独立原生 entryId/loadVersion/事件序号协议；本次安全性依赖受控单音源与显式加载边界，不能将当前过滤逻辑用于恢复动态 append。
- 代码、测试、构建和短时安装/播放检查已经完成；不将这些结果表述为长期实机完全验收。未 commit、未 push。
