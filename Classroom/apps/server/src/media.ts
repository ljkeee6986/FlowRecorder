import type { MediaGrant, Participant } from "@flowrecorder/contracts";
import { createRequire } from "node:module";
import { config } from "./config.js";

const require = createRequire(import.meta.url);

interface TlsSigApi {
  genUserSig(userId: string, expire: number): string;
  genPrivateMapKeyWithStringRoomID(userId: string, expire: number, roomId: string, privilegeMap: number): string;
}

interface TlsSigConstructor {
  new (sdkAppId: number, secretKey: string): TlsSigApi;
}

const { Api: TlsSigApi } = require("tls-sig-api-v2") as { Api: TlsSigConstructor };
const mediaGrantLifetimeSeconds = 6 * 60 * 60;

export type MediaRole = "viewer" | "cohost" | "teacher";
export type MediaIdentity = Pick<Participant, "id" | "roomId">;

export interface MediaProvider {
  readonly name: "mock" | "trtc";
  createGrant(identity: MediaIdentity, role: MediaRole): Promise<MediaGrant>;
}

export class MockMediaProvider implements MediaProvider {
  readonly name = "mock" as const;

  async createGrant(identity: MediaIdentity, role: MediaRole): Promise<MediaGrant> {
    const canPublish = role !== "viewer";
    return {
      provider: "mock",
      roomId: identity.roomId,
      userId: trtcUserId(identity.id, role),
      canPublishAudio: canPublish,
      canPublishVideo: canPublish,
      canPublishScreen: role === "teacher",
      expiresAt: new Date(Date.now() + mediaGrantLifetimeSeconds * 1000).toISOString()
    };
  }
}

export class TencentTrtcProvider implements MediaProvider {
  readonly name = "trtc" as const;
  private readonly signer: TlsSigApi;
  private readonly sdkAppId: number;

  constructor(sdkAppId = config.trtc.sdkAppId, secretKey = config.trtc.secretKey) {
    this.sdkAppId = sdkAppId;
    this.signer = new TlsSigApi(sdkAppId, secretKey);
  }

  async createGrant(identity: MediaIdentity, role: MediaRole): Promise<MediaGrant> {
    const expiresInSeconds = mediaGrantLifetimeSeconds;
    const userId = trtcUserId(identity.id, role);
    const privilegeMap = privilegesFor(role);
    return {
      provider: "trtc",
      roomId: identity.roomId,
      userId,
      canPublishAudio: role !== "viewer",
      canPublishVideo: role !== "viewer",
      canPublishScreen: role === "teacher",
      expiresAt: new Date(Date.now() + expiresInSeconds * 1000).toISOString(),
      sdkAppId: this.sdkAppId,
      userSig: this.signer.genUserSig(userId, expiresInSeconds),
      privateMapKey: this.signer.genPrivateMapKeyWithStringRoomID(userId, expiresInSeconds, identity.roomId, privilegeMap)
    };
  }
}

const privilege = {
  createRoom: 1,
  joinRoom: 2,
  sendAudio: 4,
  receiveAudio: 8,
  sendVideo: 16,
  receiveVideo: 32,
  sendScreen: 64,
  receiveScreen: 128
} as const;

function privilegesFor(role: MediaRole): number {
  const receive = privilege.joinRoom | privilege.receiveAudio | privilege.receiveVideo | privilege.receiveScreen;
  if (role === "viewer") return receive;
  if (role === "cohost") return receive | privilege.sendAudio | privilege.sendVideo;
  return 255;
}

function trtcUserId(id: string, role: MediaRole): string {
  const prefix = role === "teacher" ? "t_" : "u_";
  return `${prefix}${id.replace(/[^a-zA-Z0-9_-]/g, "").replaceAll("-", "").slice(0, 30)}`;
}

export const mediaProvider: MediaProvider = config.trtc.enabled
  ? new TencentTrtcProvider()
  : new MockMediaProvider();
