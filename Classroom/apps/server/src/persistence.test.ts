import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Pool } from "pg";
import { DataType, newDb } from "pg-mem";
import { afterEach, describe, expect, it } from "vitest";
import { FilePersistence, PostgresPersistence } from "./persistence.js";
import { ClassroomStore } from "./store.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

describe("file persistence", () => {
  it("restores rooms, messages and replays while clearing live presence", async () => {
    const directory = await mkdtemp(join(tmpdir(), "flowrecorder-classroom-"));
    temporaryDirectories.push(directory);
    const persistence = new FilePersistence(join(directory, "state.json"));
    const store = new ClassroomStore(false);
    store.setMutationListener(() => persistence.scheduleSave(store.exportState()));

    const room = store.createRoom("可恢复课堂");
    const participant = store.joinRoom(room.id, "persistent-device", "小明")!;
    store.setRoomStatus(room.id, "live");
    expect(store.addMessage(room.id, participant.id, "重启后还在")).toBeDefined();
    expect(store.createReplay(room.id, "第一课回放")).toBeDefined();
    await persistence.flush();

    const state = await new FilePersistence(join(directory, "state.json")).load();
    expect(state).toBeDefined();
    const restored = new ClassroomStore(false);
    restored.restore(state!);

    expect(restored.listRooms()[0].title).toBe("可恢复课堂");
    expect(restored.listRooms()[0].status).toBe("scheduled");
    expect(restored.messagesForRoom(room.id)[0].body).toBe("重启后还在");
    expect(restored.replaysForRoom(room.id)[0].title).toBe("第一课回放");
    expect(restored.getParticipant(participant.id)?.state).toBe("left");
  });
});

describe("PostgreSQL persistence", () => {
  it("applies the production schema and round-trips classroom state", async () => {
    const database = newDb();
    database.public.registerFunction({
      name: "char_length",
      args: [DataType.text],
      returns: DataType.integer,
      implementation: (value: string) => value.length
    });
    const adapter = database.adapters.createPg();
    const pool = new adapter.Pool() as unknown as Pool;
    const persistence = new PostgresPersistence("", pool);
    const store = new ClassroomStore(false);
    store.setMutationListener(() => persistence.scheduleSave(store.exportState()));

    const room = store.createRoom("数据库课堂");
    const participant = store.joinRoom(room.id, "postgres-device", "小红")!;
    store.setHandRaised(participant.id, true);
    store.addMessage(room.id, participant.id, "数据库消息");
    store.createReplay(room.id, "数据库回放");
    await persistence.flush();

    const restoredState = await persistence.load();
    expect(restoredState?.rooms[0].title).toBe("数据库课堂");
    expect(restoredState?.participants[0].nickname).toBe("小红");
    expect(restoredState?.messages[0].body).toBe("数据库消息");
    expect(restoredState?.replays[0].title).toBe("数据库回放");
    await persistence.close();
  });
});
