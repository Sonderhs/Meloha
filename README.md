# Meloha 🎧

一款专注**字幕/歌词同步**的 iOS 本地音频播放器。用 SwiftUI 编写，支持 LRC / SRT / VTT 字幕、后台播放、锁屏控制、画中画字幕小窗，以及类似网易云音乐的音乐库 + 迷你播放器体验。

> 工程名 / Bundle 仍为 `SubtitlePlayer`（`com.hansen.SubtitlePlayer`），App 显示名为 **Meloha**。

---

## ✨ 功能

**播放**
- 本地音频播放：`mp3 / m4a / wav / aac / aiff`
- 播放 / 暂停、可拖动进度条、快退 / 快进 15 秒
- 播放速度 0.5×–2×
- 播放模式：顺序 / 列表循环 / 单曲循环 / 随机，自然播完自动连播
- 播放队列页（当前专辑/列表的曲目，点击跳转）
- 上一曲 / 下一曲
- 睡眠定时器（15/30/60/90 分钟）
- 后台播放 + 锁屏 / 控制中心控制（播放暂停、快进快退、进度、封面）
- 「允许与其他应用同时播放」（`.mixWithOthers` 混音）

**字幕 / 歌词**
- 解析 LRC / SRT / VTT，按同名自动匹配音频
- 三行歌词式显示（上一句 / 当前句 / 下一句），逐行滚动淡入淡出
- 整篇歌词页：全歌词滚动、当前句高亮、**点任意句跳转**
- 字幕时间偏移（±，可归零）
- 字幕外观设置：字号、颜色、显示行数（1/3/5）——播放器、歌词页、画中画三处一致
- **画中画（PiP）字幕小窗**：把字幕渲染成帧显示在系统悬浮窗，切到别的 App 也能看

**音乐库**
- 「文件」与「专辑」两种视图
- 专辑为用户自建，可添加/移除歌曲、设置封面、拖动排序、重命名
- 搜索、按名称 / 添加时间排序
- 滑动删除音频（联动删除同名字幕）/ 删除、重命名专辑
- 音频封面：优先内嵌封面，无内嵌则用所属专辑封面兜底
- 迷你播放器 + 收起 / 展开

**外观 & 数据**
- 主题：跟随系统 / 浅色 / 深色
- 自定义背景图片 + 不透明度调节
- 从其他 App / 「文件」分享或「用…打开」导入音频、字幕
- 批量导入音频 / 字幕
- **导出 / 导入备份**：把所有音频、字幕、专辑、封面、背景、设置打包成一个文件，重装后一键恢复

---

## 🧱 技术栈

- **SwiftUI**（iOS 26.0 部署目标，Xcode 26）
- **AVFoundation** — `AVAudioPlayer` 播放、`AVAudioSession` 会话、封面元数据读取
- **MediaPlayer** — `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` 锁屏控制
- **AVKit** — `AVPictureInPictureController` + `AVSampleBufferDisplayLayer` 自定义内容源实现字幕画中画
- **PhotosUI** — `PhotosPicker` 选背景图 / 专辑封面
- 持久化：`UserDefaults`（`@AppStorage` 设置）+ App `Documents` 目录（音频、字幕、`albums.json`、封面、背景图）

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
      ├─ Library.swift              # 专辑/背景/主题/设置/歌词页/播放队列/备份/Toast
      ├─ SubtitlePiP.swift          # 画中画控制器与字幕帧渲染
      ├─ Assets.xcassets            # 含 AppIcon
      └─ demo.wav / demo.lrc        # 内置示例
```

> 说明：`Info.plist` 是**物理文件**（不是纯生成的）。因为 `INFOPLIST_KEY_UIBackgroundModes` 在此工程会被忽略，`UIBackgroundModes = audio`（后台音频，也是 PiP 前提）必须写在物理 Info.plist 里，并放在同步组文件夹之外。

---

## ▶️ 运行

1. 用 **Xcode 26+** 打开 `SubtitlePlayer/SubtitlePlayer.xcodeproj`。
2. `TARGETS → Signing & Capabilities` 勾选 **Automatically manage signing**，选一个 Team（免费个人 Apple ID 即可）。
3. 顶部选择目标设备（真机需 **iOS 26.0+**），按 **⌘R** 运行。
4. 首次真机运行后，在 **设置 → 通用 → VPN与设备管理** 里信任你的开发者证书。

> 免费账号签名 7 天过期，过期后重新 ⌘R 一次即可（数据不丢）。

---

## 📦 打包 IPA（自用 / 爱思助手安装）

```bash
cd SubtitlePlayer          # 进入 .xcodeproj 所在目录
sh build-ipa.sh
```

- 产物：`~/Desktop/Meloha.ipa`（**未签名**）。
- 用爱思助手 / Sideloadly 等导入安装时会用你的 Apple ID 重新签名。

---

## 💾 数据与备份

- 所有内容存于 App 沙盒：音频/字幕/`albums.json`/封面/背景 → `Documents`；各项设置 → `UserDefaults`。
- **覆盖安装且签名一致**时数据保留；App 被删除、或换了不同签名的包安装时，沙盒会被清空。
- 建议：**设置 → 数据 → 导出备份**，存到「文件」/iCloud；重装后 **导入备份** 恢复。

---

## 📝 说明 / 限制

- 画中画为纯音频场景下的自绘字幕帧，**需真机**（模拟器对自定义 `AVSampleBufferDisplayLayer` 的 PiP 支持不完整）。
- 部署目标 iOS 26.0，覆盖设备较少；如需更广兼容可下调到 iOS 17/18（代码仅用到 iOS 17+ API）。
- 内置 `demo.wav / demo.lrc` 仅作示例，如需上架请替换为自有/授权内容。
