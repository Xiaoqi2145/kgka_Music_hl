# 换歌单后需要点击两次才能播放：修复结果

依据 diagnostics/playlist-switch-two-tap-fix-plan.md 实施，根因证据见
diagnostics/playlist-switch-two-tap-evidence.md。

## 已完成（对应方案第 3、4、5 节）

### 1. 加载生命周期改为带检查点的状态机

player_controller.dart 的 _playSong 现在是
intent → resolve → claim → replace → commit → play：

- **intent**：`++_loadSerial` 作废旧意图，`_transitions.beginIntent()` 同时撤销旧的
  完成/异步租约。此阶段只记录目标歌曲、队列上下文与音质，不碰播放器。
- **resolve**（`_resolveSource`）：本地音源优先 → 预解析地址 → 网络（含音质梯度），
  只解析 URL 与响度，**不再暂停、不再替换音源**；每次网络往返前后调用
  `alive('resolve')`，过期即抛 `_LoadSuperseded`。
- **claim**（cp1/cp2）：连续两次检查意图仍是新的，才允许暂停。
- **replace**（`_replaceCommittedSource`）：暂停与 `setAudioSources` 在同一临界区内
  完成，中间没有业务逻辑；原生加载在 `_sourceLoadChain` 上串行，多个意图不会交叉替换。
  进入该阶段后不再放弃，只在 cp3 决定是否提交。
- **commit**：展示、歌词、通知栏、响度代次与历史仍只由 `_commitPlayback` 产生，
  且属于同一个 entryId。
- **play**：播放请求失败只给出可见错误，不改动已提交条目。

被取代的点击因此只可能在 cp1/cp2 退出，这两个点都不改变播放器状态：第一次点击
不会再"只暂停"。

### 2. 音源替换原子化

music_audio_handler.dart 的 `loadSong` 增加 `start` 与 `loadSerial` 参数：

- 暂停与替换紧邻，入口不再有"先暂停再等网络"的窗口。
- 使用 just_audio 0.10.5 已支持的 `setAudioSources(..., initialPosition: start)`
  完成起始定位，省掉换音质时额外的 seek 往返。
- 打印 `event=pause_for_load serial=...`，用于复核不变量 3。

### 3. 失败回滚

`_recoverPreviousEntry`：进入临界区之后失败时，重新解析并加载上一有效条目、
恢复进度、必要时恢复播放，并保留可见错误；回滚本身失败则只给出"播放失败，请重试"，
不自动重试。冷启动（没有可回滚条目）时回到 idle，而不是停在"已暂停且无条目"。

### 4. 复用判定

删除 `identical(song, current)` 快速路径：点击一首歌一律从头播放，跨歌单点击同一首歌
必然重新加载。队列增删改改走新的 `updateQueueContext`（只更新队列、保持进度），
不再靠对象同一性猜意图。换音质走 `preserveProgress: true` 的同一个状态机，
不再是一份平行的加载实现。

### 4.5 队列刷新不得吞掉在途点击（实机复核后追加）

实机复核发现第二个会造成"点两次"的机制：歌单页打开时会在后台补拉整张歌单
（playlist_detail_page.dart 的 _startBackgroundQueueLoad → replaceQueue），
而 replaceQueue/addToQueue/updateQueueContext 走的 _invalidateNavigation()
既作废工作租约也作废在途的加载意图，于是用户刚点的歌被静默丢弃，必须再点一次。
修复前 8/8 次 abandon 都发生在 resolve、2/2 发生在 cp3，全部由这一次队列刷新触发。

改动：

- TransitionCoordinator 把"加载意图"从"工作/完成租约"里拆出来：意图只由更新的意图、
  seek 或显式 `invalidateIntents()`（seek、换音质、暂停、打断）作废；
  `invalidateWork()`（队列刷新、预解析重置）不再影响在途点击。
- replaceQueue / addToQueue / updateQueueContext 不再调用 _invalidateNavigation()，
  改为 `_clearPreparedNext()`（预解析与旧完成租约作废）+
  `_cancelLoadIntentIfSongLeftQueue()`：只有本次加载的目标歌曲确实离开了队列时才作废意图。
- 提交时按当前队列重新定位 _committedQueueIndex，避免解析期间队列被刷新后索引错位。

### 5. 追踪字段

在 `[KA Music][transition]` 每行固定输出 entry / serial / quality / queue / load /
seek / request / monoUs，事件新增：
load_intent、load_claim、load_abandoned(stage,serial)、load_resolve_failed、
load_replace、load_replace_failed、load_fail、load_recovered、load_recover_failed、
play_requested、play_confirmed、pause_for_load(handler)。不输出 URL、令牌与歌词内容。

### 6. 界面中间态

控制器暴露 `preparingSongKey` 与 `isPreparingSong(song)`。MiniPlayer 在加载时把
播放按钮换成加载指示器；歌单行（playlist_detail_page、home_page 歌曲行）在
该 key 匹配时显示同一指示器。加载失败保留已提交条目并显示可重试错误。

