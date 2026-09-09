> 文档编号：KA-03-11
> 级别：L2 📖
> 状态：现行
> 关联代码：lib/controllers/download_controller.dart（500 行）、lib/services/download_service.dart（356 行）
> 最近更新：2026-09-08
> 变更触发条件：下载状态模型、索引持久化格式、并发编排、播放缓存策略变化时

# 控制器层 · DownloadController

## TL;DR

`DownloadController` 是**下载与播放缓存的编排层**：它持有两个内存索引（`_downloads` / `_playCache`），负责任务去重、进度回调、索引持久化（防抖）、LRU 清理与响度元数据回写。真正的 IO 与并发调度在 `DownloadService`（见 `03-模块详解/服务层-下载服务.md`）。**关键设计**：用户下载与播放缓存共享并发上限 3，但用户下载优先。

---

## 1. 状态模型

### 1.1 `DownloadEntry`（用户下载）

| 字段 | 类型 | 说明 |
|---|---|---|
| `song` | `Song` | 曲目 |
| `quality` | `AudioQuality` | 下载音质 |
| `status` | `DownloadStatus` | `downloading` / `downloaded` / `failed` |
| `progress` | `double` | 0.0 ~ 1.0 |
| `filePath` | `String?` | 完成后路径 |
| `downloadedAt` | `DateTime?` | 完成时间 |
| `error` | `String?` | 失败原因 |
| `loudness` | `LoudnessData?` | 响度元数据（音量均衡用） |

### 1.2 `PlayCacheEntry`（播放缓存）

| 字段 | 类型 | 说明 |
|---|---|---|
| `cacheKey` | `String` | `{hash}_{quality.apiValue}` |
| `song` | `Song` | 曲目 |
| `quality` | `AudioQuality` | 音质 |
| `filePath` | `String` | 文件路径 |
| `size` | `int` | 字节数 |
| `cachedAt` | `DateTime` | 写入时间（**LRU 依据**） |
| `loudness` | `LoudnessData?` | 响度元数据 |

### 1.3 索引持久化

| 索引 | 键 | 序列化 |
|---|---|---|
| 下载 | `ka_music_downloads_index` | JSON 数组，含 `downloadedAt` ISO 字符串 |
| 播放缓存 | `ka_music_play_cache_index` | JSON 数组 |

- 写入采用**防抖调度**（`_schedulePlayCachePersist`），`flush()` 立即落盘。
- `dispose()` 中 `unawaited(flush())`，确保退出前写入。

---

## 2. 公开接口

| 方法 | 作用 |
|---|---|
| `initialize()` | 加载上限、下载索引、播放缓存索引 |
| `download(song, quality)` | 发起用户下载（去重：下载中/已下载直接返回） |
| `cancelDownload(song)` | 取消下载（调 `DownloadService.cancel`） |
| `deleteDownload(song)` | 删除单个下载文件 + 索引 |
| `clearAllDownloads()` | 清空全部下载 |
| `cacheForPlayback(song, quality, url, {loudness})` | 播放缓存（静默、无进度） |
| `cancelPlaybackCache(song, quality)` | 取消在途播放缓存 |
| `deletePlayCache(song, quality)` | 删除单条播放缓存 |
| `clearPlayCache()` | 清空播放缓存目录与索引 |
| `updateLocalLoudness(song, quality, loudness)` | 为旧索引补写响度元数据 |
| `localPathFor(song, quality)` / `localSourceFor(...)` | 查询本地可播放源（下载 > 播放缓存） |
| `isDownloaded(song)` / `entryFor(song)` | 查询下载状态 |
| `getDownloadDirSize()` / `getPlayCacheDirSize()` | 目录大小 |
| `setPlayCacheMaxBytes(bytes)` | 调整上限并立即清理 |
| `downloadedSongs` / `downloadEntries` / `playCacheEntries` | 只读视图 |
| `flush()` / `dispose()` | 落盘与释放 |

---

## 3. 下载状态机

```
        download()
            │
            ▼
     ┌─────────────┐  成功   ┌────────────┐
     │ downloading │────────▶│ downloaded │
     └──────┬──────┘         └─────┬──────┘
            │ 失败                  │ deleteDownload()
            ▼                       ▼
     ┌─────────────┐          （移除索引与文件）
     │   failed    │
     └─────────────┘
            │ cancelDownload() / 重新 download()
            ▼
        （移除 / 回到 downloading）
```

