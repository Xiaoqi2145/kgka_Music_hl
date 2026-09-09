# 控制器层 · ThemeController

> 文档编号：KA-03-12
> 级别：L2 📖
> 状态：现行
> 关联代码：lib/controllers/theme_controller.dart（179 行，主） + lib/main.dart + lib/ui/app_theme.dart + lib/ui/adaptive_layout.dart + lib/ui/pages/personalization_settings_page.dart + lib/ui/pages/settings_page.dart + lib/ui/pages/player_page.dart
> 最近更新：2026-09-09
> 变更触发条件：新增/删除预设色、改动 theme.* 设置键、改动背景图存储位置或透明度范围、改动屏幕方向策略、改动 AppTheme 与 ThemeController 的入参契约时

---

## 1. 一句话结论（TL;DR）

`ThemeController` 是**全局个性化设置的唯一持有者**，管三件事：种子色（8 个预设 + 默认经典蓝）、自定义全局背景图（开关 / 路径 / 透明度）、横屏开关；深色模式**完全跟随系统**（`main.dart` 中 `themeMode: ThemeMode.system`，无手动切换项）。它是**单例**（`ThemeController.instance`），由 `main()` 在 `runApp` 之前构造并 `load()`。

---

## 2. 现状

### 2.1 基本信息

| 项 | 值 | 锚点 |
|---|---|---|
| 文件 | `lib/controllers/theme_controller.dart` | — |
| 行数 | 179 行（口径：PowerShell `Measure-Object -Line`，约等于非空行；文件总行数含空行为 203） | — |
| 基类 | `ChangeNotifier` | `theme_controller.dart:16` |
| 构造 | `ThemeController()`，构造体内 `_instance = this` | `theme_controller.dart:17-19` |
| 单例访问 | `static ThemeController? _instance` + `static ThemeController get instance => _instance!` | `theme_controller.dart:21-22` |
| 构造点 | `main()` 中 `final themeController = ThemeController(); await themeController.load();` | `main.dart:41-42` |
| 订阅点 | `main.dart` 用 `AnimatedBuilder(animation: _theme)` 包裹整个 `MaterialApp` | `main.dart:136-178` |
| 私有预设类型 | `class _PresetColor { const _PresetColor({required name, required color}); }` | `theme_controller.dart:198-203` |

### 2.2 状态字段与 Getter

| 私有字段 | 类型 | 初值 | Getter | 语义 | 锚点 |
|---|---|---|---|---|---|
| `_seedColor` | `Color` | `Color(0xFF1478FF)` | `seedColor` | 全局种子色 | :43、:52 |
| `_backgroundEnabled` | `bool` | `false` | `backgroundEnabled` | 是否启用自定义背景图 | :44、:53 |
| `_backgroundImagePath` | `String?` | `null` | `backgroundImagePath` | 背景图绝对路径 | :45、:54 |
| `_backgroundOpacity` | `double` | `0.15` | `backgroundOpacity` | 背景透明度（0.0 ~ 0.8） | :46、:55 |
| `_landscapeEnabled` | `bool` | `false` | `landscapeEnabled` | 手机是否允许横屏 | :47、:56 |
| `_lastAppliedIsTablet` | `bool?` | `null` | — | `applyOrientations` 去重缓存 | :49 |
| `_lastAppliedLandscapeEnabled` | `bool?` | `null` | — | `applyOrientations` 去重缓存 | :50 |

派生 Getter：`hasCustomSeedColor => _seedColor != const Color(0xFF1478FF)`（`theme_controller.dart:59`），用于个性化页是否显示「恢复默认配色」。

### 2.3 8 种预设色

`static const presetColors = <_PresetColor>[...]`（`theme_controller.dart:32-41`）：

