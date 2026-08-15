import type { Server as HttpServer } from "node:http";
import type {
  ClientToServerEvents,
  ServerToClientEvents
} from "@flowrecorder/contracts";
import { Server, type Socket } from "socket.io";
import { config } from "./config.js";
import { verifySession, type SessionClaims } from "./auth.js";
import { mediaProvider } from "./media.js";
import type { ClassroomStore } from "./store.js";

interface SocketData {
  session: SessionClaims;
  roomId: string;
}

type ClassroomSocket = Socket<ClientToServerEvents, ServerToClientEvents, never, SocketData>;
export type ClassroomIo = Server<ClientToServerEvents, ServerToClientEvents, never, SocketData>;

function roomChannel(roomId: string): string {
  return `room:${roomId}`;
}

function participantChannel(participantId: string): string {
  return `participant:${participantId}`;
}

export function broadcastSnapshot(io: ClassroomIo, store: ClassroomStore, roomId: string): void {
  const snapshot = store.snapshot(roomId);
  if (snapshot) io.to(roomChannel(roomId)).emit("room:snapshot", snapshot);
}

export function createSocketServer(httpServer: HttpServer, store: ClassroomStore): ClassroomIo {
  const io: ClassroomIo = new Server(httpServer, {
    cors: { origin: config.isProduction ? config.webOrigin : true, credentials: true },
    transports: ["websocket", "polling"]
  });

  io.use((socket, next) => {
    try {
      const token = String(socket.handshake.auth.token ?? "");
      const session = verifySession(token);
      const roomId = session.kind === "teacher"
        ? String(socket.handshake.auth.roomId ?? "")
        : session.roomId;
      if (!roomId || !store.getRoom(roomId)) throw new Error("课堂不存在");
      socket.data.session = session;
      socket.data.roomId = roomId;
      next();
    } catch {
      next(new Error("课堂连接凭证无效"));
    }
  });

  io.on("connection", (socket: ClassroomSocket) => {
    const { session, roomId } = socket.data;
    socket.join(roomChannel(roomId));

    if (session.kind === "participant") {
      const participant = store.getParticipant(session.participantId);
      if (!participant || participant.state === "kicked") {
        socket.emit("system:error", "你已无法进入这个课堂");
        socket.disconnect(true);
        return;
      }
      store.setParticipantConnected(participant.id, true);
      socket.join(participantChannel(participant.id));
    }

    const snapshot = store.snapshot(roomId);
    if (snapshot) socket.emit("room:snapshot", snapshot);
    broadcastSnapshot(io, store, roomId);

    socket.on("chat:send", (rawBody, acknowledgement) => {
      if (session.kind !== "participant") {
        acknowledgement?.(false);
        return;
      }
      const body = rawBody.trim().slice(0, 500);
      if (!body) {
        acknowledgement?.(false);
        return;
      }
      const message = store.addMessage(roomId, session.participantId, body);
      if (!message) {
        socket.emit("system:error", "当前无法发送消息，请检查是否被禁言");
        acknowledgement?.(false);
        return;
      }
      io.to(roomChannel(roomId)).emit("chat:message", message);
      acknowledgement?.(true);
    });

    socket.on("hand:set", (raised, acknowledgement) => {
      if (session.kind !== "participant") {
        acknowledgement?.(false);
        return;
      }
      const participant = store.setHandRaised(session.participantId, raised);
      if (!participant) {
        socket.emit("system:error", "当前课堂未开启举手");
        acknowledgement?.(false);
        return;
      }
      io.to(roomChannel(roomId)).emit("participant:updated", participant);
      broadcastSnapshot(io, store, roomId);
      acknowledgement?.(true);
    });

    socket.on("teacher:approve", async (participantId, acknowledgement) => {
      if (session.kind !== "teacher") {
        acknowledgement?.(false);
        return;
      }
      const participant = store.approveCohost(participantId);
      if (!participant) {
        socket.emit("system:error", "当前已有连麦学员，或该学员已经离开");
        acknowledgement?.(false);
        return;
      }
      try {
        const grant = await mediaProvider.createGrant(participant, true);
        io.to(participantChannel(participant.id)).emit("cohost:approved", grant);
        io.to(roomChannel(roomId)).emit("participant:updated", participant);
        broadcastSnapshot(io, store, roomId);
        acknowledgement?.(true);
      } catch (error) {
        store.revokeCohost(participant.id);
        socket.emit("system:error", error instanceof Error ? error.message : "连麦授权失败");
        acknowledgement?.(false);
      }
    });

    socket.on("teacher:reject", (participantId, acknowledgement) => {
      if (session.kind !== "teacher") {
        acknowledgement?.(false);
        return;
      }
      const participant = store.setHandRaised(participantId, false);
      if (!participant) {
        acknowledgement?.(false);
        return;
      }
      io.to(roomChannel(roomId)).emit("participant:updated", participant);
      io.to(participantChannel(participant.id)).emit("cohost:revoked", "讲师暂未同意本次连麦");
      broadcastSnapshot(io, store, roomId);
      acknowledgement?.(true);
    });

    socket.on("teacher:revoke", (participantId, acknowledgement) => {
      if (session.kind !== "teacher") {
        acknowledgement?.(false);
        return;
      }
      const participant = store.revokeCohost(participantId);
      if (!participant) {
        acknowledgement?.(false);
        return;
      }
      io.to(participantChannel(participant.id)).emit("cohost:revoked", "讲师已结束连麦");
      io.to(roomChannel(roomId)).emit("participant:updated", participant);
      broadcastSnapshot(io, store, roomId);
      acknowledgement?.(true);
    });

    socket.on("teacher:mute", (participantId, muted, acknowledgement) => {
      if (session.kind !== "teacher") {
        acknowledgement?.(false);
        return;
      }
      const participant = store.muteParticipant(participantId, muted);
      if (!participant) {
        acknowledgement?.(false);
        return;
      }
      io.to(roomChannel(roomId)).emit("participant:updated", participant);
      broadcastSnapshot(io, store, roomId);
      acknowledgement?.(true);
    });

    socket.on("teacher:kick", (participantId, acknowledgement) => {
      if (session.kind !== "teacher") {
        acknowledgement?.(false);
        return;
      }
      const participant = store.kickParticipant(participantId);
      if (!participant) {
        acknowledgement?.(false);
        return;
      }
      io.to(participantChannel(participant.id)).emit("cohost:revoked", "讲师已将你移出课堂");
      io.to(participantChannel(participant.id)).emit("system:error", "你已被讲师移出课堂");
      io.in(participantChannel(participant.id)).disconnectSockets(true);
      broadcastSnapshot(io, store, roomId);
      acknowledgement?.(true);
    });

    socket.on("disconnect", () => {
      if (session.kind === "participant") {
        store.setParticipantConnected(session.participantId, false);
        broadcastSnapshot(io, store, roomId);
      }
    });
  });

  return io;
}
