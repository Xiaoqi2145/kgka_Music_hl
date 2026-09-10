# 尾段连续切换封面、歌词与音源：修复方案

## 基线与范围
当前版本已提交为 b93dae4（chore: checkpoint current player and UI changes），包含当前源代码、测试和既有诊断说明，提交信息明确仍有预载问题。未 push。原始日志和 APK 不进入该提交。本文是提交后新制定的方案，尚未实施；本轮不改业务代码、不安装应用、不调用子代理。

## 新证据
用户描述：当前歌未结束时封面和歌词连续切换三次，最后播放第三个候选。ADB 重读 PID 23971 的 20:18 时段，确认：
- 20:18:27.231 AudioTrack start(320)，gain=0.691831。它可能是 seek 后续播，不单独当作新歌起点。
- 20:18:34.236 响度接口返回，34.239 generation=6，reason=transition，key=7A859F6C8C3BEAC3083F81315B95B7D1；34.269 setVolume=0.767361，34.270 ack，总计 30ms。
- 20:18:49.384 响度接口返回，49.386 generation=7，reason=transition，key=FCE8B2E13DFC2221133F0944CFBAFB84；49.414 setVolume=0.749894，ack 总计 27ms。
日志明确两次切源身份变化，不足以仅凭节选确定三次实际声学换歌的精确时间。两次增益执行都很快，优先调查 transition 为何在接口返回后触发，而非继续给 LUFS 队列加超时。原始片段保存为 preload-multiple-transition-2018.log。

## 已审查的代码风险
1. player_controller.dart:1133-1198 将 sequenceState.currentSource 变化直接升级为实际换歌：修改 currentSong、清歌词、通知封面、应用 LUFS、写历史、更新媒体通知并 trim 前置音源。没有区分结构变更与播放过渡。
2. 锁定依赖 just_audio 0.10.5 的 add/remove 先修改 Dart children 并 _broadcastSequence，之后才执行原生 concatenatingInsertAll/removeRange。_broadcastSequence 保留索引；播放事件订阅又会把平台 index 写回 sequenceState。SequenceState 的 currentIndex 对超界值还会夹到当前序列长度。故“最新快照”仍可能是结构变化与旧播放索引形成的临时状态，不是原生已切歌证明。
3. 一旦误选到预载 B，立即 trim A，可能进一步推动实际音源删除/过渡；_preparedNext 清空和未绑定条目的 position/duration 又可能预选 C，形成连续推进。该因果链需新失败测试/原生来源日志确认，不能宣称完整链路已经实机定案。
4. positionStream 与 durationStream 分开写全局状态；预载和完成兜底没有 entryId 绑定。旧尾部 position 搭配新曲 duration 可能触发新曲的预载/完成。
5. _handleCompleted 和位置兜底、原生自动过渡、手动 next 多入口；_completedSongHash 只按 hash 去重，定时器没有捕获播放条目，异步 next 查找主要检查 playRequestGeneration，而自然 transition 不一定使它失效。

## 必须成立的规则
- prefetch 完成不能修改当前曲、封面、歌词、LUFS generation、历史或实际音源。
- 每个播放实例有独立 entryId；同曲重复和 A->B->A 也不能混同。候选 next 固定绑定 ownerEntryId + queueRevision + quality + requestRevision。
- 一次自然结束只消费一次前进资格；同一 A 的迟到事件绝不能让 B 前进到 C。
- UI、歌词、归一化与播放历史必须来自同一次确认的媒体过渡，不能分别提交。
- 音源结构变化只更新结构，不等于已出声或已换歌；不能用固定延时/防抖猜测这一点。

## 推荐实施路线

### 第一阶段：正确性优先的稳定修复（默认启用）
保留下一首 URL、响度、歌词、封面等后台预解析，但暂不把预载候选动态 append 到当前音源队列；一次只让主播放器持有已提交播放条目。只有当前条目真实结束或用户显式 next 才消费候选并 load/play 一次。
这会暂时放弃样本级无缝音源接续，但不是关闭所有预载；大部分网络解析开销仍可提前完成。对已有多子源队列，在安全停止/下一次显式加载边界重建，不能为切换策略在当前播放中再次冒险 trim。
- PreparedCandidate 是纯缓存结果，不写 currentSong/lyrics 等展示字段。
- 一个 TransitionCoordinator 持有 committedEntry、固定候选、播放代次、seekRevision、一次性 completion token。预载完成仅执行 prepared，结束事件仅提交一次 transition。
- native completed 是正常前进依据。位置兜底绑定 ownerEntryId、seekRevision、精确媒体时间；在真实结束/停滞证据不足时不能因为 <=750ms 提前跳曲。兜底触发必须重新确认当前条目、未 seek、非 buffering、位置与时长同源且达到末尾；与 completed 共用一次性消费令牌。
- 手动 next/previous/换队列/换音质立即使旧候选、定时器和异步 next 解析失效；暂停不清除仍有效的候选，但旧 completion 不得恢复播放。
- _nextSong 的随机选择对同一 owner 固定一次，不能候选 A 完成就重新抽 B。

