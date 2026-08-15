import request from "supertest";
import { describe, expect, it } from "vitest";
import { createClassroomServer } from "./app.js";
import { ClassroomStore } from "./store.js";

async function teacherToken(app: ReturnType<typeof createClassroomServer>["app"]): Promise<string> {
  const response = await request(app)
    .post("/api/teacher/session")
    .send({ accessCode: "jack-demo", nickname: "测试讲师" })
    .expect(200);
  return response.body.token as string;
}

describe("classroom API", () => {
  it("creates a room and joins through its private share code", async () => {
    const server = createClassroomServer(new ClassroomStore(false));
    const token = await teacherToken(server.app);
    const created = await request(server.app)
      .post("/api/rooms")
      .set("Authorization", `Bearer ${token}`)
      .send({ title: "测试课堂" })
      .expect(201);

    const joined = await request(server.app)
      .post(`/api/live/${created.body.room.shareCode}/join`)
      .send({ deviceId: "test-device-0001", nickname: "小明" })
      .expect(200);

    expect(joined.body.participant.nickname).toBe("小明");
    expect(joined.body.media.provider).toBe("mock");
    expect(joined.body.media.canPublishAudio).toBe(false);
    expect(joined.body.media.canPublishScreen).toBe(false);

    const teacherGrant = await request(server.app)
      .post(`/api/rooms/${created.body.room.id}/media-grant`)
      .set("Authorization", `Bearer ${token}`)
      .expect(200);
    expect(teacherGrant.body.media.canPublishScreen).toBe(true);
    server.io.close();
  });

  it("rejects an invalid teacher access code", async () => {
    const server = createClassroomServer(new ClassroomStore(false));
    await request(server.app)
      .post("/api/teacher/session")
      .send({ accessCode: "wrong", nickname: "测试讲师" })
      .expect(401);
    server.io.close();
  });

  it("invalidates the old watch link after regeneration", async () => {
    const server = createClassroomServer(new ClassroomStore());
    const token = await teacherToken(server.app);
    const room = server.store.listRooms()[0];
    const oldCode = room.shareCode;

    await request(server.app)
      .post(`/api/rooms/${room.id}/regenerate-link`)
      .set("Authorization", `Bearer ${token}`)
      .expect(200);

    await request(server.app).get(`/api/live/${oldCode}`).expect(404);
    server.io.close();
  });

  it("allows only one active student cohost", () => {
    const store = new ClassroomStore();
    const room = store.listRooms()[0];
    const first = store.joinRoom(room.id, "cohost-device-1", "小明")!;
    const second = store.joinRoom(room.id, "cohost-device-2", "小红")!;

    expect(store.approveCohost(first.id)?.role).toBe("cohost");
    expect(store.approveCohost(second.id)).toBeUndefined();
    expect(store.revokeCohost(first.id)?.role).toBe("viewer");
    expect(store.approveCohost(second.id)?.role).toBe("cohost");
  });

  it("does not restore cohost rights after disconnect and blocks kicked devices", () => {
    const store = new ClassroomStore();
    const room = store.listRooms()[0];
    const participant = store.joinRoom(room.id, "blocked-device", "小明")!;

    expect(store.approveCohost(participant.id)?.role).toBe("cohost");
    expect(store.setParticipantConnected(participant.id, false)?.role).toBe("viewer");
    expect(store.setParticipantConnected(participant.id, true)?.role).toBe("viewer");
    expect(store.kickParticipant(participant.id)?.state).toBe("kicked");
    expect(store.joinRoom(room.id, "blocked-device", "重新进入")).toBeUndefined();
  });
});
