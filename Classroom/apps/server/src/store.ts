import { randomUUID } from "node:crypto";
import { customAlphabet } from "nanoid";
import type {
  ChatMessage,
  LiveRoom,
  Participant,
  PublicRoom,
  Replay,
  RoomSettings,
  RoomSnapshot
} from "@flowrecorder/contracts";

const shareCode = customAlphabet("23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz", 14);

export interface ClassroomState {
  version: 1;
  rooms: LiveRoom[];
  participants: Participant[];
  messages: ChatMessage[];
  replays: Replay[];
}

export class ClassroomStore {
  private readonly rooms = new Map<string, LiveRoom>();
  private readonly participants = new Map<string, Participant>();
  private readonly messages = new Map<string, ChatMessage[]>();
  private readonly replays = new Map<string, Replay[]>();
  private onMutation?: () => void;

  constructor(seedDemo = true) {
    if (seedDemo) this.createRoom("PPT 实战公开课");
  }

  setMutationListener(listener: (() => void) | undefined): void {
    this.onMutation = listener;
  }

  restore(state: ClassroomState): void {
    if (state.version !== 1) throw new Error(`Unsupported classroom state version: ${state.version}`);
    this.rooms.clear();
    this.participants.clear();
    this.messages.clear();
    this.replays.clear();

    for (const room of state.rooms) {
      const restoredRoom: LiveRoom = room.status === "live"
        ? { ...room, status: "scheduled", startedAt: undefined, endedAt: undefined }
        : room;
      this.rooms.set(room.id, structuredClone(restoredRoom));
      this.messages.set(room.id, []);
      this.replays.set(room.id, []);
    }
    for (const participant of state.participants) {
      const restored: Participant = {
        ...participant,
        state: participant.state === "kicked" ? "kicked" : "left",
        role: participant.role === "cohost" ? "viewer" : participant.role,
        handRaisedAt: undefined
      };
      this.participants.set(restored.id, restored);
    }
    for (const message of state.messages) {
      const roomMessages = this.messages.get(message.roomId) ?? [];
      roomMessages.push(structuredClone(message));
      this.messages.set(message.roomId, roomMessages.slice(-100));
    }
    for (const replay of state.replays) {
      const roomReplays = this.replays.get(replay.roomId) ?? [];
      roomReplays.push(structuredClone(replay));
      this.replays.set(replay.roomId, roomReplays);
    }
  }

  exportState(): ClassroomState {
    return structuredClone({
      version: 1,
      rooms: [...this.rooms.values()],
      participants: [...this.participants.values()],
      messages: [...this.messages.values()].flat(),
      replays: [...this.replays.values()].flat()
    });
  }

  createRoom(title: string): LiveRoom {
    const now = new Date().toISOString();
    const room: LiveRoom = {
      id: randomUUID(),
      courseId: randomUUID(),
      shareCode: shareCode(),
      title,
      status: "scheduled",
      heatBase: 86,
      heatMultiplier: 1,
      settings: {
        allowChat: true,
        allowHandRaise: true,
        allowCohost: true,
        localRecording: true,
        resolution: "720p"
      },
      createdAt: now
    };
    this.rooms.set(room.id, room);
    this.messages.set(room.id, []);
    this.replays.set(room.id, []);
    this.changed();
    return structuredClone(room);
  }

  listRooms(): LiveRoom[] {
    return [...this.rooms.values()]
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .map((room) => structuredClone(room));
  }

  getRoom(id: string): LiveRoom | undefined {
    const room = this.rooms.get(id);
    return room ? structuredClone(room) : undefined;
  }

  getRoomByShareCode(code: string): LiveRoom | undefined {
    const room = [...this.rooms.values()].find((candidate) => candidate.shareCode === code);
    return room ? structuredClone(room) : undefined;
  }

  publicRoom(code: string): PublicRoom | undefined {
    const room = this.getRoomByShareCode(code);
    if (!room) return undefined;
    return {
      shareCode: room.shareCode,
      title: room.title,
      status: room.status,
      heat: this.heat(room.id),
      settings: {
        allowChat: room.settings.allowChat,
        allowHandRaise: room.settings.allowHandRaise,
        allowCohost: room.settings.allowCohost
      }
    };
  }

  updateRoom(id: string, patch: Partial<Pick<LiveRoom, "title" | "heatBase" | "heatMultiplier">> & { settings?: Partial<RoomSettings> }): LiveRoom | undefined {
    const room = this.rooms.get(id);
    if (!room) return undefined;
    const updated: LiveRoom = {
      ...room,
      ...patch,
      settings: { ...room.settings, ...patch.settings }
    };
    this.rooms.set(id, updated);
    this.changed();
    return structuredClone(updated);
  }

  setRoomStatus(id: string, status: LiveRoom["status"]): LiveRoom | undefined {
    const room = this.rooms.get(id);
    if (!room) return undefined;
    const now = new Date().toISOString();
    const updated: LiveRoom = {
      ...room,
      status,
      startedAt: status === "live" ? now : room.startedAt,
      endedAt: status === "ended" ? now : undefined
    };
    this.rooms.set(id, updated);
    this.changed();
    return structuredClone(updated);
  }

  regenerateShareCode(id: string): LiveRoom | undefined {
    const room = this.rooms.get(id);
    if (!room) return undefined;
    const updated = { ...room, shareCode: shareCode() };
    this.rooms.set(id, updated);
    this.changed();
    return structuredClone(updated);
  }

