# Meloha（SubtitlePlayer）交接文档

> 给新会话的上手文档。**先读这份，再读 `~/.tclaude/.../memory/MEMORY.md`（会自动加载）。**
> 用户全程用中文交流，回复请用中文。

## 一、项目概况

- **App 名**：Meloha（Xcode 工程/bundle 名 `SubtitlePlayer`，bundle id `com.hansen.SubtitlePlayer`）
- **平台**：iOS 26 / Xcode 26，纯 SwiftUI
- **定位**：本地音频播放器 + 字幕/歌词同步 + 画中画字幕 + 本地设备端 MLX Swift 聊天机器人
- **源码目录**：`/Users/hansen/Desktop/Projects/SubtitlePlayer/SubtitlePlayer/SubtitlePlayer/*.swift`
- **工程文件**：`/Users/hansen/Desktop/Projects/SubtitlePlayer/SubtitlePlayer/SubtitlePlayer.xcodeproj`
- **工作目录**：`/Users/hansen/Desktop/Projects/SubtitlePlayer/SubtitlePlayer`

### 主要源文件
- `ContentView.swift`（很大）：播放器主界面 + `AudioFilesView`（音乐库：专辑 / 小工具两个标签）+ 播放/字幕逻辑。
- `Library.swift`：`AlbumStore`、`Album`、`AlbumDetailView`、`AddSongsView`、`UncategorizedView`、`SettingsView`、`AudioDocumentPicker`、全局函数 `documentsAudioURLs()` / `importAudioToDocuments()`、`toast` 扩展、`FileSort`（现已不用但保留）。
- `Metronome.swift`：节拍器引擎 `Metronome` + 界面 `MetronomeView`。
- `MiniTools.swift`：小工具子页面 —— `DiceRollerView`（掷骰子）/ `CardDrawView`+`PlayingCard`（抽纸牌）/ `LotteryView`（抽签）。
- `AudioTrimmer.swift`：音频裁剪 —— `trimAudio()` 引擎 + `parseTimeInput()`/`formatTrimTime()` + `AudioTrimPickerView`（选文件）→ `AudioTrimView`（裁剪界面）。
- `Backup.swift`：备份导出/导入。自定义流式容器（魔数 + 内容 + 尾部清单），`BackupManager` 负责读写、`BackupTaskRunner` 管进度/取消、`BackupExportPicker` 递文件给系统，`backupContentType` 是 `.melohabk` 的已声明类型。旧 JSON 备份仍可导入。
- `ChatBot.swift` / `ChatView.swift`：本地 MLX 聊天机器人（控制器 + 界面）。
- `SubtitlePiP.swift`：画中画字幕渲染。
- `Info.plist`（物理文件，位于 SRCROOT）：后台音频/PiP 的 `UIBackgroundModes` 必须写在这（见记忆）。

## 二、编译/验证（重要）

MLX 依赖 Metal，**只能真机**，无法在模拟器跑。验证用真机 SDK、未签名编译：

```
cd /Users/hansen/Desktop/Projects/SubtitlePlayer/SubtitlePlayer
xcodebuild -project SubtitlePlayer.xcodeproj -scheme SubtitlePlayer -sdk iphoneos -configuration Debug build CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation
```

- 编译约 2 分钟；建议 `run_in_background: true` 跑，然后 grep `BUILD SUCCEEDED|error:|warning:`。
- 结果里出现 `Ignoring --strip-bitcode` 和 `appintentsmetadataprocessor ... Metadata extraction skipped` 都是**无害**的，可过滤掉。
- **功能只能用户在真机 ⌘R 重装后手测**。每次改完的固定节奏：我 build 验证 → 报告 → 用户 ⌘R 重装并测试 → 反馈。
- Bash 分类器偶发拒绝（transient），重试通常就过；必要时用 `run_in_background`。

### ⚠️ SourceKit 误报（务必忽略，以 xcodebuild 为准）
新增/编辑后经常看到这些**假报错**，因为 SourceKit 按 macOS SDK 或单文件索引：
- `No such module 'UIKit'`
- `'AVAudioSession' is unavailable in macOS` / `navigationBarTitleDisplayMode ... unavailable in macOS`
- `Cannot find 'AudioDocumentPicker' in scope`（其实在 Library.swift，同 target 可见）

只要 `xcodebuild ... -sdk iphoneos` 输出 `** BUILD SUCCEEDED **` 就是好的。

