# Regression Checklist

用于 `v0.2.0-test` 及后续测试版的发布前人工回归。

## 环境信息

- App：`build/FlowRecorder.app`
- 输出目录：`~/Movies/FlowRecorder`
- 临时目录：`~/Movies/FlowRecorder/.in-progress`
- 日志：`~/Movies/FlowRecorder/status.txt`
- 隔离目录：`~/Movies/FlowRecorder/损坏录屏`

## 每条录完后执行

```bash
latest=$(ls -t "$HOME/Movies/FlowRecorder"/*.mp4 2>/dev/null | head -1)
stat -f '%Sm %z %N' -t '%Y-%m-%d %H:%M:%S' "$latest"
ffprobe -v error \
  -show_entries format=duration,size \
  -show_entries stream=index,codec_type,codec_name,width,height \
  -of default=noprint_wrappers=1 "$latest"
find "$HOME/Movies/FlowRecorder/.in-progress" -maxdepth 1 -type f -print
tail -30 "$HOME/Movies/FlowRecorder/status.txt"
```

通过标准：

- `ffprobe` 无 error。
- 视频流为 H.264。
- 开启任一音频源时有 AAC 音轨。
- `.in-progress` 无残留。
- `status.txt` 最近日志没有“保存失败”。

## 必测场景

| 编号 | 场景 | 设置 | 预期 |
| --- | --- | --- | --- |
| 1 | 全屏 + 系统声 | 全屏、系统声音开、麦克风关、原画 | H.264 + AAC，可播放 |
| 2 | 无音频纯视频 | 全屏、系统声音关、麦克风关、原画 | H.264，可播放，可无音轨 |
| 3 | 9:16 竖屏 | 选择 `9:16 竖屏`、原画 | 可播放，宽高接近 9:16 |
| 4 | 1:1 方形 | 选择 `1:1 方形`、原画 | 可播放，宽高接近 1:1 |
| 5 | 720P 导出 | 全屏、最高 720P | 最长边不超过 1280 |
| 6 | 麦克风 | 麦克风开，说一句话 | H.264 + AAC，人声可听 |
| 7 | 鼠标点击高亮 | 鼠标点击开，真实手点 2–3 下 | 可播放，点击光圈可见 |
| 8 | 录制中退出 | 录制中按 `Command + Q` | 自动安全保存后退出 |
| 9 | 保存中退出 | 停止后保存过程中尝试退出 | 退出被拦截或保存完成后退出 |

## 失败时处理

1. 不要删除失败样本。
2. 点击 App 内“复制诊断”。
3. 保留 `status.txt` 最近 80 行。
4. 检查 `损坏录屏` 目录是否有隔离文件。
5. 记录具体设置：范围、清晰度、系统声、麦克风、点击提示、是否退出过。
