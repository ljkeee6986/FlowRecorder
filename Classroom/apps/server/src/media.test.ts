import { describe, expect, it } from "vitest";
import { MockMediaProvider, TencentTrtcProvider } from "./media.js";

const identity = { id: "5933baf9-c334-4ebf-a540-00bfdd4bba83", roomId: "classroom-test-room" };

describe("media grants", () => {
  it("keeps viewers receive-only and grants cohosts camera/microphone only", async () => {
    const provider = new MockMediaProvider();
    const viewer = await provider.createGrant(identity, "viewer");
    const cohost = await provider.createGrant(identity, "cohost");
    const teacher = await provider.createGrant(identity, "teacher");

    expect(viewer.canPublishAudio).toBe(false);
    expect(viewer.canPublishVideo).toBe(false);
    expect(viewer.canPublishScreen).toBe(false);
    expect(cohost.canPublishAudio).toBe(true);
    expect(cohost.canPublishVideo).toBe(true);
    expect(cohost.canPublishScreen).toBe(false);
    expect(teacher.canPublishScreen).toBe(true);
  });

  it("generates server-side TRTC UserSig and room-bound PrivateMapKey", async () => {
    const provider = new TencentTrtcProvider(1_400_000_000, "test-secret-key-for-signing-only");
    const grant = await provider.createGrant(identity, "viewer");

    expect(grant.provider).toBe("trtc");
    expect(grant.sdkAppId).toBe(1_400_000_000);
    expect(grant.userId.length).toBeLessThanOrEqual(32);
    expect(grant.userSig?.length).toBeGreaterThan(50);
    expect(grant.privateMapKey?.length).toBeGreaterThan(50);
    expect(grant.userSig).not.toBe(grant.privateMapKey);
  });
});