### 工程特性
- 用 **同步文件组**（`PBXFileSystemSynchronizedRootGroup`）：在源码目录里新建 `.swift` 文件会**自动纳入编译**，无需改 `project.pbxproj`（`Metronome.swift` 就是这样加的）。
- 开了 `MEMBER_IMPORT_VISIBILITY`：用 `@Published`/`ObservableObject` 的文件必须**显式 `import Combine`**（见记忆）。

## 三、本会话做的改动（按时间）

1. **专辑内导入音频回调不触发** → 根因是被 push 的子页 `.fileImporter` 被祖先的 presentation 吞掉；改用 UIKit `AudioDocumentPicker`（`UIDocumentPickerViewController`, `asCopy:true`）经 `.sheet` 呈现。
2. **深层/iCloud 文件导入"没反应"** → 云端占位符未下载，`copyItem` 静默失败；`importAudioToDocuments` 加 `NSFileCoordinator` 协调读取兜底 + 导入结果 toast 显式提示成功/失败数。文件页导入也复用了这套。
3. **删除「文件」页，改为 `[专辑 | 小工具]`**（用户明确要，只用专辑管理音乐）：
   - `LibraryMode` 改为 `.albums`/`.tools`，默认 `.albums`。
   - 删了全局导入入口、文件平铺列表、搜索音频、排序、逐文件重命名、库内配字幕，以及一整批只服务文件页的死代码。
   - 音频导入现在只在专辑内（"从文件导入音频"）。
4. **小工具页**（`AudioFilesView.toolsList`）：掷骰子 🎲、抽纸牌 🃏（本地真随机，结果走顶部 toast + 行尾记上次结果）；下面「工具」组里有节拍器入口。
5. **「未分类」虚拟专辑**（`UncategorizedView` + `AlbumStore.uncategorizedURLs()`）：专辑列表顶部自动出现，聚合不在任何专辑里的松散音频，可直接播放、左滑删除（连同同名字幕）。无松散文件时不显示。
6. **demo 可"删"**：内置 `demo.wav` 是只读的删不掉，改为持久隐藏（`UserDefaults` 键 `hideDemoTrack`），`documentsAudioURLs()` 之后不再补它。
7. **节拍器**（`Metronome.swift`）：BPM 40–240、每小节 1–8 拍（首拍重音）、节拍点可视化、开始/停止。声音用 AVAudioEngine 程序生成咔哒声。
8. **节拍器调速闪退修复**：`bpm`/`beatsPerBar` 的 `didSet` 里回写自身做夹取会**无限递归崩溃**；改为 didSet 不回写、范围在 UI 侧（滑杆/Stepper/加减按钮）夹取。
9. **节拍器自定义音效**：可上传音频当节拍声（首拍原音量、其余拍 ×0.6）；存 App Support（不进 Documents 免得混入音乐库）；解码转成引擎格式；`UserDefaults` 键 `metronomeCustomSoundFile` 记住；播放用 `.interrupts` 防叠加；可"恢复默认"。

**当前状态：全部改动 `BUILD SUCCEEDED`，无报错无警告。等用户真机手测。**

## 三之二、后续会话的改动

10. **列表显示字幕配置状态**：新增 `matchingSubtitleURL(for:)` + `subtitleFileExtensions` + `SubtitleBadge`（都在 `Library.swift`，全局）。专辑详情页与播放队列的歌曲行尾显示：已配字幕=蓝色实心气泡+格式名，未配=灰色空心气泡。原先散在 3 处的字幕扩展名硬编码已统一到 `subtitleFileExtensions`。
    - ⚠️ `captions.bubble.slash` **这个 SF Symbol 不存在**（`.slash` 变体不是每个符号都有）。图标名写错不会编译报错，只会静默渲染空白 —— 新增图标前务必验证符号是否存在。
11. **骰子/纸牌改为独立子页 + 加抽签**（`MiniTools.swift`）：
    - 三个页面都从小工具列表 `NavigationLink` 进入，与节拍器一致。
    - 动画统一用 `Task` + `async` 循环手动控制每帧间隔（先快后慢），**不用**一条长时间隐式动画 —— 这样 `onDisappear` 能直接 `cancel()`，不会留下半路状态。
    - 骰子：1–6 颗，各自错开停下，`die.face.N` 符号 + 倾角/缩放。
    - 纸牌：真实牌堆语义（52 张抽完为止、可洗牌），3D 翻牌用 `rotation3DEffect`；牌面需再转 180° 否则是镜像；连抽时先用 `Transaction.disablesAnimations` 把角度归零，否则会看到牌倒着转回去。
    - 抽签：选项自定义、`@AppStorage` 持久化（按 `\n` 分隔存一个 String），转盘式高亮绕两圈后停在目标。
    - 「上次结果」从 `@State` 改为 `@AppStorage`（`lastDiceResult`/`lastCardResult`/`lastLotteryResult`），子页面写、列表行尾读。
