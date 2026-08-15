# Jack 在线课堂

`Classroom 0.2` 是录屏大师Jack的在线教学工作区。它与现有 macOS 本地录屏核心隔离，当前用于验证完整课堂业务链路。

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
- 本地原子文件持久化，服务重启后课堂、链接、消息和回放不会丢失。
- PostgreSQL 生产数据表、读写适配器和 Redis/PostgreSQL 容器配置。
- 腾讯官方 UserSig 与 PrivateMapKey 服务端签名，区分观看、连麦和讲师屏幕分享权限。
- 腾讯官方 TRTC Web SDK 按需加载，支持远端屏幕/摄像头播放和受控学员连麦。
- 跨平台讲师网页推流桥接，可发布屏幕、系统声音、麦克风和摄像头。
- 登录、加入课堂和聊天频率限制。
- 100 名学员同时连接的课堂控制链路自动化测试。

## 当前边界

- 默认使用 `.data/classroom-state.json`，采用临时文件写入后原子替换，文件权限为 `600`。
- 生产环境强制使用 PostgreSQL，禁止退回内存或本地文件；本机没有 PostgreSQL，因此当前通过 PostgreSQL 模拟引擎验证建表、外键和数据往返，正式部署仍需真实云数据库复验。
- 默认使用 `mock` 音视频提供方；配置 TRTC 后，网页观看、讲师网页推流和学员连麦会自动切换到真实音视频。
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
2. 创建腾讯云 TRTC 应用，在控制台开启 PrivateMapKey 严格权限校验，再配置 `TRTC_SDK_APP_ID`、`TRTC_SECRET_KEY` 和 `TRTC_STRICT_PERMISSIONS=true`。
3. 配置 `PERSISTENCE_DRIVER=postgres` 和 `DATABASE_URL`；生产模式会拒绝使用内存或本地文件。
4. 配置 HTTPS 域名、腾讯云 COS/VOD 和对象存储回调。
5. 完成 iPhone 微信、安卓微信和 100 人压力测试后再对外开放。
