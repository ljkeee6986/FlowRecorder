export type RoomStatus = "scheduled" | "live" | "ended";
export type ParticipantRole = "teacher" | "viewer" | "cohost";
export type ParticipantState = "connected" | "left" | "kicked";
export type StreamResolution = "540p" | "720p" | "1080p";
export type OrderStatus = "pending" | "paid" | "cancelled" | "refunded";
export type PaymentProviderName = "wechat" | "alipay";

export interface RoomSettings {
  allowChat: boolean;
  allowHandRaise: boolean;
  allowCohost: boolean;
  localRecording: boolean;
  resolution: StreamResolution;
}

export interface LiveRoom {
  id: string;
  courseId: string;
  shareCode: string;
  title: string;
  status: RoomStatus;
  heatBase: number;
  heatMultiplier: number;
  settings: RoomSettings;
  startedAt?: string;
  endedAt?: string;
  createdAt: string;
}

export interface PublicRoom {
  shareCode: string;
  title: string;
  status: RoomStatus;
  heat: number;
  settings: Pick<RoomSettings, "allowChat" | "allowHandRaise" | "allowCohost">;
}

export interface Participant {
  id: string;
  roomId: string;
  deviceId: string;
  nickname: string;
  role: ParticipantRole;
  state: ParticipantState;
  muted: boolean;
  handRaisedAt?: string;
  joinedAt: string;
}

export interface ChatMessage {
  id: string;
  roomId: string;
  participantId: string;
  nickname: string;
  role: ParticipantRole;
  body: string;
  createdAt: string;
}

export interface Replay {
  id: string;
  roomId: string;
  title: string;
  status: "pending" | "uploading" | "ready" | "failed";
  playbackUrl?: string;
  durationSeconds?: number;
  createdAt: string;
}

export interface Order {
  id: string;
  courseId: string;
  deviceId: string;
  provider: PaymentProviderName;
  status: OrderStatus;
  amountFen: number;
  providerReference?: string;
  createdAt: string;
}

export interface AccessGrant {
  id: string;
  courseId: string;
  deviceId: string;
  orderId?: string;
  expiresAt?: string;
  createdAt: string;
}

export interface MediaGrant {
  provider: "mock" | "trtc";
  roomId: string;
  userId: string;
  canPublishAudio: boolean;
  canPublishVideo: boolean;
  expiresAt: string;
  sdkAppId?: number;
  userSig?: string;
  privateMapKey?: string;
}

export interface JoinRoomResponse {
  room: PublicRoom;
  participant: Participant;
  token: string;
  media: MediaGrant;
  messages: ChatMessage[];
}

export interface RoomSnapshot {
  room: LiveRoom;
  participants: Participant[];
  messages: ChatMessage[];
  actualOnline: number;
  heat: number;
  activeCohostId?: string;
}

export interface ServerToClientEvents {
  "room:snapshot": (snapshot: RoomSnapshot) => void;
  "room:updated": (room: LiveRoom) => void;
  "participant:updated": (participant: Participant) => void;
  "chat:message": (message: ChatMessage) => void;
  "cohost:approved": (grant: MediaGrant) => void;
  "cohost:revoked": (reason: string) => void;
  "system:error": (message: string) => void;
}

export interface ClientToServerEvents {
  "chat:send": (body: string, acknowledgement?: (ok: boolean) => void) => void;
  "hand:set": (raised: boolean, acknowledgement?: (ok: boolean) => void) => void;
  "teacher:approve": (participantId: string, acknowledgement?: (ok: boolean) => void) => void;
  "teacher:reject": (participantId: string, acknowledgement?: (ok: boolean) => void) => void;
  "teacher:revoke": (participantId: string, acknowledgement?: (ok: boolean) => void) => void;
  "teacher:mute": (participantId: string, muted: boolean, acknowledgement?: (ok: boolean) => void) => void;
  "teacher:kick": (participantId: string, acknowledgement?: (ok: boolean) => void) => void;
}