12. **音频裁剪**（`AudioTrimmer.swift`，小工具页「工具」组）：选音频 → 输入 mm:ss 或拖滑杆定区间 → 试听 → 导出为 Documents 里的新 M4A，原文件不动。
    - ⚠️ **iOS 的 `AVAssetExportSession` 不能写 MP3**，只能 `AVAssetExportPresetAppleM4A` + `.m4a`。裁 MP3 的输出扩展名会变成 m4a（库支持读，能正常播）。
    - ⚠️ 新 API 是 `export(to:as:)`，**区间通过 `session.timeRange` 属性传**，不是 `export` 的参数（写成参数会报 "Extra argument 'timeRange'"）。旧的 `exportAsynchronously` 已废弃。
    - `naturalTimeScale` 要用 `try await track.load(.naturalTimeScale)`，直接取属性有废弃警告。
    - 试听用 `AVAudioPlayer` + `Task.sleep` 手动到点停（AVAudioPlayer 没有区间播放能力）。
    - 导出中断会 `removeItem` 清掉半成品，免得污染音乐库。

## 四、必须知道的坑（否则会重蹈覆辙）

1. **别叠 presentation 修饰符**：同一视图节点上多个 `.sheet`/`.fileImporter`/`.alert`/`.confirmationDialog` 会互相顶掉（弹不出或回调不触发）。多的挂到 `.background(Color.clear.<modifier>(...))` 独立节点。（记忆：`no-stacked-presentation-modifiers`）
2. **跨导航层级的 fileImporter**：被 push 的子页里若祖先已挂了 `.fileImporter`，子页的 `.fileImporter` 完成回调仍会被吞——这种情况直接用 UIKit `AudioDocumentPicker`（`.sheet` 呈现），别用 SwiftUI `.fileImporter`。（记忆同上）
3. **导入外部文件**：一律走 `importAudioToDocuments()`（含 iCloud 协调读取），别再各写裸 `copyItem`；失败要 toast，别静默 `try?`。（记忆：`import-cloud-files-needs-coordinator`）
4. **`@Published` 的 didSet 别回写自身**：会无限递归闪退。范围校验放调用处或用守卫。
5. **`import Combine`**：见上（MEMBER_IMPORT_VISIBILITY）。
6. **UIBackgroundModes**：必须写在 SRCROOT 的物理 Info.plist，`INFOPLIST_KEY_UIBackgroundModes` 会被静默忽略。（记忆：`uibackgroundmodes-needs-physical-infoplist`）
7. **新增 SF Symbol 前先验证存在**：图标名写错**不会编译报错**，只会静默渲染成空白。`captions.bubble.slash`、`bubble.slash`、`text.bubble.slash` 都不存在。验证方法：写个小 Swift 脚本用 `NSImage(systemSymbolName:accessibilityDescription:)` 判空（macOS 与 iOS 共用同一套符号库）。
8. **SwiftUI 类型检查超时**：`body` 里塞太多嵌套条件会报 "unable to type-check this expression in reasonable time"（这是**真报错**，不是 SourceKit 误报）。拆成多个 `@ViewBuilder` 计算属性即可。
9. **`.tint.gradient` 不存在**：`ShapeStyle` 的 `.tint` 没有 `.gradient` 成员，用 `Color.accentColor.gradient`。
10. **搬大文件时循环里必须套 `autoreleasepool`**：`FileHandle.read(upToCount:)` 返回的是桥接来的 `NSData`，进当前 autorelease pool，而循环中途不排空。少了它，"流式"读 300MB 会实打实攒下 300MB 匿名内存（实测 301.3 MB → 加上后 1.2 MB）。这是导出备份闪退的第二个原因。
11. **量内存别看 `resident_size`**：它把文件页缓存（干净页、系统随时可回收）也算进去，流式搬运会显示成与数据等大，看不出问题。iOS 的 jetsam 看的是 `phys_footprint`，而定位泄漏要看 `task_vm_info.internal`（匿名内存）。
12. **`UInt64` 减法会 trap**：从文件读来的长度/偏移先校验再参与算术。写成 `fileSize - footer - manifestLength` 或 `reduce(+)`、`Int64(totalBytes)`，遇到坏备份就是直接闪退而不是报错。已在 `restoreStreaming` 里改成加法比较 + `addingReportingOverflow`。
13. **自定义扩展名必须在 Info.plist 里声明类型**，否则「文件」选择器里是灰的选不中。未声明的扩展名在系统里只解析成动态类型（`dyn.xxxx`），光在 `allowedContentTypes` 里写 `.data` 不管用。`.melohabk` 声明成 `com.hansen.SubtitlePlayer.backup`（`UTExportedTypeDeclarations` + `CFBundleDocumentTypes`）后才正常。
    - ⚠️ 验证陷阱：在 macOS 上用 `UTType(filenameExtension:)` 测会显示它 conform 到 `.data`，看着没问题 —— 但那测的是本地文件类型解析，**不是 iOS 选择器的过滤行为，结论不能拿来当依据**。这一条就是这么漏过去的。
    - 改了 Info.plist 的类型声明后**必须重装 App**（⌘R）才生效，类型是装机时注册的。
