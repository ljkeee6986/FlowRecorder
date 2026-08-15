import type {
  ChatMessage,
  ClientToServerEvents,
  JoinRoomResponse,
  MediaGrant,
  PublicRoom,
  RoomSnapshot,
  ServerToClientEvents
} from "@flowrecorder/contracts";
import {
  ArrowRight,
  CircleAlert,
  Hand,
  LoaderCircle,
  MessageCircle,
  Mic,
  MicOff,
  Radio,
  Send,
  ShieldCheck,
  UserRound,
  Video,
  VideoOff,
  Wifi,
  WifiOff,
  X
} from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useParams } from "react-router-dom";
import { io, type Socket } from "socket.io-client";
import { api } from "./api";
import { Stage } from "./Stage";
import { classroomDeviceId, formatClock, statusLabel } from "./utils";

type ClassroomSocket = Socket<ServerToClientEvents, ClientToServerEvents>;

export function ViewerPage() {
  const { shareCode = "" } = useParams();
  const [room, setRoom] = useState<PublicRoom | null>(null);
  const [session, setSession] = useState<JoinRoomResponse | null>(null);
  const [snapshot, setSnapshot] = useState<RoomSnapshot | null>(null);
  const [nickname, setNickname] = useState(() => localStorage.getItem("flowrecorder.classroom.nickname") ?? "");
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [draft, setDraft] = useState("");
  const [handRaised, setHandRaised] = useState(false);
  const [cohostGrant, setCohostGrant] = useState<MediaGrant | null>(null);
  const [mediaStream, setMediaStream] = useState<MediaStream | null>(null);
  const [connected, setConnected] = useState(navigator.onLine);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [joining, setJoining] = useState(false);
  const [socket, setSocket] = useState<ClassroomSocket | null>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const messageEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    api.publicRoom(shareCode)
      .then((result) => setRoom(result.room))
      .catch((requestError) => setError(requestError instanceof Error ? requestError.message : "课堂链接无效"))
      .finally(() => setLoading(false));
  }, [shareCode]);

  useEffect(() => {
    if (!session) return;
    const nextSocket: ClassroomSocket = io({ auth: { token: session.token } });
    nextSocket.on("connect", () => setConnected(true));
    nextSocket.on("disconnect", () => setConnected(false));
    nextSocket.on("room:snapshot", (nextSnapshot) => {
      setSnapshot(nextSnapshot);
      setMessages(nextSnapshot.messages);
      setRoom({
        shareCode: nextSnapshot.room.shareCode,
        title: nextSnapshot.room.title,
        status: nextSnapshot.room.status,
        heat: nextSnapshot.heat,
        settings: {
          allowChat: nextSnapshot.room.settings.allowChat,
          allowHandRaise: nextSnapshot.room.settings.allowHandRaise,
          allowCohost: nextSnapshot.room.settings.allowCohost
        }
      });
      const me = nextSnapshot.participants.find((participant) => participant.id === session.participant.id);
      setHandRaised(Boolean(me?.handRaisedAt));
    });
    nextSocket.on("chat:message", (message) => setMessages((current) => current.some((item) => item.id === message.id) ? current : [...current, message]));
    nextSocket.on("cohost:approved", setCohostGrant);
    nextSocket.on("cohost:revoked", (reason) => {
      stopLocalMedia();
      setCohostGrant(null);
      setError(reason);
    });
    nextSocket.on("system:error", setError);
    nextSocket.on("connect_error", () => setConnected(false));
    setSocket(nextSocket);
    return () => {
      nextSocket.disconnect();
      setSocket(null);
    };
  }, [session]);

  useEffect(() => {
    messageEndRef.current?.scrollIntoView({ block: "nearest" });
  }, [messages]);

  useEffect(() => {
    if (videoRef.current && mediaStream) videoRef.current.srcObject = mediaStream;
  }, [mediaStream]);

  useEffect(() => {
    const online = () => setConnected(true);
    const offline = () => setConnected(false);
    window.addEventListener("online", online);
    window.addEventListener("offline", offline);
    return () => {
      window.removeEventListener("online", online);
      window.removeEventListener("offline", offline);
      mediaStream?.getTracks().forEach((track) => track.stop());
    };
  }, [mediaStream]);

  async function join(event: React.FormEvent) {
    event.preventDefault();
    if (!nickname.trim()) return;
    setJoining(true);
    setError("");
    try {
      const result = await api.joinRoom(shareCode, classroomDeviceId(), nickname.trim());
      localStorage.setItem("flowrecorder.classroom.nickname", nickname.trim());
      setSession(result);
      setMessages(result.messages);
      setRoom(result.room);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "进入课堂失败");
    } finally {
      setJoining(false);
    }
  }

  function toggleHand() {
    socket?.emit("hand:set", !handRaised, (ok) => {
      if (ok) setHandRaised((value) => !value);
      else setError("举手没有成功，请稍后重试");
    });
  }

  function sendMessage(event: React.FormEvent) {
    event.preventDefault();
    const body = draft.trim();
    if (!body) return;
    socket?.emit("chat:send", body, (ok) => {
      if (ok) setDraft("");
      else setError("消息发送失败");
    });
  }

  async function startLocalMedia() {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: { facingMode: "user" } });
      setMediaStream(stream);
      if (videoRef.current) videoRef.current.srcObject = stream;
    } catch {
      setError("摄像头或麦克风未授权，请在微信或浏览器设置中允许");
    }
  }

  function stopLocalMedia() {
    mediaStream?.getTracks().forEach((track) => track.stop());
    setMediaStream(null);
    if (videoRef.current) videoRef.current.srcObject = null;
  }

  if (loading) return <div className="viewer-loading"><LoaderCircle className="spin" size={30} /><span>正在连接课堂</span></div>;
  if (!room) return <div className="viewer-loading error-page"><CircleAlert size={32} /><strong>{error || "课堂链接无效"}</strong><span>请联系讲师获取新链接</span></div>;

  if (!session) {
    return (
      <main className="viewer-entry">
        <div className="entry-topline"><div className="brand-lockup light"><img src="/icon_128x128.png" alt="" /><div><strong>Jack 在线课堂</strong><span>PRIVATE CLASSROOM</span></div></div><span className={`entry-status ${room.status}`}><Radio size={13} />{statusLabel(room.status)}</span></div>
        <section className="entry-stage"><Stage room={room} /></section>
        <section className="entry-sheet">
          <span className="eyebrow">CLASSROOM ACCESS</span>
          <h1>{room.title}</h1>
          <div className="entry-meta"><span><UserRound size={16} />昵称进入</span><span><ShieldCheck size={16} />课堂链接已验证</span><span><Wifi size={16} />实时互动</span></div>
          <form onSubmit={join}>
            <label>你的昵称<input autoFocus value={nickname} onChange={(event) => setNickname(event.target.value)} maxLength={24} placeholder="请输入昵称" /></label>
            {error && <div className="inline-error">{error}</div>}
            <button className="entry-button" disabled={joining}>{joining ? <LoaderCircle className="spin" size={19} /> : <ArrowRight size={19} />}{joining ? "正在进入" : "进入课堂"}</button>
          </form>
        </section>
      </main>
    );
  }

  return (
    <main className="viewer-room">
      <header className="viewer-header">
        <div className="brand-lockup light compact"><img src="/icon_128x128.png" alt="" /><div><strong>{room.title}</strong><span>{statusLabel(room.status)}</span></div></div>
        <div className={`network-state ${connected ? "online" : "offline"}`}>{connected ? <Wifi size={14} /> : <WifiOff size={14} />}{connected ? "连接正常" : "正在重连"}</div>
        <div className="heat-badge"><Radio size={14} />热度 {snapshot?.heat ?? room.heat}</div>
      </header>

      <div className="viewer-layout">
        <section className="viewer-video-column">
          <Stage room={room} localVideoRef={mediaStream ? videoRef : undefined} cohostName={session.participant.nickname} />
          {cohostGrant && !mediaStream && (
            <div className="cohost-approved"><div><Video size={19} /><span><strong>讲师已同意连麦</strong><small>开启后你的画面和声音将进入课堂</small></span></div><button onClick={() => void startLocalMedia()}>开启摄像头和麦克风</button></div>
          )}
          {mediaStream && <div className="cohost-active"><span><Mic size={16} />连麦进行中</span><span><Video size={16} />摄像头已开启</span></div>}
          <div className="viewer-actions">
            <button className={handRaised ? "active" : ""} onClick={toggleHand} disabled={!room.settings.allowHandRaise}><Hand size={20} />{handRaised ? "取消举手" : "举手连麦"}</button>
            <button onClick={() => document.querySelector(".viewer-chat")?.scrollIntoView({ behavior: "smooth" })}><MessageCircle size={20} />课堂讨论</button>
            <button disabled><MicOff size={20} />默认静音</button>
            <button disabled><VideoOff size={20} />默认关闭</button>
          </div>
        </section>

        <aside className="viewer-chat">
          <div className="viewer-chat-title"><div><MessageCircle size={18} /><strong>课堂讨论</strong></div><span>{snapshot?.actualOnline ?? 1} 人在线</span></div>
          <div className="viewer-messages">
            <div className="system-message">请围绕课程内容交流</div>
            {messages.map((message) => (
              <div className={`viewer-message ${message.participantId === session.participant.id ? "mine" : ""}`} key={message.id}>
                <div><b>{message.nickname}</b><time>{formatClock(message.createdAt)}</time></div><p>{message.body}</p>
              </div>
            ))}
            <div ref={messageEndRef} />
          </div>
          <form className="viewer-composer" onSubmit={sendMessage}>
            <input value={draft} onChange={(event) => setDraft(event.target.value)} maxLength={500} placeholder={room.settings.allowChat ? "说点什么..." : "讲师已关闭聊天"} disabled={!room.settings.allowChat} />
            <button title="发送" aria-label="发送" disabled={!draft.trim()}><Send size={18} /></button>
          </form>
        </aside>
      </div>

      {error && <button className="viewer-alert" onClick={() => setError("")}><CircleAlert size={17} /><span>{error}</span><X size={16} /></button>}
    </main>
  );
}
