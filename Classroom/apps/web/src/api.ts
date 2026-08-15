import type { JoinRoomResponse, LiveRoom, MediaGrant, PublicRoom, Replay, RoomSnapshot } from "@flowrecorder/contracts";

export class ApiError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

async function request<T>(path: string, options: RequestInit = {}, token?: string): Promise<T> {
  const response = await fetch(path, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      ...options.headers,
      ...(token ? { Authorization: `Bearer ${token}` } : {})
    }
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new ApiError(payload.error ?? "请求失败，请稍后重试", response.status);
  return payload as T;
}

export const api = {
  teacherLogin(accessCode: string, nickname: string) {
    return request<{ token: string; nickname: string }>("/api/teacher/session", {
      method: "POST",
      body: JSON.stringify({ accessCode, nickname })
    });
  },
  listRooms(token: string) {
    return request<{ rooms: LiveRoom[] }>("/api/rooms", {}, token);
  },
  createRoom(token: string, title: string) {
    return request<{ room: LiveRoom; watchUrl: string }>("/api/rooms", {
      method: "POST",
      body: JSON.stringify({ title })
    }, token);
  },
  room(token: string, roomId: string) {
    return request<RoomSnapshot & { watchUrl: string; replays: Replay[] }>(`/api/rooms/${roomId}`, {}, token);
  },
  updateRoom(token: string, roomId: string, patch: unknown) {
    return request<{ room: LiveRoom }>(`/api/rooms/${roomId}`, {
      method: "PATCH",
      body: JSON.stringify(patch)
    }, token);
  },
  setRoomStatus(token: string, roomId: string, action: "start" | "end") {
    return request<{ room: LiveRoom }>(`/api/rooms/${roomId}/${action}`, { method: "POST" }, token);
  },
  teacherMediaGrant(token: string, roomId: string) {
    return request<{ media: MediaGrant }>(`/api/rooms/${roomId}/media-grant`, { method: "POST" }, token);
  },
  regenerateLink(token: string, roomId: string) {
    return request<{ room: LiveRoom; watchUrl: string }>(`/api/rooms/${roomId}/regenerate-link`, { method: "POST" }, token);
  },
  createReplay(token: string, roomId: string, title: string) {
    return request<{ replay: Replay; upload: { enabled: boolean; reason: string } }>(`/api/rooms/${roomId}/replays`, {
      method: "POST",
      body: JSON.stringify({ title })
    }, token);
  },
  publicRoom(shareCode: string) {
    return request<{ room: PublicRoom }>(`/api/live/${shareCode}`);
  },
  joinRoom(shareCode: string, deviceId: string, nickname: string) {
    return request<JoinRoomResponse>(`/api/live/${shareCode}/join`, {
      method: "POST",
      body: JSON.stringify({ deviceId, nickname })
    });
  }
};
