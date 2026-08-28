# Meloha 🎧

一款专注**字幕/歌词同步**的 iOS 本地音频播放器。用 SwiftUI 编写，支持 LRC / SRT / VTT 字幕、后台播放、锁屏控制、画中画字幕小窗，以及类似网易云音乐的音乐库 + 迷你播放器体验。另含设备端本地 AI 助手与若干音频小工具。

> 工程名 / Bundle 仍为 `SubtitlePlayer`（`com.hansen.SubtitlePlayer`），App 显示名为 **Meloha**。

---

## ✨ 功能

**播放**
- 本地音频播放：`mp3 / m4a / wav / aac / aiff`
- 播放 / 暂停、可拖动进度条、快退 / 快进 15 秒
- 播放速度 0.5×–2×
- 播放模式：顺序 / 列表循环 / 单曲循环 / 随机，自然播完自动连播
- 播放队列页（点击跳转，行尾显示字幕状态）
- 上一曲 / 下一曲
- 睡眠定时器（15/30/60/90 分钟）
- 后台播放 + 锁屏 / 控制中心控制（播放暂停、快进快退、进度、封面）
- 读取内嵌 ID3 元数据：标题、艺术家、封面。文件名是 `RJ01234567` 这类编号时，显示内嵌标题更可读
- 「允许与其他应用同时播放」（`.mixWithOthers` 混音）

**字幕 / 歌词**
- 解析 LRC / SRT / VTT，按同名自动匹配音频（优先级 SRT → VTT → LRC）
- 歌词式显示（上一句 / 当前句 / 下一句），逐行滚动淡入淡出
- 整篇歌词页：全歌词滚动、当前句高亮、**点任意句跳转**
- 字幕时间偏移（±0.5/1s，可归零）
- 字幕外观设置：字号、颜色、显示行数（1/3/5）——播放器、歌词页、画中画三处一致
- **画中画（PiP）字幕小窗**：把字幕渲染成帧显示在系统悬浮窗，切到别的 App 也能看
- 音乐库内导入字幕；文件名与音频不同名时，弹列表选「配给哪首歌」并自动改名对齐
- 曲目行显示是否已配字幕（蓝色实心气泡 + 格式 / 灰色空心气泡）

**音乐库**
- 「专辑」与「小工具」两个标签页
- 专辑为用户自建：添加/移除歌曲、设置封面、重命名、拖动排序
- **专辑内分组**（一层，如 CD1/CD2、原曲/伴奏），可折叠；播放队列始终是整张专辑，在分组里点歌也能连着往下听
- **专辑图片集**：与封面无关的内容图（歌词本、内页、乐谱等），可看大图、缩放、删除
- **备注与标签**：记社团/声优/来源，打标签；名称、备注、标签都能搜索，标签栏可一键筛选
- **每张专辑独立的排序方式**：名称 / 导入时间 / 时长 / 手动（各含正倒序）
- 封面与图片均可从**相册**或**「文件」**选择
- 「未分类」虚拟专辑：聚合不属于任何专辑的音频，可直接导入音频/字幕
- 滑动删除音频（联动删除同名字幕）/ 删除、重命名专辑
- 迷你播放器 + 收起 / 展开

**小工具**
- **音频裁剪**：毫秒级选段（输入框 / 滑杆 / ±0.01 微调），可试听选中段（带进度条），导出为新文件，原文件不动
- **从链接下载**：音频直链下载，带进度，校验 HTTP 状态、MIME 与可解码性
- **节拍器**：BPM 40–240、每小节 1–8 拍（首拍重音）、节拍点可视化；节拍声可用内置咔哒声或自选音频（取开头约 2 秒）
- 掷骰子 / 抽纸牌 / 抽签（本地随机，各有独立页面与动画）

**本地 AI 助手**
- 设备端离线大模型（MLX Swift）：Qwen3 0.6B / Llama 3.2 1B / Qwen2.5 1.5B / 3B（4bit 量化）
- 模型下载进度、可删除释放空间、支持国内镜像源
- 可带入当前歌曲信息（歌名 + 歌词）提问
- 可通过对话控制播放（播放/暂停/上下曲/快进快退）
- 自定义人设（系统提示）

**外观 & 数据**
- 主题：跟随系统 / 浅色 / 深色
- 自定义背景图片 + 不透明度调节
- 从其他 App / 「文件」分享或「用…打开」导入音频、字幕
- **导出 / 导入备份**：把所有音频、字幕、专辑、封面、图片、背景、设置打包成一个文件，重装后一键恢复

---

## 🧱 技术栈

