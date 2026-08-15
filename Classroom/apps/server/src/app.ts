import { createServer, type Server as HttpServer } from "node:http";
import cors from "cors";
import express, { type Express, type Request, type Response } from "express";
import { z } from "zod";
import { config } from "./config.js";
import { requireTeacher, signSession } from "./auth.js";
import { mediaProvider } from "./media.js";
import { ClassroomStore } from "./store.js";
import { broadcastSnapshot, createSocketServer, type ClassroomIo } from "./socket.js";

const roomSettingsSchema = z.object({
  allowChat: z.boolean().optional(),
  allowHandRaise: z.boolean().optional(),
  allowCohost: z.boolean().optional(),
  localRecording: z.boolean().optional(),
  resolution: z.enum(["540p", "720p", "1080p"]).optional()
});

function notFound(res: Response, message = "未找到课堂"): void {
  res.status(404).json({ error: message });
}

function pathParam(req: Request, name: string): string {
  const value = req.params[name];
  return Array.isArray(value) ? value[0] ?? "" : value ?? "";
}

export interface ClassroomServer {
  app: Express;
  httpServer: HttpServer;
  io: ClassroomIo;
  store: ClassroomStore;
}

export function createClassroomServer(store = new ClassroomStore()): ClassroomServer {
  const app = express();
  const httpServer = createServer(app);
  const io = createSocketServer(httpServer, store);

  app.use(cors({ origin: config.isProduction ? config.webOrigin : true, credentials: true }));
  app.use(express.json({ limit: "1mb" }));

  app.get("/api/health", (_req, res) => {
    res.json({
      ok: true,
      version: "0.1.0",
      mediaProvider: mediaProvider.name,
      paymentsEnabled: config.paymentsEnabled,
      persistence: "memory"
    });
  });

  app.post("/api/teacher/session", (req, res) => {
    const parsed = z.object({ accessCode: z.string().min(1), nickname: z.string().trim().min(1).max(30).default("Jack 讲师") }).safeParse(req.body);
    if (!parsed.success || parsed.data.accessCode !== config.teacherAccessCode) {
      res.status(401).json({ error: "讲师口令不正确" });
      return;
    }
    const token = signSession({ kind: "teacher", teacherId: "owner", nickname: parsed.data.nickname });
    res.json({ token, nickname: parsed.data.nickname });
  });

  app.get("/api/rooms", requireTeacher, (_req, res) => {
    res.json({ rooms: store.listRooms() });
  });

  app.post("/api/rooms", requireTeacher, (req, res) => {
    const parsed = z.object({ title: z.string().trim().min(2).max(80) }).safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "课堂名称需要 2–80 个字符" });
      return;
    }
    const room = store.createRoom(parsed.data.title);
    res.status(201).json({ room, watchUrl: `${config.publicWebUrl}/live/${room.shareCode}` });
  });

  app.get("/api/rooms/:id", requireTeacher, (req, res) => {
    const snapshot = store.snapshot(pathParam(req, "id"));
    if (!snapshot) return notFound(res);
    res.json({ ...snapshot, watchUrl: `${config.publicWebUrl}/live/${snapshot.room.shareCode}`, replays: store.replaysForRoom(snapshot.room.id) });
  });

  app.patch("/api/rooms/:id", requireTeacher, (req, res) => {
    const parsed = z.object({
      title: z.string().trim().min(2).max(80).optional(),
      heatBase: z.number().int().min(0).max(100000).optional(),
      heatMultiplier: z.number().min(0).max(100).optional(),
      settings: roomSettingsSchema.optional()
    }).safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "课堂设置无效" });
      return;
    }
    const room = store.updateRoom(pathParam(req, "id"), parsed.data);
    if (!room) return notFound(res);
    io.to(`room:${room.id}`).emit("room:updated", room);
    broadcastSnapshot(io, store, room.id);
    res.json({ room });
  });

  app.post("/api/rooms/:id/start", requireTeacher, (req, res) => {
    const room = store.setRoomStatus(pathParam(req, "id"), "live");
    if (!room) return notFound(res);
    io.to(`room:${room.id}`).emit("room:updated", room);
    broadcastSnapshot(io, store, room.id);
    res.json({ room });
  });

  app.post("/api/rooms/:id/end", requireTeacher, (req, res) => {
    const room = store.setRoomStatus(pathParam(req, "id"), "ended");
    if (!room) return notFound(res);
    io.to(`room:${room.id}`).emit("room:updated", room);
    broadcastSnapshot(io, store, room.id);
    res.json({ room });
  });

  app.post("/api/rooms/:id/regenerate-link", requireTeacher, (req, res) => {
    const room = store.regenerateShareCode(pathParam(req, "id"));
    if (!room) return notFound(res);
    broadcastSnapshot(io, store, room.id);
    res.json({ room, watchUrl: `${config.publicWebUrl}/live/${room.shareCode}` });
  });

  app.post("/api/rooms/:id/replays", requireTeacher, (req, res) => {
    const parsed = z.object({ title: z.string().trim().min(2).max(100) }).safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "回放名称无效" });
      return;
    }
    const replay = store.createReplay(pathParam(req, "id"), parsed.data.title);
    if (!replay) return notFound(res);
    res.status(201).json({ replay, upload: { enabled: false, reason: "等待配置腾讯云 COS/VOD" } });
  });

  app.get("/api/payments/status", (_req, res) => {
    res.json({ enabled: config.paymentsEnabled, providers: ["wechat", "alipay"], mode: "reserved" });
  });

  app.get("/api/live/:shareCode", (req, res) => {
    const room = store.publicRoom(pathParam(req, "shareCode"));
    if (!room) return notFound(res, "课堂链接无效或已更新");
    res.json({ room });
  });

  app.post("/api/live/:shareCode/join", async (req, res) => {
    const parsed = z.object({
      deviceId: z.string().min(8).max(100),
      nickname: z.string().trim().min(1).max(24)
    }).safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "请输入有效昵称" });
      return;
    }
    const room = store.getRoomByShareCode(pathParam(req, "shareCode"));
    if (!room) return notFound(res, "课堂链接无效或已更新");
    const participant = store.joinRoom(room.id, parsed.data.deviceId, parsed.data.nickname);
    const token = signSession({ kind: "participant", roomId: room.id, participantId: participant.id, role: participant.role });
    const media = await mediaProvider.createGrant(participant, false);
    res.json({
      room: store.publicRoom(room.shareCode),
      participant,
      token,
      media,
      messages: store.messagesForRoom(room.id)
    });
  });

  app.use((error: unknown, _req: Request, res: Response, _next: (error?: unknown) => void) => {
    console.error(error);
    res.status(500).json({ error: "服务暂时不可用，请稍后重试" });
  });

  return { app, httpServer, io, store };
}
