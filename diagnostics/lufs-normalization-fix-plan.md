# LUFS 自动切歌延迟修复方案

## 范围与目标
仅制定方案，尚未修改业务代码、运行新增测试或安装 APK。不使用子代理，保留工作区用户修改。以 diagnostics/lufs-delay-confirmed-195458.log 为实机基线：新歌增益 0.804 与旧歌增益 0.902 相隔 15ms 交错，约 5.3 秒后才实际 setVolume=0.803526。

目标：新歌身份不回退；旧曲增益不能提交到新曲；3 秒首次自动归一化截止不能被索引重排/普通回调重置；已知增益尽快生效且不阻塞播放。未知响度明确旁路，迟到数据只缓存。不是延长窗口、定时重启或用渐变掩盖错误。

## 首要竞争窗口（需失败测试确认）
player_controller.dart:1106-1166：_onPlaylistIndexChanged 通过 _playlistSongs[index] 识别歌曲。切到 B 后调用 _trimPlaylistBefore(1)，先 await 原生删除索引 0 的 A，等完成才把 Dart 列表从 [A,B] 改为 [B]。若删除期间先发 index=0，回调仍以旧列表读成 A，重选归一化源并重新打开窗口。该路径与实机 B(-6.1) -> A(-7.1) 的日志顺序高度吻合，但不能把尚未验证的具体回调当成已证实根因。

同时检查：append 完成前的索引事件；drop tail 提前修改 Dart 映射而原生删除失败；旧 trim 完成后裁剪了新 load 的列表。

## 实施顺序

### 1. 先补可重复失败测试和关键日志
- 升级 test/player_normalization_test.dart 的 fake：现有索引/session/state 均为 Stream.empty，无法覆盖本问题。提供可控事件流、可挂起的 append/remove/load/setVolume，以及注入单调时钟。
- 构造 [A,B] -> 自动 index=1 -> 删除 A 时先发 index=0、后完成 remove Future 的顺序，断言 currentSong 永不回退 A、B generation 不再增长、B 增益不会被 A 替换。另测事件在 Future 完成之后才到达。
- 日志包含 entryId、songKey、quality、playlistRevision、playbackGeneration、applyRevision、sessionId、触发原因、单调时间、窗口起点/剩余时间；记录请求/执行/返回/丢弃/旁路原因。
- 将现有 Applied 拆分为 gain_resolved、effect_ack、volume_requested、volume_ack，避免把服务内部计算完成等同于实际生效。Dart ack 仍不是首帧声学测量；ADB AudioTrack 日志作旁证。不得输出播放 URL 或令牌。

### 2. 修复播放源身份与列表变更一致性（P0）
- 使用带稳定身份的播放条目：entryId（每次播放实例独立）、songKey、quality、URL。URL 不写入诊断日志。为 AudioSource 附上 tag，优先从 just_audio 同一 sequenceState 快照里的 currentSource/tag 判定当前条目，不再以独立索引事件查另一份可变列表。先核对锁定版本的 sequenceState/tag API。
- 同一条目因删除头部而 index 1->0，仅是索引重排；不切歌、不 begin、不重置窗口、不重复记录历史。相同歌曲重新播放或重复队列条目则按新播放实例处理；音质切换显式改变源身份。
- 若版本 API 不能提供一致快照，采用带 playlistRevision 的列表变更事务：变更期间缓存事件，完成后按最终序列统一协调。不能简单提前 sublist 或仅用布尔标志丢事件。
- load/append/remove/trim/drop-tail 统一管理 revision；旧异步完成不得改写新列表。失败后从实际播放器序列校准，不假装删除成功；明确处理部分成功。必要时只串行化列表结构变更，不能把播放控制/响度网络请求放入长队列。

### 3. 归一化提交增加端到端身份保护（P0）
- 每次请求捕获不可变上下文：entryId、quality、playbackGeneration、settingsRevision、sessionId、gain、首次应用截止点。不能在异步完成后用当时的全局 generation 给旧结果重新授权。
- 数据返回、原生效果执行前/后、setVolume 提交前/后均核对上下文。已进入原生的调用不能靠 Dart 失效标记撤回；需要最终状态协调，不能宣称加检查即可取消在途操作。
- 对同一条目、设置、session 的重复调用去重；待执行工作只保留最新目标，过期任务返回明确 stale 状态，而非 1.0，避免把失效误认为应旁路。
- _normalizationVolume 和 markApplied 只由有效请求确认；ducking 使用最新归一化目标独立组合，不允许恢复中断时带回旧曲增益。

