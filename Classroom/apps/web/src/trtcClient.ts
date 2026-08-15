import type { MediaGrant } from "@flowrecorder/contracts";
import type TRTC from "trtc-sdk-v5";

interface TeacherTrtcViews {
  screen: () => HTMLElement | null;
  camera: () => HTMLElement | null;
}

export class TeacherTrtcClient {
  private client?: TRTC;

  constructor(
    private readonly views: TeacherTrtcViews,
    private readonly onError: (message: string) => void
  ) {}

  async start(grant: MediaGrant, resolution: "540p" | "720p" | "1080p"): Promise<void> {
    if (grant.provider !== "trtc" || !grant.sdkAppId || !grant.userSig || !grant.privateMapKey) {
      throw new Error("TRTC 讲师凭证不完整");
    }
    if (!grant.canPublishScreen) throw new Error("讲师凭证没有屏幕分享权限");
    const screenView = this.views.screen();
    const cameraView = this.views.camera();
    if (!screenView || !cameraView) throw new Error("讲师预览画面尚未准备完成");

    const { default: TrtcClass } = await import("trtc-sdk-v5");
    const client = TrtcClass.create();
    this.client = client;
    client.on(TrtcClass.EVENT.ERROR, (error) => this.onError(`音视频错误：${error.message ?? error.code}`));
    client.on(TrtcClass.EVENT.SCREEN_SHARE_STOPPED, () => this.onError("屏幕分享已停止，请结束课堂后重新开播"));

    try {
      await client.enterRoom({
        sdkAppId: grant.sdkAppId,
        userId: grant.userId,
        userSig: grant.userSig,
        privateMapKey: grant.privateMapKey,
        strRoomId: grant.roomId,
        scene: TrtcClass.TYPE.SCENE_LIVE,
        role: TrtcClass.TYPE.ROLE_ANCHOR,
        autoReceiveAudio: true,
        autoReceiveVideo: false
      });
      await client.startLocalAudio();
      await client.startLocalVideo({ view: cameraView, option: { profile: "480p", mirror: true } });
      await client.startScreenShare({
        view: screenView,
        option: {
          systemAudio: true,
          fillMode: "contain",
          profile: resolution === "1080p" ? "1080p_2" : resolution === "720p" ? "720p_2" : "480p_2"
        }
      });
    } catch (error) {
      await this.stop();
      throw error;
    }
  }

  async stop(): Promise<void> {
    const client = this.client;
    if (!client) return;
    await Promise.allSettled([
      client.stopScreenShare(),
      client.stopLocalAudio(),
      client.stopLocalVideo()
    ]);
    await client.exitRoom().catch(() => undefined);
    (client.off as unknown as (event: "*") => void)("*");
    this.client = undefined;
  }
}

interface TrtcViews {
  screen: () => HTMLElement | null;
  camera: () => HTMLElement | null;
  localCohost: () => HTMLElement | null;
}

interface TrtcCallbacks {
  onError: (message: string) => void;
  onConnection: (connected: boolean) => void;
  onRemoteVideo: (kind: "screen" | "camera", available: boolean) => void;
}

export class ClassroomTrtcClient {
  private client?: TRTC;
  private TrtcClass?: typeof TRTC;
  private viewerGrant?: MediaGrant;
  private publishing = false;

  constructor(private readonly views: TrtcViews, private readonly callbacks: TrtcCallbacks) {}

  async enter(grant: MediaGrant): Promise<void> {
    if (grant.provider !== "trtc" || !grant.sdkAppId || !grant.userSig || !grant.privateMapKey) {
      throw new Error("TRTC 观看凭证不完整");
    }
    this.viewerGrant = grant;
    const { default: TrtcClass } = await import("trtc-sdk-v5");
    this.TrtcClass = TrtcClass;
    const client = TrtcClass.create();
    this.client = client;

    client.on(TrtcClass.EVENT.ERROR, (error) => this.callbacks.onError(`音视频错误：${error.message ?? error.code}`));
    client.on(TrtcClass.EVENT.KICKED_OUT, () => this.callbacks.onError("音视频连接已被服务器断开"));
    client.on(TrtcClass.EVENT.CONNECTION_STATE_CHANGED, (event) => {
      this.callbacks.onConnection(event.state !== "DISCONNECTED");
    });
    client.on(TrtcClass.EVENT.REMOTE_VIDEO_AVAILABLE, (event) => {
      const kind = event.streamType === TrtcClass.TYPE.STREAM_TYPE_SUB ? "screen" : "camera";
      const view = kind === "screen" ? this.views.screen() : this.views.camera();
      if (!view) return;
      this.callbacks.onRemoteVideo(kind, true);
      void client.startRemoteVideo({ userId: event.userId, streamType: event.streamType, view })
        .catch((error: unknown) => this.callbacks.onError(humanMediaError(error, "播放远端画面失败")));
    });
    client.on(TrtcClass.EVENT.REMOTE_VIDEO_UNAVAILABLE, (event) => {
      const kind = event.streamType === TrtcClass.TYPE.STREAM_TYPE_SUB ? "screen" : "camera";
      this.callbacks.onRemoteVideo(kind, false);
    });

    await client.enterRoom({
      sdkAppId: grant.sdkAppId,
      userId: grant.userId,
      userSig: grant.userSig,
      privateMapKey: grant.privateMapKey,
      strRoomId: grant.roomId,
      scene: TrtcClass.TYPE.SCENE_LIVE,
      role: TrtcClass.TYPE.ROLE_AUDIENCE,
      autoReceiveAudio: true,
      autoReceiveVideo: true,
      enableAutoPlayDialog: true
    });
    this.callbacks.onConnection(true);
  }

  async promote(grant: MediaGrant): Promise<void> {
    const client = this.client;
    const TrtcClass = this.TrtcClass;
    const view = this.views.localCohost();
    if (!client || !TrtcClass || !view || !grant.privateMapKey) throw new Error("音视频课堂尚未连接");
    if (!grant.canPublishAudio || !grant.canPublishVideo) throw new Error("连麦凭证没有发布权限");

    await client.switchRole(TrtcClass.TYPE.ROLE_ANCHOR, { privateMapKey: grant.privateMapKey });
    try {
      await client.startLocalAudio();
      await client.startLocalVideo({ view, option: { profile: "480p", mirror: true } });
      this.publishing = true;
    } catch (error) {
      await Promise.allSettled([client.stopLocalAudio(), client.stopLocalVideo()]);
      await this.switchBackToAudience();
      throw error;
    }
  }

  async demote(): Promise<void> {
    if (!this.client) return;
    if (this.publishing) {
      await Promise.allSettled([this.client.stopLocalAudio(), this.client.stopLocalVideo()]);
      this.publishing = false;
    }
    await this.switchBackToAudience();
  }

  async close(): Promise<void> {
    const client = this.client;
    if (!client) return;
    await Promise.allSettled([client.stopLocalAudio(), client.stopLocalVideo()]);
    await client.exitRoom().catch(() => undefined);
    (client.off as unknown as (event: "*") => void)("*");
    this.client = undefined;
    this.TrtcClass = undefined;
    this.publishing = false;
  }

  private async switchBackToAudience(): Promise<void> {
    if (!this.client || !this.TrtcClass || !this.viewerGrant?.privateMapKey) return;
    await this.client.switchRole(this.TrtcClass.TYPE.ROLE_AUDIENCE, {
      privateMapKey: this.viewerGrant.privateMapKey
    });
  }
}

function humanMediaError(error: unknown, fallback: string): string {
  if (error instanceof Error && error.message) return `${fallback}：${error.message}`;
  return fallback;
}