| # | 名称 | ARGB 常量 | 十六进制 | 备注 |
|---|---|---|---|---|
| 1 | 经典蓝 | `Color(0xFF1478FF)` | #1478FF | 默认色，与 `AppTheme.blue` 相同（`app_theme.dart:5`） |
| 2 | 酷狗红 | `Color(0xFFFF2D55)` | #FF2D55 | 与 `AppTheme.musicRed` 相同（`app_theme.dart:6`），始终作为 `secondary` |
| 3 | 清新绿 | `Color(0xFF24C768)` | #24C768 | 与 `AppTheme` 的 `tertiary` 相同（`app_theme.dart:54`） |
| 4 | 优雅紫 | `Color(0xFF8B5CF6)` | #8B5CF6 | — |
| 5 | 暖阳橙 | `Color(0xFFF59E0B)` | #F59E0B | — |
| 6 | 樱花粉 | `Color(0xFFEC4899)` | #EC4899 | — |
| 7 | 天际青 | `Color(0xFF06B6D4)` | #06B6D4 | — |
| 8 | 石墨灰 | `Color(0xFF64748B)` | #64748B | — |

注意 `presetColors` 的静态类型是 `List<_PresetColor>`，`_PresetColor` 是库私有类型，**外部文件只能通过类型推断遍历**，不能显式标注该类型（现有用法见 `personalization_settings_page.dart:44-52`）。

### 2.4 持久化键

| 键 | 常量 | 类型 | 默认 | 取值范围 | 锚点 |
|---|---|---|---|---|---|
| `theme.seed_color` | `_seedColorKey` | `int`（`Color.toARGB32()`） | `0xFF1478FF` | 任意 ARGB | :25、:83 |
| `theme.bg_enabled` | `_bgEnabledKey` | `bool` | `false` | true / false | :26、:92 |
| `theme.bg_image_path` | `_bgImagePathKey` | `String` | 键不存在 | 绝对路径 | :27、:134 |
| `theme.bg_opacity` | `_bgOpacityKey` | `double` | `0.15` | 读取时 `clamp(0.0, 0.8)` | :28、:71-74 |
| `theme.landscape_enabled` | `_landscapeEnabledKey` | `bool` | `false` | true / false | :29、:101 |

---

## 3. 设计说明

### 3.1 `load()` 的读取顺序

`ThemeController.load()`（`theme_controller.dart:62-76`）严格按以下顺序读，最后一次 `notifyListeners()`：

| 步 | 读取 | 缺省处理 | 锚点 |
|---|---|---|---|
| 1 | `prefs.getInt('theme.seed_color')` | null 时保留 `0xFF1478FF` | :64-67 |
| 2 | `prefs.getBool('theme.bg_enabled') ?? false` | 无条件覆盖 | :68 |
| 3 | `prefs.getString('theme.bg_image_path')` | null 时保留 null | :69 |
| 4 | `prefs.getBool('theme.landscape_enabled') ?? false` | 无条件覆盖 | :70 |
| 5 | `prefs.getDouble('theme.bg_opacity')` | null 时保留 0.15；非 null 时 `clamp(0.0, 0.8)` | :71-74 |

`load()` **不做**三件事：不校验背景图文件是否仍存在；不调用 `applyOrientations`；不写回任何键。

### 3.2 写方法与副作用

| 方法 | 入参 | 提前返回条件 | 持久化 | 副作用 | 锚点 |
|---|---|---|---|---|---|
| `setSeedColor(Color)` | 目标色 | 与当前相同 | `setInt(theme.seed_color, toARGB32())` | `notifyListeners()` → `main.dart` 重建 `MaterialApp` 主题 | :79-85 |
| `setBackgroundEnabled(bool)` | 开关 | 与当前相同 | `setBool(theme.bg_enabled)` | `notifyListeners()` | :88-94 |
| `setLandscapeEnabled(bool, bool isTablet)` | 开关 + 是否平板 | 与当前相同 | `setBool(theme.landscape_enabled)` | 调 `applyOrientations(isTablet)`，再 `notifyListeners()` | :97-104 |
| `setBackgroundImagePath(String?)` | 路径或 null | 无 | 非 null 写 `setString`，null 走 `remove` | `notifyListeners()` | :130-139 |
| `setBackgroundOpacity(double)` | 0.0~0.8 | 无 | `setDouble`（写入的是 clamp 后的值） | `notifyListeners()` | :142-147 |
| `pickAndSetBackgroundImage()` | 无 | 用户取消 / 源文件不存在 | 经 `setBackgroundImagePath` | 见 §3.3 | :152-179 |
| `clearBackgroundImage()` | 无 | 无 | 经 `setBackgroundImagePath(null)` + `setBackgroundEnabled(false)` | 删除磁盘文件 | :182-194 |

