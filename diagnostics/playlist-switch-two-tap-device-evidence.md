# 换歌单后需要点击两次：实机复核证据（修复前 / 修复后）

设备：23049RAD8C（ee7d3743），应用 com.hoilai.mm.music。
采集：adb logcat（flutter / AudioManager / ActivityTaskManager）+ 系统媒体会话轮询。
原始日志含 URL 与令牌，不进入仓库；本文件只记录事件、时间与哈希。

## 构建

| 版本 | SHA256 | 说明 |
| --- | --- | --- |
| 修复前 | 4D6578705E2E8D305FDE6A138CFE4C59A33FFBBB9A14A2461942E080B4A869BF | 状态机修复，未处理队列刷新 |
| 修复后 | ACBF7B596D7DDCC6F1F84576BF125D7A26EDE2655BB58EC8584BD5F9D9FA6587 | 追加队列刷新不得吞掉点击 |

两次都用 `adb install -r` 覆盖安装，并通过 `pm path` + `adb pull` 回读
base.apk 校验哈希与本地构建产物一致（MATCH=True），确认设备跑的就是本次代码。

## 修复前的实机时间线（21:42–21:49）

24 次点击意图（load_intent），只有 14 次提交，10 次被放弃：8 次 resolve、2 次 cp3。

| 被放弃的点击 | 放弃位置 | 放弃时 queue 版本 | 随后的第二次点击 | 结果 |
| --- | --- | --- | --- | --- |
| 21:44:37.438 serial=2 queueIndex=1 | resolve | 1 → 2 | 21:44:38.684 serial=3 queueIndex=1 | committed |
| 21:44:44.447 serial=4 queueIndex=1 | resolve | 4 → 5 | 21:44:46.443 serial=5 queueIndex=1 | committed |
| 21:44:53.669 serial=6 queueIndex=3 | resolve | 7 → 8 | 21:44:54.298 serial=7 queueIndex=3 | committed |
| 21:45:12.561 serial=8 queueIndex=1 | resolve | 10 → 11 | 21:45:14.500 serial=9 queueIndex=1 | committed |
| 21:45:24.437 serial=10 queueIndex=4 | resolve | 13 → 14 | 21:45:25.565 serial=11 queueIndex=4 | committed |
| 21:45:35.130 serial=12 queueIndex=3 | **cp3**（音源已被替换） | 16 → 17 | 21:45:36.514 serial=13 queueIndex=3 | committed |
| 21:45:49.530 serial=14 queueIndex=0 | resolve | 19 → 20 | 21:45:50.561 serial=15 queueIndex=0 | committed |
| 21:49:46.380 serial=16 queueIndex=4 | resolve | 22 → 23 | 21:49:48.097 serial=17 queueIndex=4 | committed |

可核对的事实：

1. 每一次被放弃的点击，其队列版本（queue=）都比意图时刻 +1，说明加载期间发生过一次
   队列刷新（replaceQueue）。放弃事件的固定字段与 detail 字段的 serial 相同，
   因此放弃不是由更新的意图造成，而是由这次队列刷新造成。
2. 被放弃之后 0.5–1.7 秒必然出现一次 queueIndex 完全相同的新意图——用户重新点了同一行。
3. cp3 的两次（serial 5、12）已经完成"暂停 + 替换音源"，仍然没有提交：暂停已发生而条目未更新。
4. 修复前每次放弃都发生在 resolve 阶段，说明点击本身没有暂停播放器（旧"第一次只暂停"
   的现象已被状态机修复消除），但点击依然被静默吞掉。

## 修复后的实机复核（21:51 起，同一台设备）

覆盖安装 ACBF7B59… 并重启应用后：

- 10 次点击意图 → 10 次提交，0 次放弃，0 次失败；10 次 pause_for_load 全部对应同序号提交。
- 其中 6 次在 resolve 期间发生了队列刷新（queue 版本 +1）仍然正常提交：

| 点击 | 意图时 queue | 提交时 queue | 加载期间队列刷新 | 结果 |
| --- | --- | --- | --- | --- |
| 21:51:06.979 serial=2 | 1 | 2 | 是 | committed |
| 21:51:09.624 serial=3 | 3 | 4 | 是 | committed |
| 21:51:13.349 serial=4 | 5 | 6 | 是 | committed |
| 21:51:16.529 serial=5 | 7 | 8 | 是 | committed |
| 21:51:38.566 serial=7 | 10 | 11 | 是 | committed |
| 21:51:52.948 serial=8 | 12 | 13 | 是 | committed |

- 系统媒体会话（通知栏）在同一时刻显示已提交歌曲：`state=PlaybackState {state=3, ...}`
  且 metadata 为点击的歌曲，位置持续前进，说明"点一次即出声"。
- 截屏：diagnostics/rt-02-after-fix.png（修复后设备状态）。

## 结论

修复前剩余的"需要点两次"由第二个机制造成：歌单页在打开时会后台补拉整张歌单
（playlist_detail_page.dart 的 _startBackgroundQueueLoad → replaceQueue），
而 replaceQueue 走的 _invalidateNavigation() 会取消在途加载，于是用户刚点的歌被丢弃。
修复前 8/8 的放弃都发生在 resolve，2/2 发生在 cp3；修复后同类场景 6/6 正常提交。

日志原始文件：diagnostics/rt-logcat-focus.log（定向采集）、
diagnostics/rt-logcat-raw.log（21:42–21:44 全量）、
diagnostics/rt-session-timeline.log（每 1.2 秒记录一次通知栏歌曲与播放状态）。