### 4. 固定 3 秒语义与原生执行边界（P1）
- 3 秒是首次自动应用截止，而非等待 3 秒再应用。窗口以真实播放条目的首个 playing+ready/媒体切换时间为基准，用单调时钟；普通 session 回调、列表 trim、暂停恢复不能重开。显式设置变更允许新 settingsRevision 的立即应用；同曲 seek 不算新曲。
- 已知响度直接采用当前曲目标，避免先恢复 1.0 再衰减的闪变。未知响度不沿用上一首增益，进入明确旁路；超时数据仅缓存下次播放，不能通过 session/重试偷渡应用。
- 已经在窗口内落实的增益可在 session 重建后恢复，不应被视作迟到首次应用。
- 不盲目把衰减 setVolume 提前到 disableLoudnessEnhancer 之前：旧 boost 未清理可能叠加造成突响。跟踪原生 enhancer 状态，安全跳过确认为关闭时的冗余 disable；未知状态执行明确、安全的过渡。
- 队列/原生延迟先测量。若确有原生等待跨截止问题，再扩展 Android 协议携带 revision 与原生单调时钟 deadline，在副作用前拒绝过期操作，并补失败协调。不能仅 Future.timeout 后继续并发操作：timeout 不取消在途原生调用，也不能直接比较 Dart Stopwatch 与 Android 时钟。

## 回归矩阵
1. A->B 自动预载切歌，trim 的索引事件早于/晚于 Future 完成。
2. trim 期间 load C；快速 A->B->A；同曲重复条目；音质重载。
3. append/remove 失败、部分成功、迟到事件；列表和实际播放身份保持一致。
4. B 的响度已缓存、2.9 秒到达、恰好 3 秒、5 秒才到达；迟到只缓存。
5. 原生调用挂起时切歌/关闭归一化；旧结果不得落到新歌。
6. 衰减->衰减、boost->衰减、衰减->boost、已知->无数据；无短暂过量增益。
7. session 重建、通知 duck/恢复、暂停恢复、seek 到尾部；首次窗口不被误重置。
8. 播放/seek 不等待网络或原生长任务；多轮切歌无在途任务和监听器持续增长。

## 文件范围
主要：lib/controllers/player_controller.dart、lib/services/music_audio_handler.dart、lib/services/playback_loudness.dart、lib/services/volume_normalization_service.dart。
测试：test/player_normalization_test.dart、test/playback_loudness_test.dart、test/volume_normalization_service_test.dart，必要时新增播放列表协调器测试。
Android MainActivity.kt 仅在原生边界确需增强时改动；不顺带重构无关 UI/下载代码。

## 验证及交付门槛
- 先看到故障用例在修复前失败、修复后通过；运行相关 flutter test、全部 test 与 flutter analyze，并区分已有失败和本次新增失败。
- 构建诊断 APK，记录源码提交/差异摘要和 APK SHA256；安装会重启进程，实施验证前明确告知，保存原始日志，不能以新进程结果冒充原 9.5 小时进程的修复验证。
- 实机复测本次同一曲对，分别冷缓存/热缓存、预载开/关、手动 next/自然尾切；连续至少 30 次尾切。
- 验收：无 A->B->A 身份回退、无旧曲增益实际提交；有缓存数据时从媒体切换到正确 setVolume 目标常态 <=300ms，作为性能目标需实测；不允许首次自动增益超过 3 秒后再落地。无数据必须记录明确旁路原因，不能把始终 1.0 当归一化通过。
- 补至少 10 小时的连续/间歇播放 soak，定期尾切、记录延迟分布/待执行数/内存。无长期实测前，只能声明短期回归通过，不能声明长期运行问题已解决。

## 推荐拆分
第一批提交：可复现测试 + 一致播放源身份 + 列表 revision 防护 + 必要日志。
第二批提交：归一化端到端提交和截止边界加固，按实测决定是否需要原生协议扩展。
不要先上轮询补偿、延长窗口、定时清播放器或响度渐变来掩盖身份错误。
