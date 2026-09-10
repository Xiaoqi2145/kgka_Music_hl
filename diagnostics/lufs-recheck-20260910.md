# LUFS 生效延迟复查

未重启、未安装 APK、未改业务代码；本轮未调用子代理。

## 已确认
- PID 19770 连续运行约 9.5 小时。
- 手机 APK SHA256 与本地 release APK 一致：02dadaec724443203a090523e71f6034e306ea5926b65cc7618f4b236a6b842c。无法仅凭哈希证明 APK 对应当前未提交源码。
- 用户回忆曾拖动到上一首尾部，因此 AudioTrack start 不能直接当作下一首起点。
- 当前曲目：櫻ノ詩 (樱之诗) / はな。
- 两次 MediaSession 快照：position=134686, updated=51651008；position=149712, updated=51666034。二者 updated-position 均为 51516322 ms，表明期间正常连续播放。
- 对照设备墙钟及 uptime，当前歌曲媒体时钟零点约为 19:47:09（墙钟采样只有秒级精度，且非原生首帧时间）。

## 时间线
- 19:46:55.538 AudioTrack 294 启动，已有音量 0.431818；结合用户描述，此处是上一首拖动后继续播放，不应作为当前曲目起点。
- 19:47:08.119 创建新 FLAC 解码器，08.165 开始处理。解码器启动不等于首帧出声。
- 19:47:09.319 VolumeNorm Applied，LUFS=-8.9，gain=0.432，-7.3dB。与上一首增益相同，日志不包含歌曲 key / generation / 调用来源，无法判定是否旧任务。
- 19:47:11.276 AudioTrack 音量恢复 1.0，即相对之前提高约 7.3dB。

## 判断
抓到了切歌附近音量从 0.432 到 1.0 的明显变化。按当前曲目媒体时钟反推，约发生在开播 2～3 秒附近，不能把上一首拖动后的 15.74 秒直接解释为归一化延迟。现有日志无法严格确认是否超过 3 秒，也无法确认是迟到的首次归一化、旧曲增益残留后旁路，还是设置变化。未证明长期运行导致队列堆积。

当前源码检查：_selectNormalizationSource 重置元数据窗口但不会立即清理 _normalizationVolume；_onPlaylistIndexChanged 异步应用增益，因此过渡期间可能保留上一首音量。原生 MethodChannel 串行等待无超时；这些是待验证风险，不是本事件已确认根因。

建议下次捕获 song key / generation / 原生媒体切换时刻 / ready 与 position / 窗口起点 / apply 请求、入队、执行、返回 / setVolume 请求与实际执行 / bypass 原因及设置操作。不得只用 AudioTrack start 或 Applied 日志推断首帧与增益起点。

日志文件 lufs-recheck-20260910.log 为本次保存的进程日志尾部，不是完整历史。