## 业务文件

- lib/controllers/player_controller.dart
- lib/services/music_audio_handler.dart
- lib/services/transition_coordinator.dart
- lib/ui/widgets/preparing_indicator.dart（新增）
- lib/ui/widgets/mini_player.dart
- lib/ui/pages/playlist_detail_page.dart
- lib/ui/pages/home_page.dart
- test/player_normalization_test.dart
- test/transition_coordinator_test.dart

## 验证

### 实机复核（23049RAD8C，ee7d3743）

- 覆盖安装并回读 base.apk 校验哈希：修复前 4D657870…、修复后 ACBF7B59…（与本地构建一致）。
- 修复前：24 次点击只有 14 次提交，10 次被放弃（8 次 resolve、2 次 cp3），
  每次放弃后 0.5–1.7 秒用户都重新点了同一行才播放。
- 修复后：10 次点击 10 次提交，0 放弃、0 失败；其中 6 次在解析期间发生队列刷新
  （queue 版本 +1）仍正常提交，通知栏显示已提交歌曲且位置前进。
- 证据：diagnostics/playlist-switch-two-tap-device-evidence.md、
  diagnostics/rt-logcat-focus.log、diagnostics/rt-session-timeline.log。

### 回归测试

新增回归测试（方案第 6 节逐条对应）：

1. `a second tap while the first is resolving commits only the newest`：
   第一次点击的 /song/url 挂在 Completer 上，第二次点击先提交；断言
   `handler.loads == [song, c]`、原生替换只有 2 次、第一次点击期间
   `audioPlayer.playing` 保持为真、过期点击不再重复请求 B。
2. `rapid taps A to B to C commit only C once`：B、C 均挂在网络上，第三次点击
   先提交；断言只有 D 提交、原生替换与播放请求各一次、通知栏只写一次。
3. `a failed replace rolls back to the previous entry and its position`：
   原生替换抛错后自动回滚到上一首歌并恢复到 42 秒，errorMessage 可见。
4. `tapping the playing song from another queue reloads it`：队列上下文变化即视为
   新播放，不做静默队列同步，也不同一性复用。
5. `a seek during a pending load cannot pause the player` 与
   `queue edits keep the current entry without reloading it`：加载中的 seek /
   队列编辑都不会让播放器停在"已暂停且无当前条目"。
6. `invariant: no native replace without a committed entry`：在原生替换回调中注入
   断言，任意一次暂停+替换发生时都必须已有已提交条目。
7. `a queue refresh during a pending resolve keeps the tap alive`：
   解析期间 replaceQueue 只换队列，点击继续提交（实机缺陷的直接复现）。
8. `a queue edit that drops the pending song cancels that load`：
   目标歌曲离开队列时该次加载作废，播放器保持原条目。
9. transition_coordinator_test.dart 新增 4 条：beginIntent 撤销旧意图、
   队列刷新只作废工作租约不作废意图、显式取消作废意图、commit 结束自身意图、
   seek 在触碰播放器前撤销意图。

命令结果（diagnostics/playlist-switch-two-tap-validation.log）：

- `flutter test --no-pub`：95 tests passed（修复前 82）。
- `flutter analyze --no-pub --no-fatal-infos`：0 error / 0 warning，
  10 条 info 全部是本次未触碰文件里原有的提示。
- `flutter build apk --release`：成功，退出码 0；
  build/app/outputs/flutter-apk/app-release.apk，61559997 bytes，
  SHA256 ACBF7B596D7DDCC6F1F84576BF125D7A26EDE2655BB58EC8584BD5F9D9FA6587
  （队列刷新修复之前的那次构建为 4D657870…）。
  已核对构建产物 `lib/arm64-v8a/libapp.so` 中存在 load_abandoned / pause_for_load /
  load_recovered 字符串，确认 APK 来自本次修复代码。
- `git diff --check` 通过（仅 CRLF 提示）。

## 边界

- 实机复核覆盖 21:42–21:53 的两段会话（修复前 24 次点击、修复后 10 次点击），
  由用户手动切换歌单与点击，未做长时间或弱网压力测试；冷启动、慢网络下的表现
  仍以同样的日志打点（load_intent / pause_for_load / load_abandoned）复核。
- 修复前的"第一次只暂停"已由状态机消除（放弃只发生在 resolve，未触碰播放器），
  实机剩余症状（必须点两次）由队列刷新造成，已在本轮一并修复。
- 未改动响度算法与 3 秒窗口；未恢复已删除的动态音源 append/trim 链路；
  未使用固定延时、防抖或忽略首次点击。
- 原生 `setAudioSources` 失败后的重试次数与旧实现一致（预解析地址一次 + 音质梯度
  各一次），不做无限重试；纯本地文件没有网络回退，直接回滚。