14. **MLX 聊天机器人**：3 个 SPM 依赖 + Metal 工具链 + 只能真机 + 跳过插件/宏验证；国内下载走 `HF_ENDPOINT` 镜像；模型缓存持久化只设 `HF_HOME` 指向 `Library/hf-models`。（记忆：`mlx-local-chatbot-setup`）

### ⚠️ 关于「测过了」的边界（2.1 的教训）

2.1 发出去的备份功能导入不了。往返逻辑有 25 项测试、内存也量过，但**全部集中在纯 Foundation 那一层**；真正坏掉的三处都在没测的那层，且**每一处都违反了上面已经写下的坑**：

- `.fileImporter` 和 `.alert` 叠在同一节点（坑 1、2）
- 读外部文件没有 `NSFileCoordinator`（坑 3）
- 自定义扩展名没声明类型（坑 13，当时还不存在）

教训：坑列表要在**改完之后逐条对一遍**，不能只在写的时候凭印象避开。UI 层（presentation 修饰符、文件选择、类型注册、security scope）在 Mac 上一行都测不到，属于「只能真机验」的部分 —— 发布前必须真机跑一次完整往返，把「没测过」写进交付说明不等于尽到责任。

## 五、待办 / 提过但用户没定的事

- **节拍器静音键**：现在可能受手机静音键影响没声。提议过让它强制 `.playback` 忽略静音键，**用户 8/22 答复「暂时不管」**——别再主动问，除非用户提起。
- **节拍器**：可选加 Tap 打拍测速、拖滑杆时不重复响。
- **「未分类」**：可选加左滑"加入专辑"操作（弹专辑菜单）。
- **AI 播放控制**：小模型不稳时可加关键词兜底（`ChatBot.swift` 的 `<<PLAY>>` 等标记协议已实现）。
- **专辑删除键**：用户明确说**不用改**，保留列表里"左滑删除、右滑重命名"的现状。
- **去背景音（人声分离）**：8/23 评估后**用户决定不做**。三条路：相位取消（几十行但鼓/贝斯一起被削、声音变窄、对现代母带无效）、Apple Vocal Isolation（只对通话开放，无第三方 API）、ML 模型如 Demucs（质量好但要几十~几百 MB 模型 + Core ML 转换 + 无法实时）。**真正的成本不在算法而在换引擎**——见下条。
- **音效类功能（消音/均衡器/变调）的共同前提**：现在播放核心是 `AVAudioPlayer`，**不支持插入音频处理节点**，任何音效都得先迁到 `AVAudioEngine`。而倍速、锁屏控制、PiP 字幕、Now Playing 全挂在 `AVAudioPlayer` 上，迁移意味着这些都要重新验证。评估过两次（均衡器/变调、去背景音），两次结论都是收益撑不起风险。
- README 的"本地 AI 助手/小工具"章节（提过，未做）。

## 六、记忆文件（`~/.tclaude/projects/-Users-hansen-Desktop-Projects-SubtitlePlayer/memory/`）

`MEMORY.md` 是索引，会自动加载。现有条目：
- `uibackgroundmodes-needs-physical-infoplist`
- `mlx-local-chatbot-setup`
- `project-requires-explicit-combine-import`
- `no-stacked-presentation-modifiers`
- `import-cloud-files-needs-coordinator`

新会话若发现新的、非显而易见的项目级事实/用户反馈，按记忆规范补充。
