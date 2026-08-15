# Jack 在线课堂

`Classroom 0.1` 是录屏大师Jack的在线教学工作区。它与现有 macOS 本地录屏核心隔离，当前用于验证完整课堂业务链路。

## 已完成

- 讲师口令登录、课堂创建与课堂切换。
- 随机课堂链接、旧链接失效和昵称设备身份。
- 开始/结束课堂、540P/720P/1080P 档位和课堂权限设置。
- 微信友好的移动观看页和桌面浏览器观看页。
- WebSocket 实时成员、聊天、举手和讲师控制。
- 同时仅一名学员连麦；讲师可以批准、拒绝、结束连麦、禁言和移出。
- 真实在线人数与可配置课堂热度分开统计。
- 回放登记与腾讯云 COS/VOD 上传占位。
- 微信支付、支付宝支付、订单和课程访问权接口占位，默认关闭。
- PostgreSQL 生产数据表和 Redis/PostgreSQL 本地容器配置。

## 当前边界

- 默认使用内存数据仓库，重启服务后测试课堂数据会清空；生产 PostgreSQL 连接是下一阶段。
- 默认使用 `mock` 音视频提供方。聊天、举手、审批和浏览器摄像头授权可测试，但真实远程音视频需要配置腾讯云 TRTC 并安装服务端签名器。
- 现有 Mac 本地 MP4 录制仍由仓库根目录的 Swift App 独立负责，尚未与课堂开播按钮联动。
- Windows 原生讲师端尚未开始。

## 本地启动

```bash
cd /Users/kun/Documents/Codex/FlowRecorder/Classroom
npm install
npm run dev
```

启动后打开：

- 讲师控制台：`http://localhost:4173/teacher`
- 测试讲师口令：`jack-demo`
- 学员链接：进入控制台后点击“复制链接”。

同一 Wi-Fi 下可以在手机访问终端显示的 `Network` 地址。讲师控制台会按当前访问地址生成可复制的学员链接。

## 验证

```bash
npm run typecheck
npm test
npm run build
```

## 生产准备

1. 复制 `.env.example` 为 `.env`，替换 `JWT_SECRET` 和 `TEACHER_ACCESS_CODE`。
2. 创建腾讯云 TRTC 应用，将签名和高级权限生成逻辑安装在服务端。
3. 启用 PostgreSQL/Redis 数据仓库，不允许生产环境回退到内存。
4. 配置 HTTPS 域名、腾讯云 COS/VOD 和对象存储回调。
5. 完成 iPhone 微信、安卓微信和 100 人压力测试后再对外开放。
