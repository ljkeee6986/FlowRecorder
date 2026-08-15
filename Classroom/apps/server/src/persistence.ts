import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Pool, type PoolClient } from "pg";
import type {
  ChatMessage,
  LiveRoom,
  Participant,
  Replay,
  StreamResolution
} from "@flowrecorder/contracts";
import { config } from "./config.js";
import type { ClassroomState } from "./store.js";

export interface ClassroomPersistence {
  readonly name: "memory" | "file" | "postgres";
  load(): Promise<ClassroomState | undefined>;
  scheduleSave(state: ClassroomState): void;
  flush(): Promise<void>;
  close(): Promise<void>;
}

abstract class BufferedPersistence implements ClassroomPersistence {
  abstract readonly name: "file" | "postgres";
  private pending?: ClassroomState;
  private timer?: NodeJS.Timeout;
  private writing: Promise<void> = Promise.resolve();

  abstract load(): Promise<ClassroomState | undefined>;
  protected abstract writeState(state: ClassroomState): Promise<void>;

  scheduleSave(state: ClassroomState): void {
    this.pending = structuredClone(state);
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      void this.flush().catch((error) => console.error(`${this.name} persistence write failed`, error));
    }, 150);
  }

  async flush(): Promise<void> {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    const state = this.pending;
    this.pending = undefined;
    if (!state) return this.writing;
    this.writing = this.writing.then(() => this.writeState(state));
    return this.writing;
  }

  async close(): Promise<void> {
    await this.flush();
  }
}

export class MemoryPersistence implements ClassroomPersistence {
  readonly name = "memory" as const;
  async load(): Promise<undefined> { return undefined; }
  scheduleSave(): void {}
  async flush(): Promise<void> {}
  async close(): Promise<void> {}
}

export class FilePersistence extends BufferedPersistence {
  readonly name = "file" as const;

  constructor(private readonly filePath: string) {
    super();
  }