  joinRoom(roomId: string, deviceId: string, nickname: string): Participant | undefined {
    const existing = [...this.participants.values()].find(
      (participant) => participant.roomId === roomId && participant.deviceId === deviceId
    );
    if (existing) {
      if (existing.state === "kicked") return undefined;
      const updated: Participant = {
        ...existing,
        nickname,
        state: "connected",
        role: existing.role === "cohost" ? "viewer" : existing.role,
        handRaisedAt: undefined
      };
      this.participants.set(updated.id, updated);
      this.changed();
      return structuredClone(updated);
    }

    const participant: Participant = {
      id: randomUUID(),
      roomId,
      deviceId,
      nickname,
      role: "viewer",
      state: "connected",
      muted: false,
      joinedAt: new Date().toISOString()
    };
    this.participants.set(participant.id, participant);
    this.changed();
    return structuredClone(participant);
  }

  getParticipant(id: string): Participant | undefined {
    const participant = this.participants.get(id);
    return participant ? structuredClone(participant) : undefined;
  }

  setParticipantConnected(id: string, connected: boolean): Participant | undefined {
    const participant = this.participants.get(id);
    if (!participant || participant.state === "kicked") return participant ? structuredClone(participant) : undefined;
    const updated: Participant = {
      ...participant,
      state: connected ? "connected" : "left",
      role: !connected && participant.role === "cohost" ? "viewer" : participant.role,
      handRaisedAt: !connected ? undefined : participant.handRaisedAt
    };
    this.participants.set(id, updated);
    this.changed();
    return structuredClone(updated);
  }

  setHandRaised(id: string, raised: boolean): Participant | undefined {
    const participant = this.participants.get(id);
    const room = participant && this.rooms.get(participant.roomId);
    if (!participant || !room?.settings.allowHandRaise || participant.state === "kicked") return undefined;
    const updated = { ...participant, handRaisedAt: raised ? new Date().toISOString() : undefined };
    this.participants.set(id, updated);
    this.changed();
    return structuredClone(updated);
  }

  approveCohost(id: string): Participant | undefined {
    const participant = this.participants.get(id);
    if (!participant || participant.state !== "connected") return undefined;
    const room = this.rooms.get(participant.roomId);
    if (!room?.settings.allowCohost || this.activeCohost(room.id)) return undefined;
    const updated: Participant = { ...participant, role: "cohost", handRaisedAt: undefined };
    this.participants.set(id, updated);
    this.changed();
    return structuredClone(updated);
  }

  revokeCohost(id: string): Participant | undefined {
    const participant = this.participants.get(id);
    if (!participant) return undefined;
    const updated: Participant = { ...participant, role: "viewer", handRaisedAt: undefined };
    this.participants.set(id, updated);
    this.changed();
    return structuredClone(updated);
  }

  muteParticipant(id: string, muted: boolean): Participant | undefined {
    const participant = this.participants.get(id);
    if (!participant) return undefined;
    const updated = { ...participant, muted };
    this.participants.set(id, updated);
    this.changed();
    return structuredClone(updated);
  }

  kickParticipant(id: string): Participant | undefined {
    const participant = this.participants.get(id);
    if (!participant) return undefined;
    const updated: Participant = { ...participant, state: "kicked", role: "viewer", handRaisedAt: undefined };
    this.participants.set(id, updated);
    this.changed();
    return structuredClone(updated);
  }

  addMessage(roomId: string, participantId: string, body: string): ChatMessage | undefined {
    const participant = this.participants.get(participantId);
    const room = this.rooms.get(roomId);
    if (!participant || participant.roomId !== roomId || participant.state !== "connected" || participant.muted || !room?.settings.allowChat) return undefined;
    const message: ChatMessage = {
      id: randomUUID(),
      roomId,
      participantId,
      nickname: participant.nickname,
      role: participant.role,
      body,
      createdAt: new Date().toISOString()
    };
    const messages = this.messages.get(roomId) ?? [];
    messages.push(message);
    this.messages.set(roomId, messages.slice(-100));
    this.changed();
    return structuredClone(message);
  }

  messagesForRoom(roomId: string): ChatMessage[] {
    return structuredClone(this.messages.get(roomId) ?? []);
  }

  createReplay(roomId: string, title: string): Replay | undefined {
    if (!this.rooms.has(roomId)) return undefined;
    const replay: Replay = {
      id: randomUUID(),
      roomId,
      title,
      status: "pending",
      createdAt: new Date().toISOString()
    };
    const replays = this.replays.get(roomId) ?? [];
    replays.unshift(replay);
    this.replays.set(roomId, replays);
    this.changed();
    return structuredClone(replay);
  }

  replaysForRoom(roomId: string): Replay[] {
    return structuredClone(this.replays.get(roomId) ?? []);
  }

  snapshot(roomId: string): RoomSnapshot | undefined {
    const room = this.rooms.get(roomId);
    if (!room) return undefined;
    const participants = [...this.participants.values()]
      .filter((participant) => participant.roomId === roomId)
      .sort((a, b) => a.joinedAt.localeCompare(b.joinedAt));
    return {
      room: structuredClone(room),
      participants: structuredClone(participants),
      messages: this.messagesForRoom(roomId),
      actualOnline: participants.filter((participant) => participant.state === "connected").length,
      heat: this.heat(roomId),
      activeCohostId: this.activeCohost(roomId)?.id
    };
  }

  private activeCohost(roomId: string): Participant | undefined {
    return [...this.participants.values()].find(
      (participant) => participant.roomId === roomId && participant.role === "cohost" && participant.state === "connected"
    );
  }

  private heat(roomId: string): number {
    const room = this.rooms.get(roomId);
    if (!room) return 0;
    const online = [...this.participants.values()].filter(
      (participant) => participant.roomId === roomId && participant.state === "connected"
    ).length;
    return Math.round(room.heatBase + online * room.heatMultiplier);
  }

  private changed(): void {
    this.onMutation?.();
  }
}