### 3.3 自定义背景图的选取与落盘

`pickAndSetBackgroundImage()`（`theme_controller.dart:152-179`）：

| 步 | 动作 | 参数/结果 | 锚点 |
|---|---|---|---|
| 1 | `ImagePicker().pickImage` | `source: gallery`、`imageQuality: 88`、`maxWidth: 2560`、`maxHeight: 2560` | :155-160 |
| 2 | 用户取消 | 返回 `false` | :161 |
| 3 | 校验源文件存在 | 不存在返回 `false` | :163-164 |
| 4 | 取扩展名 | 有 `.` 取最后一段，否则 `.jpg` | :168-170 |
| 5 | 复制到永久目录 | `getApplicationDocumentsDirectory()/bg_custom{ext}` | :167-172 |
| 6 | 写路径 | `setBackgroundImagePath(permanentPath)` | :174 |
| 7 | 自动开启 | 若 `!_backgroundEnabled` 则 `setBackgroundEnabled(true)` | :175-177 |
| 8 | 返回 | `true` | :178 |

`clearBackgroundImage()`（:182-194）先尝试删除当前路径文件（异常吞掉），再清路径、关开关。

### 3.4 `applyOrientations` 与平板判断

`applyOrientations(bool isTablet)`（`theme_controller.dart:107-127`）：

| 条件 | 允许方向 | 锚点 |
|---|---|---|
| `isTablet` 或 `_landscapeEnabled` | `portraitUp` / `portraitDown` / `landscapeLeft` / `landscapeRight` | :115-121 |
| 其余（手机且未开横屏） | 仅 `portraitUp` | :122-126 |

去重保护：若 `_lastAppliedIsTablet == isTablet` 且 `_lastAppliedLandscapeEnabled == _landscapeEnabled`，直接返回，不重复调用 `SystemChrome.setPreferredOrientations`（:108-113）。

平板判断有两个入口（`lib/ui/adaptive_layout.dart`）：

| 方法 | 依据 | 适用场景 | 锚点 |
|---|---|---|---|
| `AdaptiveLayout.isTablet(context)` | `MediaQuery.sizeOf(context).shortestSide >= 600` | 有 `BuildContext` 的构建期 | `adaptive_layout.dart:20-23` |
| `AdaptiveLayout.isTabletByPlatform()` | `platformDispatcher.views.first` 的 `physicalSize / devicePixelRatio` 的 `shortestSide >= 600` | `dispose` 等 context 已失效处 | `adaptive_layout.dart:31-39` |

调用点：

| 调用点 | 传参 | 锚点 |
|---|---|---|
| `main.dart` 每次 build | `_theme.applyOrientations(AdaptiveLayout.isTablet(context))` | `main.dart:135` |
| 设置页横屏开关 | `theme.setLandscapeEnabled(value, AdaptiveLayout.isTablet(context))` | `settings_page.dart:324-329` |
| 播放页 `dispose` | 直接读 `ThemeController.instance.landscapeEnabled` + `AdaptiveLayout.isTabletByPlatform()`，自行调用 `SystemChrome` | `player_page.dart:66-78` |

`AdaptiveContentPadding` 复用同一阈值：宽度 `< 600` 直接返回子组件，否则居中并限制最大宽度（默认 `AdaptiveLayout.contentMaxWidth = 680`）（`adaptive_layout.dart:47-72`）。

### 3.5 与 `main.dart` 的 `_AppBackground` 配合

主题色注入（`main.dart:139-157`）：

| 参数 | 取值 | 说明 |
|---|---|---|
| `themeMode` | `ThemeMode.system` | 深色/浅色跟随系统，**无手动开关** |
| `theme` / `darkTheme` | `AppTheme.light/dark(seedColor: _theme.seedColor, transparentBackground: _theme.backgroundEnabled)` | 背景图开启时启用透明页面转场 |
| `builder` | `_AppBackground(themeController: _theme, child: _SystemUiOverlay(child))` | 背景层包住全部页面 |