  async load(): Promise<ClassroomState | undefined> {
    try {
      const payload = JSON.parse(await readFile(this.filePath, "utf8")) as ClassroomState;
      if (payload.version !== 1 || !Array.isArray(payload.rooms) || !Array.isArray(payload.participants)) {
        throw new Error("Unsupported classroom state file");
      }
      return payload;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw new Error(`Cannot load classroom state: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  protected async writeState(state: ClassroomState): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true });
    const temporaryPath = `${this.filePath}.${process.pid}.tmp`;
    await writeFile(temporaryPath, `${JSON.stringify(state, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
    await rename(temporaryPath, this.filePath);
  }
}

interface RoomRow {
  id: string;
  course_id: string;
  share_code: string;
  title: string;
  status: LiveRoom["status"];
  heat_base: number;
  heat_multiplier: string | number;
  allow_chat: boolean;
  allow_hand_raise: boolean;
  allow_cohost: boolean;
  local_recording: boolean;
  resolution: StreamResolution;
  started_at: Date | null;
  ended_at: Date | null;
  created_at: Date;
}

interface ParticipantRow {
  id: string;
  room_id: string;
  device_id: string;
  nickname: string;
  role: Participant["role"];
  state: Participant["state"];
  muted: boolean;
  hand_raised_at: Date | null;
  joined_at: Date;
}

interface MessageRow {
  id: string;
  room_id: string;
  participant_id: string;
  nickname: string;
  role: Participant["role"];
  body: string;
  created_at: Date;
}

interface ReplayRow {
  id: string;
  room_id: string;
  title: string;
  status: Replay["status"];
  playback_url: string | null;
  duration_seconds: number | null;
  created_at: Date;
}

export class PostgresPersistence extends BufferedPersistence {
  readonly name = "postgres" as const;
  private readonly pool: Pool;
  private initialized = false;

  constructor(connectionString: string, pool?: Pool) {
    super();
    this.pool = pool ?? new Pool({ connectionString, max: 10, idleTimeoutMillis: 30_000 });
    this.pool.on("error", (error) => console.error("PostgreSQL pool error", error));
  }

  async load(): Promise<ClassroomState | undefined> {
    await this.ensureSchema();
    const [roomResult, participantResult, messageResult, replayResult] = await Promise.all([
      this.pool.query<RoomRow>("SELECT * FROM live_rooms ORDER BY created_at DESC"),
      this.pool.query<ParticipantRow>("SELECT * FROM participants ORDER BY joined_at"),
      this.pool.query<MessageRow>(`SELECT m.*, p.nickname, p.role FROM chat_messages m JOIN participants p ON p.id = m.participant_id ORDER BY m.created_at`),
      this.pool.query<ReplayRow>("SELECT * FROM replays ORDER BY created_at DESC")
    ]);
    if (roomResult.rowCount === 0) return undefined;

    const rooms: LiveRoom[] = roomResult.rows.map((row) => ({
      id: row.id,
      courseId: row.course_id,
      shareCode: row.share_code,
      title: row.title,
      status: row.status,
      heatBase: row.heat_base,
      heatMultiplier: Number(row.heat_multiplier),
      settings: {
        allowChat: row.allow_chat,
        allowHandRaise: row.allow_hand_raise,
        allowCohost: row.allow_cohost,
        localRecording: row.local_recording,
        resolution: row.resolution
      },
      startedAt: row.started_at?.toISOString(),
      endedAt: row.ended_at?.toISOString(),
      createdAt: row.created_at.toISOString()
    }));
    const participants: Participant[] = participantResult.rows.map((row) => ({
      id: row.id,
      roomId: row.room_id,
      deviceId: row.device_id,
      nickname: row.nickname,
      role: row.role,
      state: row.state,
      muted: row.muted,
      handRaisedAt: row.hand_raised_at?.toISOString(),
      joinedAt: row.joined_at.toISOString()
    }));
    const messages: ChatMessage[] = messageResult.rows.map((row) => ({
      id: row.id,
      roomId: row.room_id,
      participantId: row.participant_id,
      nickname: row.nickname,
      role: row.role,
      body: row.body,
      createdAt: row.created_at.toISOString()
    }));
    const replays: Replay[] = replayResult.rows.map((row) => ({
      id: row.id,
      roomId: row.room_id,
      title: row.title,
      status: row.status,
      playbackUrl: row.playback_url ?? undefined,
      durationSeconds: row.duration_seconds ?? undefined,
      createdAt: row.created_at.toISOString()
    }));
    return { version: 1, rooms, participants, messages, replays };
  }

  protected async writeState(state: ClassroomState): Promise<void> {
    await this.ensureSchema();
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      for (const room of state.rooms) await this.upsertRoom(client, room);
      for (const participant of state.participants) await this.upsertParticipant(client, participant);
      for (const message of state.messages) await this.upsertMessage(client, message);
      for (const replay of state.replays) await this.upsertReplay(client, replay);
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  override async close(): Promise<void> {
    await super.close();
    await this.pool.end();
  }

  private async ensureSchema(): Promise<void> {
    if (this.initialized) return;
    const schemaPath = fileURLToPath(new URL("../../../infra/schema.sql", import.meta.url));
    await this.pool.query(await readFile(schemaPath, "utf8"));
    this.initialized = true;
  }

  private async upsertRoom(client: PoolClient, room: LiveRoom): Promise<void> {
    await client.query(
      `INSERT INTO courses (id, title, created_at, updated_at) VALUES ($1, $2, $3, NOW())
       ON CONFLICT (id) DO UPDATE SET title = EXCLUDED.title, updated_at = NOW()`,
      [room.courseId, room.title, room.createdAt]
    );
    await client.query(
      `INSERT INTO live_rooms (
         id, course_id, share_code, title, status, heat_base, heat_multiplier,
         allow_chat, allow_hand_raise, allow_cohost, local_recording, resolution,
         started_at, ended_at, created_at, updated_at
       ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,NOW())
       ON CONFLICT (id) DO UPDATE SET
         share_code=EXCLUDED.share_code, title=EXCLUDED.title, status=EXCLUDED.status,
         heat_base=EXCLUDED.heat_base, heat_multiplier=EXCLUDED.heat_multiplier,
         allow_chat=EXCLUDED.allow_chat, allow_hand_raise=EXCLUDED.allow_hand_raise,
         allow_cohost=EXCLUDED.allow_cohost, local_recording=EXCLUDED.local_recording,
         resolution=EXCLUDED.resolution, started_at=EXCLUDED.started_at,
         ended_at=EXCLUDED.ended_at, updated_at=NOW()`,
      [room.id, room.courseId, room.shareCode, room.title, room.status, room.heatBase, room.heatMultiplier,
        room.settings.allowChat, room.settings.allowHandRaise, room.settings.allowCohost,
        room.settings.localRecording, room.settings.resolution, room.startedAt ?? null,
        room.endedAt ?? null, room.createdAt]
    );
  }

  private async upsertParticipant(client: PoolClient, participant: Participant): Promise<void> {
    await client.query(
      `INSERT INTO participants (id, room_id, device_id, nickname, role, state, muted, hand_raised_at, joined_at, last_seen_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,NOW())
       ON CONFLICT (id) DO UPDATE SET nickname=EXCLUDED.nickname, role=EXCLUDED.role,
         state=EXCLUDED.state, muted=EXCLUDED.muted, hand_raised_at=EXCLUDED.hand_raised_at,
         last_seen_at=NOW()`,
      [participant.id, participant.roomId, participant.deviceId, participant.nickname,
        participant.role, participant.state, participant.muted, participant.handRaisedAt ?? null,
        participant.joinedAt]
    );
  }

  private async upsertMessage(client: PoolClient, message: ChatMessage): Promise<void> {
    await client.query(
      `INSERT INTO chat_messages (id, room_id, participant_id, body, created_at)
       VALUES ($1,$2,$3,$4,$5) ON CONFLICT (id) DO NOTHING`,
      [message.id, message.roomId, message.participantId, message.body, message.createdAt]
    );
  }

  private async upsertReplay(client: PoolClient, replay: Replay): Promise<void> {
    await client.query(
      `INSERT INTO replays (id, room_id, title, status, playback_url, duration_seconds, created_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7)
       ON CONFLICT (id) DO UPDATE SET title=EXCLUDED.title, status=EXCLUDED.status,
         playback_url=EXCLUDED.playback_url, duration_seconds=EXCLUDED.duration_seconds`,
      [replay.id, replay.roomId, replay.title, replay.status, replay.playbackUrl ?? null,
        replay.durationSeconds ?? null, replay.createdAt]
    );
  }
}

export function createPersistence(): ClassroomPersistence {
  switch (config.persistence.driver) {
    case "memory": return new MemoryPersistence();
    case "postgres": return new PostgresPersistence(config.persistence.databaseUrl);
    default: return new FilePersistence(config.persistence.filePath);
  }
}
