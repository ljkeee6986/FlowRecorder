import type { MediaGrant, Participant } from "@flowrecorder/contracts";
import { config } from "./config.js";

export interface MediaProvider {
  readonly name: "mock" | "trtc";
  createGrant(participant: Participant, canPublish: boolean): Promise<MediaGrant>;
}

class MockMediaProvider implements MediaProvider {
  readonly name = "mock" as const;

  async createGrant(participant: Participant, canPublish: boolean): Promise<MediaGrant> {
    return {
      provider: "mock",
      roomId: participant.roomId,
      userId: participant.id,
      canPublishAudio: canPublish,
      canPublishVideo: canPublish,
      expiresAt: new Date(Date.now() + 60 * 60 * 1000).toISOString()
    };
  }
}

// The signer is deliberately isolated so no TRTC secret can ever reach a browser bundle.
// It will be replaced with Tencent's server-side UserSig/PrivateMapKey implementation
// when a real TRTC application is provisioned.
class TencentTrtcProvider implements MediaProvider {
  readonly name = "trtc" as const;

  async createGrant(_participant: Participant, _canPublish: boolean): Promise<MediaGrant> {
    throw new Error("TRTC credentials are configured, but the production signer is not installed yet");
  }
}

export const mediaProvider: MediaProvider = config.trtc.enabled
  ? new TencentTrtcProvider()
  : new MockMediaProvider();