| 转换 | 触发 | 副作用 |
|---|---|---|
| → `downloading` | `download()` | `notifyListeners()` |
| `downloading` → `downloaded` | IO 成功 | 写入 `filePath`/`downloadedAt`/`loudness`，`_persistDownloads()` |
| `downloading` → `failed` | 抛异常（含空 URL） | 写入 `error` |
| `downloading` → 移除 | `cancelDownload()` | 调 `DownloadService.cancel` |
| `downloaded` → 移除 | `deleteDownload()` / `clearAllDownloads()` | 删文件 + 持久化 |

---

## 4. 播放缓存策略

| 环节 | 行为 | 位置 |
|---|---|---|
| 触发 | `PlayerController` 在稳定播放 30 秒后调用 | `player_controller.dart:1010+` |
| 已存在同 key | 若旧条目缺 `loudness` 且新数据可用 → 仅补写响度，不重复下载 | `download_controller.dart:419-434` |
| 正在下载该曲 | 跳过（避免与用户下载争抢） | `download_controller.dart:435` |
| 成功 | 记录条目 + 防抖持久化 + 触发 LRU 清理（排除刚写入的路径） | `download_controller.dart:443-456` |
| 失败 | **静默忽略**（播放不受影响） | `download_controller.dart:457-459` |

### 4.1 LRU 清理（`_prunePlayCache`）

1. 取 `_playCache` 全部条目，按 `cachedAt` **升序**排序；
2. 调 `DownloadService.prunePlayCache(entries, excludePaths, maxBytes)`；
3. 返回被删除的 key 集合 → 从内存索引移除 → `notifyListeners()` + 防抖持久化。

> ⚠️ `excludePaths` 用于保护「刚写入的条目」，避免刚缓存完就被自己淘汰（当单条大于上限时会失效）。

---

## 5. 与播放器的交互

| 场景 | 调用链 |
|---|---|
| 播放前查本地源 | `PlayerController.playSong` → `downloadController.localSourceFor(song, quality)` |
| 本地文件加载失败 | `PlayerController` → `downloadController.deletePlayCache(song, quality)` → 回退网络 |
| 无缝预载 | `_prepareNextSourceIfNeeded` → `localSourceFor` 命中则跳过网络解析 |
| 响度元数据回写 | `_hydrateLocalLoudness` → `downloadController.updateLocalLoudness` |
| 播放缓存调度 | `PlayerController._schedulePlaybackCache` → `cacheForPlayback` |

> **循环依赖解法**：`PlayerController.downloadController` 是**可变字段**，由 `main.dart` 在构造后注入（`player_controller.dart:107`）。

---

## 6. 约束与坑

| 编号 | 问题 | 影响 |
|---|---|---|
| DC-01 | LRU 依据是 `cachedAt`（写入时间），热门老歌可能被冷门新歌挤掉 | 命中率下降（TD-08） |
| DC-02 | 播放缓存目录在 `getTemporaryDirectory()` | 系统可清理（TD-02） |
| DC-03 | 单条大于上限时 `excludePaths` 保护失效，刚缓存即被删 | 无效 IO |
| DC-04 | 下载失败只记录 `error` 字符串，无重试与分类 | 用户需手动重试 |
| DC-05 | 索引持久化是**全量 JSON 重写**，条目多时耗时 | 大量下载后卡顿 |
| DC-06 | `updateLocalLoudness` 只更新索引，不更新音频文件元数据 | 换设备后失效 |
| DC-07 | 无下载队列可见性与优先级调整 | 用户无法干预 |
| DC-08 | `dispose()` 的 `flush()` 是 `unawaited`，进程被杀时可能丢失最后一次索引 | 索引与磁盘不一致 |

---

## 7. 待办与关联

| 事项 | 编号 | 文档 |
|---|---|---|
| 播放缓存淘汰改为访问时间 | T-M3-08 | `07-推进计划/任务分解-WBS.md` |
| 缓存目录迁出临时目录 | T-M3-05 | 同上 |
| 统一 `DiskCache` 接口 | T-M3-01 | 同上 |
| IO 层与并发细节 | — | `03-模块详解/服务层-下载服务.md` |
| 下载相关设置项 | — | `04-数据与接口/本地存储与配置项清单.md` |
| 下载页 UI | — | `03-模块详解/UI层-页面与组件清单.md` |