`AppTheme._theme` 的种子色用法：`ColorScheme.fromSeed(seedColor)`，深色下 `primary = _lighten(seedColor, 0.18)`，`secondary` 固定 `musicRed`，`tertiary` 固定 `0xFF24C768`（`app_theme.dart:50-73`）。`transparentBackground = true` 时替换 `pageTransitionsTheme` 为透明快照的转场集合（`app_theme.dart:7-30`、:78-80`）。

`_AppBackground`（`main.dart:186-315`）的渲染契约：

| 项 | 实现 | 锚点 |
|---|---|---|
| 未启用或无路径 | 直接返回 `child`，并 `_releaseLiveImage()` | `main.dart:272-275` |
| 图片 Provider | `ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, FileImage(File(path)))`，按 `'$path@$cacheWidth*$cacheHeight'` 缓存 | `main.dart:203-222` |
| 目标分辨率 | `MediaQuery.size * devicePixelRatio` 向上取整 | `main.dart:280-286` |
| 常驻解码 | `_keepImageAlive` 用 `ImageStreamListener` 持有解码结果，`dispose` 时释放 | `main.dart:224-261` |
| 图层顺序 | 背景图 → 遮罩 → `child` | `main.dart:288-311` |
| 遮罩色 | 深色 `Color(0xFF06070A)`，浅色 `Colors.white` | `main.dart:277-278` |
| 遮罩透明度 | `alpha = 1.0 - backgroundOpacity`（opacity 越大背景越明显） | `main.dart:303-307` |
| 图片参数 | `fit: BoxFit.cover`、`gaplessPlayback: true`、`filterQuality: FilterQuality.low`、`errorBuilder` 返回空 | `main.dart:293-299` |

### 3.6 个性化设置页入口

`PersonalizationSettingsPage`（`personalization_settings_page.dart`，587 行）是唯一的功能入口，导航来自「设置 → 个性化 → 皮肤与背景」（`settings_page.dart:304-316`）：

| UI 元素 | 行为 | 显示条件 | 锚点 |
|---|---|---|---|
| 8 个 `_ColorDot` | `tc.setSeedColor(preset.color)`，选中态比对 `tc.seedColor == preset.color` | 始终 | `personalization_settings_page.dart:41-54` |
| 「恢复默认配色」 | `setSeedColor(const Color(0xFF1478FF))` | 仅 `tc.hasCustomSeedColor` | :55-63 |
| 「启用自定义背景」开关 | `setBackgroundEnabled(value)` | `backgroundImagePath == null` 时 `onChanged: null`（禁用） | :72-81 |
| 「选择背景图」 | `pickAndSetBackgroundImage()`，成功 `Toast.success('背景图已设置')` | 始终 | :83-91、:131-142 |
| 「背景预览」 | 跳 `_FullBackgroundPreview`（`fullscreenDialog: true`） | 路径非 null | :94-100、:144-154 |
| 透明度滑块 | `min: 0.0`、`max: 0.8`、`divisions: 80`，`onChangeEnd` 才落盘 | 路径非 null | :102-105、:304-312 |
| 「移除背景图」 | 二次确认后 `clearBackgroundImage()` | 路径非 null | :107-113、:156-178 |
| 「横屏模式」开关 | 见 §3.4 | 位于设置页而非个性化页 | `settings_page.dart:318-330` |

### 3.7 已知问题：背景图渲染延迟

用户反馈自定义背景图在页面切换时延迟约 0.7 秒（`KA-Music-项目状态.md` §4.2，第 166-171 行）。已尝试并**全部回退**的方案：预加载字节、预解码 `ui.Image`、架构分离。当前代码即原版实现——`_AppBackground` 已用 `ResizeImage` + `gaplessPlayback` + 常驻 `ImageStreamListener` 优化（`main.dart:203-261`、:296），但延迟仍存在。待核实方向：`Image.file()` 的缓存键问题或 Navigator 过渡动画的同步问题。

---

## 4. 约束与坑

1. **`instance` 是 `_instance!` 空断言**（:22）。若在 `main()` 构造 `ThemeController` 之前访问 `ThemeController.instance`（例如某个测试直接构造 Widget），会抛 `Null check operator used on a null value`。当前唯一消费点 `player_page.dart:67` 位于页面 `dispose`，运行时必然已构造。
2. **再次构造 `ThemeController` 会顶掉单例。** 构造函数无条件 `_instance = this`（:18），多实例场景下 `instance` 指向最后构造的那个。
3. **透明度上限硬编码 0.8**，`setBackgroundOpacity` 与 `load` 各 clamp 一次（:73、:143），UI 滑块同样封顶 0.8；没有常量抽取，改范围需同步改三处。
4. **背景图文件名固定为 `bg_custom{ext}`**（:171）。换图时同名覆盖；若新旧扩展名不同（如 `.png` → `.jpg`），旧文件不会被删除，`clearBackgroundImage` 也只删当前路径（:182-191）。
5. **`setBackgroundImagePath` 不清理旧文件**（:130-139），直接调用会造成孤儿文件。
6. **`load()` 不校验文件存在性**。背景图被外部删除后，`backgroundEnabled` 仍为 true，`_AppBackground` 走 `errorBuilder` 返回空白（`main.dart:298`），界面表现为「没有任何背景」而非回退到纯色。
7. **深色模式不可手动切换。** `themeMode` 固定 `ThemeMode.system`（`main.dart:143`），全仓库没有任何 `ThemeMode` 写入点或「深色模式」设置项。
8. **平板恒可横屏**：`applyOrientations` 中 `isTablet || _landscapeEnabled`（:115）使平板上「横屏模式」开关**无实际效果**，开关值仅被持久化；设置页文案已注明「平板默认开启」（`settings_page.dart:322`）。
9. **`setLandscapeEnabled` 的提前返回会跳过方向应用**（:98-99）。若开关值未变（例如启动后首次交互传了相同值），不会重新调用 `applyOrientations`；实际上 `main.dart:135` 每次 build 都会补一次，因此不构成可见缺陷。
10. **方向恢复依赖 `ThemeController.instance`**：播放页 `dispose` 不走 `applyOrientations`，而是自己复制了一份判断逻辑（`player_page.dart:66-78`）。若将来改方向策略，需要同时改两处。
11. **背景图与缩略图缓存无关**：背景图是本地文件，不进 `ArtworkCacheService`（缩略图缓存），也不参与其 LRU 淘汰。

---

## 5. 待办与关联

### 5.1 待办

| 项 | 说明 | 优先级 |
|---|---|---|
| 修复背景图切换延迟 | 见 §3.7；需先定位是缓存键问题还是转场同步问题 | 中 |
| 背景图孤儿文件清理 | `setBackgroundImagePath` / `pickAndSetBackgroundImage` 在切换时删除旧文件 | 中 |
| 文件缺失自愈 | `load()` 后校验 `theme.bg_image_path` 是否存在，缺失则自动关闭开关 | 中 |
| 常量抽取 | 透明度上下限（0.0 / 0.8）抽为 `ThemeController` 常量并让 UI 复用 | 低 |
| 单例健壮性 | `instance` 改为懒构造或抛出具名异常；或去掉单例改由构造参数传递 | 低 |
| 手动深色模式 | 当前不支持；若要加需新增 `theme.mode` 键并改 `main.dart:143` | 低（需求待定） |

### 5.2 关联文档

- `main.dart` 的装配与 `_AppBackground` 生命周期：`../02-架构设计/启动流程与依赖装配.md`
- `theme.*` 键的完整清单与默认值：`../04-数据与接口/本地存储与配置项清单.md`
- 个性化页在 UI 清单中的位置：`UI层-页面与组件清单.md`
- 背景图渲染延迟的台账条目：`../06-质量保障/已知问题与技术债台账.md`
- 术语（缩略图缓存 ≠ 背景图）：`../00-元数据/术语表.md`
