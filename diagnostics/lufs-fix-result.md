# LUFS 自动切歌竞争修复结果

## 已完成
- 先用可控原生时序复现故障：remove 的 index=0 通知在完成确认前发出时，旧代码把 B 误选回 A；测试实际失败 Expected B / Actual A，并再次输出 A 的增益。
- 切换到 sequenceStateStream，以同一快照的 currentSource/tag 判断曲目，使用 IndexedAudioSource 对象身份区分播放实例。拒绝过期快照，重复快照和索引重排不会重选响度源。
- AudioSource 在创建时附加 Song tag。列表镜像从实际序列快照同步，trim 不再 await 完成后按旧下标裁剪另一份列表。
- load revision 和当前音源身份保护旧 trim 完成；尾部清理基于实际音源位置，不删除已经成为当前曲的预载项；失败明确记录。
- 归一化日志区分 gain_resolved / volume_requested / volume_ack，附带 key、generation、serial、reason、session、局部耗时。没有改变 LUFS 公式或延长 3 秒窗口。

## 业务文件
- lib/controllers/player_controller.dart
- lib/services/music_audio_handler.dart
- lib/services/volume_normalization_service.dart
- test/player_normalization_test.dart

## 验证
- 修复前失败测试：Expected B / Actual A。
- 修复后同一测试通过。补测删除失败、裁剪期间加载 C、迟到旧快照、每种场景 30 次重复状态快照；未发生旧曲回退或重复音量提交。30 次是模拟状态通知，不是实机 30 次自然切歌。
- 全量 flutter test：55 tests passed。最后仅给测试 teardown 的 if 增加花括号，无测试行为变化。
- 最终 flutter analyze --no-pub --no-fatal-infos：无 error/warning，11 条原有 info；新增 info 已清理。diagnostics/lufs-fix-validation.log 保存的是清理最后一条测试花括号提示之前的全量测试/分析输出。
- git diff --check 通过（仅 Git CRLF 提示）。
- flutter build apk --release --no-pub 成功，file_picker 有未来 Flutter/Kotlin 插件兼容性警告，未阻塞构建。

## APK
build/app/outputs/flutter-apk/app-release.apk
大小：61559997 bytes（约 58.7 MiB）
SHA256：33DEC8A69DD3227B1ECDEB5F72381F79A9EA508929C4F721978977643D46DF36

## 边界
本轮未调用子代理，保留原有未提交修改。APK 从当前完整工作区构建，因此也包含用户已有的 UI/下载等修改。
未执行 adb install，未重启或改变手机播放；最终设备仍为旧 PID 19770，手机尚未运行修复版。代码回归和发布构建已完成；修复版实机尾切复测与 10 小时长期运行验证尚未完成，不宣称实机耗时已降至某个值，也不把本次身份竞争证据解释成长时间运行导致。

本次针对已通过失败测试证实的索引/序列竞争完成修复；未盲目加入原生 timeout/重启/轮询补偿。原生在途调用截止协议等独立防御性扩展未纳入此次补丁。