- **SwiftUI**（iOS 26.0 部署目标，Xcode 26）
- **AVFoundation** — `AVAudioPlayer` 播放、`AVAudioSession` 会话、元数据读取；`AVAssetExportSession` 裁剪导出；`AVAudioEngine` 节拍器音效生成
- **MediaPlayer** — `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` 锁屏控制
- **AVKit** — `AVPictureInPictureController` + `AVSampleBufferDisplayLayer` 自定义内容源实现字幕画中画
- **PhotosUI** — `PhotosPicker` 选背景图 / 封面 / 专辑图片
- **MLX Swift** — 设备端大模型推理（依赖 Metal，**仅真机**）
- 持久化：`UserDefaults`（`@AppStorage` 设置）+ App `Documents` 目录（音频、字幕、`albums.json`、封面、图片、背景图）

---

## 📁 项目结构

```
SubtitlePlayer/                     # 仓库根
└─ SubtitlePlayer/                  # 工程目录（含 .xcodeproj）
   ├─ SubtitlePlayer.xcodeproj
   ├─ Info.plist                    # 物理 Info.plist（后台音频、文档类型、显示名等）
   ├─ build-ipa.sh                  # 一键打包未签名 IPA
   └─ SubtitlePlayer/               # 源码（文件系统同步组）
      ├─ SubtitlePlayerApp.swift    # App 入口
      ├─ ContentView.swift          # 播放器主体 + 音乐库（AudioFilesView）
      ├─ Library.swift              # 专辑/分组/图片/背景/主题/设置/歌词页/队列/备份/Toast
      ├─ AudioPicker.swift          # 共享的「选音频」列表与搜索框
      ├─ AudioTrimmer.swift         # 音频裁剪
      ├─ AudioDownloader.swift      # 直链下载
      ├─ Metronome.swift            # 节拍器
      ├─ MiniTools.swift            # 骰子 / 纸牌 / 抽签
      ├─ ChatBot.swift / ChatView.swift  # 本地 MLX 聊天机器人
      ├─ SubtitlePiP.swift          # 画中画控制器与字幕帧渲染
      └─ Assets.xcassets            # 含 AppIcon
```

> 说明：`Info.plist` 是**物理文件**（不是纯生成的）。因为 `INFOPLIST_KEY_UIBackgroundModes` 在此工程会被忽略，`UIBackgroundModes = audio`（后台音频，也是 PiP 前提）必须写在物理 Info.plist 里，并放在同步组文件夹之外。
>
> 源码目录是**文件系统同步组**：新增 `.swift` 文件会自动纳入编译，无需改 `project.pbxproj`。

---

## ▶️ 运行

1. 用 **Xcode 26+** 打开 `SubtitlePlayer/SubtitlePlayer.xcodeproj`。
2. `TARGETS → Signing & Capabilities` 勾选 **Automatically manage signing**，选一个 Team（免费个人 Apple ID 即可）。
3. 顶部选择目标设备（真机需 **iOS 26.0+**），按 **⌘R** 运行。
4. 首次真机运行后，在 **设置 → 通用 → VPN与设备管理** 里信任你的开发者证书。

> 免费账号签名 7 天过期，过期后重新 ⌘R 一次即可（数据不丢）。
>
> ⚠️ AI 助手依赖 Metal，**无法在模拟器运行**，必须用真机。其余功能模拟器可用。

---

## 📦 打包 IPA（自用 / 爱思助手安装）

```bash
cd SubtitlePlayer          # 进入 .xcodeproj 所在目录
sh build-ipa.sh
```

- 产物：`dist/Meloha.ipa`（仓库根同级的 `dist/` 目录，**未签名**）。
- 用爱思助手 / Sideloadly 等导入安装时会用你的 Apple ID 重新签名。

---

## 💾 数据与备份

- 所有内容存于 App 沙盒：音频/字幕/`albums.json`/封面/图片/背景 → `Documents`；各项设置 → `UserDefaults`。
- **覆盖安装且签名一致**时数据保留；App 被删除、或换了不同签名的包安装时，沙盒会被清空。
- 建议：**设置 → 数据 → 导出备份**，存到「文件」/iCloud；重装后 **导入备份** 恢复。

---

## 📝 说明 / 限制

- 画中画为纯音频场景下的自绘字幕帧，**需真机**（模拟器对自定义 `AVSampleBufferDisplayLayer` 的 PiP 支持不完整）。
- AI 助手需真机（Metal）；首次使用需下载模型（几百 MB 到数 GB，视所选模型）。
- 音频裁剪导出为 M4A：**iOS 系统不支持写 MP3**，裁剪 MP3 时输出扩展名会变成 `.m4a`（库内可正常播放）。
- 直链下载默认仅支持 HTTPS（未放开 ATS）；纯 HTTP 链接会被系统拦截。
- 部署目标 iOS 26.0，覆盖设备较少；如需更广兼容需下调部署目标并替换部分新 API。
- App 不再内置示例音频，首次启动为空库，需自行导入。
