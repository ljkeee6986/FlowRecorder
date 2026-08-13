# FlowRecorder / 录屏大师Jack

轻量 macOS 录屏工具测试版，面向创作者、课程讲解、产品演示、作品复盘场景。当前重点是稳定生成可播放 MP4，避免录制完成后出现“损坏录屏”。

## 当前测试版

- 版本：`v0.2.0-test`
- App 显示版本：`测试版 v0.2.0 (20)`
- 测试包位置：`/Users/kun/Desktop/FlowRecorder测试版/录屏大师Jack.app`
- 默认输出目录：`~/Movies/FlowRecorder`
- 诊断日志：`~/Movies/FlowRecorder/status.txt`
- 隔离目录：`~/Movies/FlowRecorder/损坏录屏`

## 已支持能力

- 使用 macOS ScreenCaptureKit 原生录制输出 MP4。
- 支持主屏幕全屏录制。
- 支持系统声音录制，默认开启。
- 支持麦克风录制，默认关闭；开启前会检查麦克风权限。
- 支持全屏、手动框选、16:9 横屏、9:16 竖屏、1:1 方形录制范围。
- 支持窗口区域录制；开录前会确认窗口仍然存在，避免录到旧位置。
- 支持导出清晰度：原画、最高 1080P、最高 720P、最高 540P。
- 支持录制前 3 秒倒计时，倒计时中可再次点击录制按钮取消。
- 支持悬浮录制控制条，控制条不会被录进视频。
- 支持鼠标点击高亮后处理；后处理失败时保留可播放原始视频。
- 支持圆形摄像头悬浮小窗和提词器悬浮窗。
- 支持录制前健康检查：输出目录、磁盘空间、屏幕录制权限、麦克风权限。
- 支持复制诊断，包含版本、macOS、App 路径、最近录屏、临时文件和日志尾部。

## 损坏录屏防护

- 录制文件先写入 `.in-progress` 临时目录，保存成功后才移动到最终目录。
- 停止录制后会等待系统原生 MP4 封装完成，并验证文件可播放。
- 开启音频源时会校验 MP4 至少包含 1 条音轨。
- 保存中退出会被拦截；录制中退出会先安全停止并保存，保存成功后才退出。
- 启动时会隔离上次未完成的 `.in-progress` 文件，避免影响新录制。
- 诊断日志会自动轮转，避免长期使用后无限增长。

## 快捷键

- `Command + R`：开始 / 停止录制。

## 首次运行权限

macOS 会拦截所有录屏软件。第一次使用时需要手动允许：

1. 打开系统设置。
2. 进入“隐私与安全性”。
3. 找到“屏幕与系统音频录制”。
4. 允许“录屏大师Jack”。
5. 退出并重新打开 App。

如果不开这个权限，应用会显示权限错误，不会生成视频文件。

## 发布前手动回归

每次准备发测试包时，至少录以下 5 条样本，并用 `ffprobe` 验证：

- 全屏 + 系统声：输出 H.264 + AAC。
- 9:16 竖屏：输出可播放，比例接近 9:16。
- 1:1 方形：输出可播放，比例接近 1:1。
- 麦克风开启：输出 H.264 + AAC，并能听到人声。
- 鼠标点击开启：真实手点 2–3 下，输出可播放，点击光圈可见。

检查命令：

```bash
latest=$(ls -t "$HOME/Movies/FlowRecorder"/*.mp4 2>/dev/null | head -1)
ffprobe -v error \
  -show_entries format=duration,size \
  -show_entries stream=index,codec_type,codec_name,width,height \
  -of default=noprint_wrappers=1 "$latest"
find "$HOME/Movies/FlowRecorder/.in-progress" -maxdepth 1 -type f -print
tail -40 "$HOME/Movies/FlowRecorder/status.txt"
```

## 已知限制

- 当前只支持 macOS 15+。
- 当前只打包本地测试版 `.app`，尚未做 DMG / notarization。
- 摄像头小窗目前依赖屏幕可见内容被捕获；不是独立合成轨道。
- 区域/窗口录制通过稳定全屏捕获后裁剪完成；录制中移动窗口可能导致裁剪区域不符合预期。
- UI 自动化对 SwiftUI 坐标点击不稳定，9:16 / 1:1 / 鼠标点击高亮仍建议人工回归确认。

## 构建

```bash
cd /Users/kun/Documents/Codex/FlowRecorder
./build.sh
ditto build/FlowRecorder.app "/Users/kun/Desktop/FlowRecorder测试版/录屏大师Jack.app"
codesign --verify --deep --strict "/Users/kun/Desktop/FlowRecorder测试版/录屏大师Jack.app"
```

## 下一步

- 完成 5 条人工回归样本。
- 如全部通过，保留 `v0.2.0-test` 作为当前稳定测试版。
- 下一轮再考虑 DMG 打包、notarization、摄像头独立合成、自动回归脚本。