### 第二阶段：若要恢复动态无缝音源预载
不能仅改回 currentIndexStream、再加一个 isMutating 布尔量或 debounce。必须先建立可验证的事件来源：
- 明确区分 playlist_structure_changed、prefetch_ready、native_media_transition、seek_completed。
- 原生过渡事件包含稳定媒体条目 ID、播放器实例/加载版本、事件序号、原因及原生单调时间。只有确认到不同的实际当前条目才提交业务 transition；结构通知/同条目的索引重排不提交。
- 核对平台接口是否已能提供这些字段；仅使用 Dart positionDiscontinuityStream 前必须审查其是否也由混合序列推导，不能当作天然独立证据。若能力不足，采用仓库内受控插件补丁或明确的平台桥接，不能修改全局 Pub Cache。
- 列表增删通过单一执行器串行化，并按具体 sourceId 返回操作结果；预载过期只删属于该请求的确切非当前条目，不能用差集或可变索引猜测。
- trim 不与切歌业务提交互相递归；保留有界历史音源窗口，选择经过确认的维护边界，失败时协调真实序列。
- 第一阶段可独立交付，第二阶段通过同一验收后再启用；不在无证据时把复杂协议一次性堆入主链路。

## UI / LUFS 联动
- 真实 transition 的单一提交方法一次确定歌曲、条目 ID、音质、归一化代次和起点；封面、歌词与通知栏只订阅 committedEntry。
- 请求歌词/封面必须携带 entryId 或展示请求版本，返回时核对，旧请求只写缓存。
- 增益计算可以预先完成，但真正提交绑定 committedEntry；预载数据不能重开当前歌的 3 秒窗口。保留现有增益公式，先解决错误切曲，而不是延长 LUFS 窗口。

## 先写失败测试
现有测试 fake.emitSequence 同时提供已协调的序列与索引，虽然覆盖了旧列表映射回退，但没有模拟依赖的两阶段结构广播，这就是本次测试缺口。新增：
1. add 候选后先广播结构，原生尚未插入：封面/歌词/currentSong/generation/音量均不变。
2. remove 先改 Dart 序列，平台旧索引稍后到达，再追加新候选：不得连锁 B->C->D，不得删除正在播放的条目。
3. 原样注入 20:18:27 播放、34.236 和49.384 两次响应：在未确认结束时零次业务切歌；一次真实结束后恰好切一次。
4. 旧 position、旧 duration、completed、fallback timer 以不同顺序到达；当前 B 不能被 A 的尾部事件跳过。
5. 预载中 seek 到尾部又拉回、连续拖动、手动 next/previous、暂停、换队列、换音质；候选过期不影响新播放。
6. 同曲重复条目与随机模式；一首的候选只能消费一次。
7. 接口 7秒/15秒返回、追加失败/删除失败/部分成功；无 UI 提前切换，失败路径可继续播放。
8. 歌词/封面异步返回乱序；展示始终与 committedEntry 一致。

## 实机记录与验收
- 日志记录 currentEntry、candidateEntry、owner、queue/load/seek/request revision、事件来源、transitionReason、媒体 position/duration 的 owner、单调时间、序列 IDs 和操作 start/ack/reject。不得输出 URL/令牌。
- 同曲对、相同尾部拖动步骤，冷/热缓存与慢网络都验证；记录屏幕与日志关联，而不是只看 generation。
- 至少 30 次自然尾切 + 30 次尾部往返拖动：预载阶段展示变化为 0，每次实际结束业务 transition 恰好 1，最终播放预定下一首，不跳过候选。重复状态通知测试不能冒充实机重复切歌。
- 音量在真实已提交条目范围内验证 3 秒规则；仅有 generation 变化或 AudioTrack start 不能推断声学切歌起点。
- 全量 flutter test/analyze/build，再做至少 10 小时运行验证；明确短期通过与长期未测的边界。

## 文件范围
lib/controllers/player_controller.dart、lib/services/music_audio_handler.dart、新的播放过渡协调器及对应测试。必要时调整歌词/UI只读订阅边界。动态无缝阶段才扩展受控插件/平台协议。第一阶段不改响度算法、不顺带改无关 UI。

## 明确不采用
封面歌词延迟显示、忽略前 N 秒事件、固定 debounce、延长 3 秒窗口、定时重启、把 sequenceState 最新快照直接当成原生播放提交。它们不能消除误删当前音源和重复前进。
