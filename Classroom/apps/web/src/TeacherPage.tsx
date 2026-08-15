import type { LiveRoom, Participant, Replay, RoomSnapshot } from "@flowrecorder/contracts";
import {
  BookOpenCheck,
  Check,
  ChevronDown,
  CircleStop,
  Clipboard,
  Copy,
  EllipsisVertical,
  ExternalLink,
  FileVideo,
  Hand,
  LayoutDashboard,
  Link2,
  LockKeyhole,
  LogOut,
  MessageSquareText,
  MicOff,
  MonitorUp,
  Plus,
  Radio,
  RefreshCw,
  Settings2,
  ShieldCheck,
  SlidersHorizontal,
  UserRoundX,
  UsersRound,
  Video,
  Wifi
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { io, type Socket } from "socket.io-client";
import type { ClientToServerEvents, ServerToClientEvents } from "@flowrecorder/contracts";
import { api, ApiError } from "./api";
import { Stage } from "./Stage";
import { TeacherTrtcClient } from "./trtcClient";
import { copyText, formatClock, statusLabel } from "./utils";

type ClassroomSocket = Socket<ServerToClientEvents, ClientToServerEvents>;
type Section = "record" | "classroom" | "replays" | "settings";

const tokenKey = "flowrecorder.classroom.teacherToken";

function Login({ onLogin }: { onLogin: (token: string) => void }) {
  const [accessCode, setAccessCode] = useState(import.meta.env.DEV ? "jack-demo" : "");
  const [nickname, setNickname] = useState("Jack 讲师");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      const result = await api.teacherLogin(accessCode, nickname);
      sessionStorage.setItem(tokenKey, result.token);
      onLogin(result.token);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "登录失败");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="login-shell">
      <section className="login-panel">
        <div className="brand-lockup large">
          <img src="/icon_128x128.png" alt="" />
          <div><strong>Jack 在线课堂</strong><span>讲师控制台</span></div>
        </div>
        <form onSubmit={submit} className="login-form">
          <label>讲师名称<input value={nickname} onChange={(event) => setNickname(event.target.value)} maxLength={30} /></label>
          <label>讲师口令<input type="password" value={accessCode} onChange={(event) => setAccessCode(event.target.value)} /></label>
          {error && <div className="inline-error">{error}</div>}
          <button className="primary-button wide" disabled={busy}>{busy ? "正在进入..." : "进入控制台"}</button>
        </form>
        <div className="secure-note"><ShieldCheck size={16} />{import.meta.env.DEV ? "本地测试环境 · 正式部署后更换独立口令" : "安全讲师登录"}</div>
      </section>
    </main>
  );
}

export function TeacherPage() {
  const [token, setToken] = useState(() => sessionStorage.getItem(tokenKey) ?? "");
  const [section, setSection] = useState<Section>("classroom");
  const [rooms, setRooms] = useState<LiveRoom[]>([]);
  const [selectedRoomId, setSelectedRoomId] = useState("");
  const [snapshot, setSnapshot] = useState<RoomSnapshot | null>(null);
  const [watchUrl, setWatchUrl] = useState("");
  const [replays, setReplays] = useState<Replay[]>([]);
  const [socket, setSocket] = useState<ClassroomSocket | null>(null);
  const [newRoomTitle, setNewRoomTitle] = useState("");
  const [showCreate, setShowCreate] = useState(false);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [teacherMediaActive, setTeacherMediaActive] = useState(false);
  const teacherScreenViewRef = useRef<HTMLDivElement>(null);
  const teacherCameraViewRef = useRef<HTMLDivElement>(null);
  const teacherTrtcRef = useRef<TeacherTrtcClient | null>(null);

  const selectedRoom = snapshot?.room ?? rooms.find((room) => room.id === selectedRoomId);

  const loadRooms = useCallback(async () => {
    if (!token) return;
    try {
      const result = await api.listRooms(token);
      setRooms(result.rooms);
      setSelectedRoomId((current) => result.rooms.some((room) => room.id === current) ? current : result.rooms[0]?.id || "");
    } catch (requestError) {
      if (requestError instanceof ApiError && requestError.status === 401) {
        sessionStorage.removeItem(tokenKey);
        setToken("");
      } else setError(requestError instanceof Error ? requestError.message : "无法读取课堂");
    }
  }, [token]);

  const loadRoom = useCallback(async () => {
    if (!token || !selectedRoomId) return;
    try {
      const result = await api.room(token, selectedRoomId);
      setSnapshot(result);
      setWatchUrl(`${window.location.origin}/live/${result.room.shareCode}`);
      setReplays(result.replays);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "无法读取课堂");
    }
  }, [selectedRoomId, token]);

  useEffect(() => { void loadRooms(); }, [loadRooms]);
  useEffect(() => { void loadRoom(); }, [loadRoom]);

  useEffect(() => {
    if (!token || !selectedRoomId) return;
    const nextSocket: ClassroomSocket = io({ auth: { token, roomId: selectedRoomId } });
    nextSocket.on("room:snapshot", setSnapshot);
    nextSocket.on("system:error", setError);
    nextSocket.on("connect_error", () => setError("实时课堂连接失败，正在重试"));
    setSocket(nextSocket);
    return () => {
      nextSocket.disconnect();
      setSocket(null);
    };
  }, [selectedRoomId, token]);

  useEffect(() => () => {
    void teacherTrtcRef.current?.stop();
    teacherTrtcRef.current = null;
  }, []);

  const connectedParticipants = useMemo(
    () => snapshot?.participants.filter((participant) => participant.state === "connected") ?? [],
    [snapshot]
  );
  const raisedHands = connectedParticipants.filter((participant) => participant.handRaisedAt);

  async function createRoom(event: React.FormEvent) {
    event.preventDefault();
    if (!newRoomTitle.trim()) return;
    setBusy(true);
    try {
      const result = await api.createRoom(token, newRoomTitle.trim());
      setRooms((current) => [result.room, ...current]);
      setSelectedRoomId(result.room.id);
      setWatchUrl(`${window.location.origin}/live/${result.room.shareCode}`);
      setNewRoomTitle("");
      setShowCreate(false);
      flash("课堂已创建");
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "创建失败");
    } finally {
      setBusy(false);
    }
  }

  async function setStatus(action: "start" | "end") {
    if (!selectedRoom) return;
    setBusy(true);
    try {
      if (action === "start") {
        const { media } = await api.teacherMediaGrant(token, selectedRoom.id);
        if (media.provider === "trtc") {
          const client = new TeacherTrtcClient(
            { screen: () => teacherScreenViewRef.current, camera: () => teacherCameraViewRef.current },
            setError
          );
          teacherTrtcRef.current = client;
          await client.start(media, selectedRoom.settings.resolution);
          setTeacherMediaActive(true);
        }
      } else {
        await teacherTrtcRef.current?.stop();
        teacherTrtcRef.current = null;
        setTeacherMediaActive(false);
      }
      const result = await api.setRoomStatus(token, selectedRoom.id, action);
      setSnapshot((current) => current ? { ...current, room: result.room } : current);
      setRooms((current) => current.map((room) => room.id === result.room.id ? result.room : room));
      flash(action === "start"
        ? selectedRoom.settings.localRecording ? "课堂已开播，请确认录屏大师Jack正在录制" : "课堂已开播"
        : "课堂已结束，本地录像可继续保存");
    } catch (requestError) {
      if (action === "start") {
        await teacherTrtcRef.current?.stop();
        teacherTrtcRef.current = null;
        setTeacherMediaActive(false);
      }
      setError(requestError instanceof Error ? requestError.message : "操作失败");
    } finally {
      setBusy(false);
    }
  }

  async function updateRoom(patch: unknown, success?: string) {
    if (!selectedRoom) return;
    try {
      const result = await api.updateRoom(token, selectedRoom.id, patch);
      setSnapshot((current) => current ? { ...current, room: result.room } : current);
      if (success) flash(success);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "设置保存失败");
    }
  }

  async function regenerateLink() {
    if (!selectedRoom) return;
    if (!window.confirm("旧链接会立即失效，确认重新生成吗？")) return;
    try {
      const result = await api.regenerateLink(token, selectedRoom.id);
      setWatchUrl(`${window.location.origin}/live/${result.room.shareCode}`);
      setSnapshot((current) => current ? { ...current, room: result.room } : current);
      flash("已生成新链接，旧链接失效");
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "生成失败");
    }
  }

  async function createReplay() {
    if (!selectedRoom) return;
    try {
      const result = await api.createReplay(token, selectedRoom.id, `${selectedRoom.title} 回放`);
      setReplays((current) => [result.replay, ...current]);
      flash("已建立回放任务，配置云存储后即可上传");
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "创建失败");
    }
  }

  function flash(message: string) {
    setNotice(message);
    window.setTimeout(() => setNotice(""), 2600);
  }

  function logout() {
    sessionStorage.removeItem(tokenKey);
    setToken("");
  }

  function teacherAction(event: keyof Pick<ClientToServerEvents, "teacher:approve" | "teacher:reject" | "teacher:revoke" | "teacher:kick">, participant: Participant) {
    socket?.emit(event, participant.id, (ok) => {
      if (!ok) setError("操作没有完成，请刷新后重试");
    });
  }

  if (!token) return <Login onLogin={setToken} />;

  return (
    <div className="teacher-shell">
      <aside className="teacher-sidebar">
        <div className="brand-lockup">
          <img src="/icon_128x128.png" alt="" />
          <div><strong>Jack 课堂</strong><span>TEACHER DESK</span></div>
        </div>
        <nav>
          <button className={section === "record" ? "active" : ""} onClick={() => setSection("record")}><Video size={18} />本地录制</button>
          <button className={section === "classroom" ? "active" : ""} onClick={() => setSection("classroom")}><Radio size={18} />在线课堂</button>
          <button className={section === "replays" ? "active" : ""} onClick={() => setSection("replays")}><FileVideo size={18} />课程与回放</button>
          <button className={section === "settings" ? "active" : ""} onClick={() => setSection("settings")}><Settings2 size={18} />设置与诊断</button>
        </nav>
        <div className="sidebar-health"><Wifi size={16} /><div><strong>服务连接正常</strong><span>本地测试环境</span></div></div>
        <button className="sidebar-logout" onClick={logout}><LogOut size={16} />退出控制台</button>
      </aside>

      <main className="teacher-main">
        <header className="teacher-header">
          <div>
            <span className="eyebrow">{section === "classroom" ? "LIVE CLASSROOM" : section.toUpperCase()}</span>
            <h1>{section === "classroom" ? "在线课堂" : section === "record" ? "本地录制" : section === "replays" ? "课程与回放" : "设置与诊断"}</h1>
          </div>
          <div className="room-switcher">
            <select value={selectedRoomId} onChange={(event) => setSelectedRoomId(event.target.value)} aria-label="选择课堂">
              {rooms.map((room) => <option key={room.id} value={room.id}>{room.title}</option>)}
            </select>
            <ChevronDown size={15} />
          </div>
          <button className="secondary-button" onClick={() => setShowCreate(true)}><Plus size={17} />新建课堂</button>
        </header>

        {notice && <div className="toast success"><Check size={17} />{notice}</div>}
        {error && <button className="toast error" onClick={() => setError("")}>{error}<span>关闭</span></button>}

        {showCreate && (
          <div className="modal-backdrop" onMouseDown={() => setShowCreate(false)}>
            <form className="modal" onSubmit={createRoom} onMouseDown={(event) => event.stopPropagation()}>
              <div className="modal-icon"><BookOpenCheck size={22} /></div>
              <h2>新建课堂</h2>
              <label>课堂名称<input autoFocus value={newRoomTitle} onChange={(event) => setNewRoomTitle(event.target.value)} placeholder="例如：剪辑基础第 1 课" /></label>
              <div className="modal-actions"><button type="button" className="text-button" onClick={() => setShowCreate(false)}>取消</button><button className="primary-button" disabled={busy}>创建课堂</button></div>
            </form>
          </div>
        )}

        {section === "record" && <RecordSection />}
        {section === "replays" && <ReplaySection replays={replays} onCreate={createReplay} />}
        {section === "settings" && <SettingsSection />}
        {section === "classroom" && selectedRoom && snapshot && (
          <div className="studio-grid">
            <section className="studio-workspace">
              <div className="section-heading">
                <div><span className={`status-dot ${selectedRoom.status}`} /> <strong>{statusLabel(selectedRoom.status)}</strong><span>{selectedRoom.settings.resolution.toUpperCase()} · 30 FPS</span></div>
                <button className="icon-button" title="刷新" aria-label="刷新" onClick={() => void loadRoom()}><RefreshCw size={16} /></button>
              </div>
              <Stage
                room={selectedRoom}
                teacher
                remoteScreenViewRef={teacherScreenViewRef}
                remoteCameraViewRef={teacherCameraViewRef}
                remoteScreenActive={teacherMediaActive}
                remoteCameraActive={teacherMediaActive}
              />
              <div className="broadcast-controls">
                <div className="source-status"><MonitorUp size={18} /><div><strong>主屏幕</strong><span>屏幕与系统声音</span></div></div>
                <div className="source-status"><Video size={18} /><div><strong>摄像头</strong><span>独立小窗</span></div></div>
                <div className="control-spacer" />
                {selectedRoom.status === "live" ? (
                  <button className="stop-button" disabled={busy} onClick={() => void setStatus("end")}><CircleStop size={18} />结束课堂</button>
                ) : (
                  <button className="primary-button" disabled={busy} onClick={() => void setStatus("start")}><Radio size={18} />开始上课</button>
                )}
              </div>

              <section className="settings-band">
                <div className="band-title"><SlidersHorizontal size={17} /><strong>开播设置</strong></div>
                <div className="setting-row">
                  <label>清晰度
                    <select value={selectedRoom.settings.resolution} onChange={(event) => void updateRoom({ settings: { resolution: event.target.value } })}>
                      <option value="540p">流畅 540P</option><option value="720p">标准 720P</option><option value="1080p">高清 1080P</option>
                    </select>
                  </label>
                  <Toggle label="聊天" checked={selectedRoom.settings.allowChat} onChange={(checked) => void updateRoom({ settings: { allowChat: checked } })} />
                  <Toggle label="举手" checked={selectedRoom.settings.allowHandRaise} onChange={(checked) => void updateRoom({ settings: { allowHandRaise: checked } })} />
                  <Toggle label="允许连麦" checked={selectedRoom.settings.allowCohost} onChange={(checked) => void updateRoom({ settings: { allowCohost: checked } })} />
                  <Toggle label="同步本地录像" checked={selectedRoom.settings.localRecording} onChange={(checked) => void updateRoom({ settings: { localRecording: checked } })} />
                </div>
              </section>
            </section>

            <aside className="studio-rail">
              <section className="rail-section share-section">
                <div className="rail-title"><Link2 size={17} /><strong>课堂链接</strong><button className="icon-button" title="重新生成" aria-label="重新生成" onClick={() => void regenerateLink()}><RefreshCw size={15} /></button></div>
                <div className="share-url"><span>{watchUrl}</span><button title="复制链接" aria-label="复制链接" onClick={async () => flash(await copyText(watchUrl) ? "链接已复制" : "请手动复制链接")}><Copy size={16} /></button></div>
                <button className="outline-button wide" onClick={() => window.open(watchUrl, "_blank")}><ExternalLink size={16} />打开学员页</button>
              </section>

              <section className="rail-section stats-strip">
                <div><UsersRound size={17} /><strong>{snapshot.actualOnline}</strong><span>真实在线</span></div>
                <div><Radio size={17} /><strong>{snapshot.heat}</strong><span>课堂热度</span></div>
                <div><Hand size={17} /><strong>{raisedHands.length}</strong><span>正在举手</span></div>
              </section>

              <section className="rail-section participant-section">
                <div className="rail-title"><UsersRound size={17} /><strong>课堂成员</strong><span>{connectedParticipants.length}</span></div>
                {raisedHands.length > 0 && <div className="queue-label">举手队列</div>}
                {raisedHands.map((participant) => (
                  <ParticipantRow key={participant.id} participant={participant} highlight onApprove={() => teacherAction("teacher:approve", participant)} onReject={() => teacherAction("teacher:reject", participant)} />
                ))}
                <div className="participant-list">
                  {connectedParticipants.filter((participant) => !participant.handRaisedAt).map((participant) => (
                    <ParticipantRow key={participant.id} participant={participant} onRevoke={() => teacherAction("teacher:revoke", participant)} onMute={(muted) => socket?.emit("teacher:mute", participant.id, muted)} onKick={() => teacherAction("teacher:kick", participant)} />
                  ))}
                  {connectedParticipants.length === 0 && <Empty label="还没有学员进入" icon={<UsersRound size={21} />} />}
                </div>
              </section>

              <section className="rail-section chat-preview">
                <div className="rail-title"><MessageSquareText size={17} /><strong>课堂消息</strong><span>{snapshot.messages.length}</span></div>
                <div className="message-list compact">
                  {snapshot.messages.slice(-4).map((message) => <div className="message" key={message.id}><b>{message.nickname}</b><span>{message.body}</span><time>{formatClock(message.createdAt)}</time></div>)}
                  {snapshot.messages.length === 0 && <Empty label="暂无课堂消息" icon={<MessageSquareText size={21} />} />}
                </div>
              </section>
            </aside>
          </div>
        )}
      </main>
    </div>
  );
}

function Toggle({ label, checked, onChange }: { label: string; checked: boolean; onChange: (checked: boolean) => void }) {
  return <label className="toggle-row"><span>{label}</span><input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} /><i /></label>;
}

interface ParticipantRowProps {
  participant: Participant;
  highlight?: boolean;
  onApprove?: () => void;
  onReject?: () => void;
  onRevoke?: () => void;
  onMute?: (muted: boolean) => void;
  onKick?: () => void;
}

function ParticipantRow({ participant, highlight, onApprove, onReject, onRevoke, onMute, onKick }: ParticipantRowProps) {
  const [menu, setMenu] = useState(false);
  return (
    <div className={`participant-row ${highlight ? "highlight" : ""}`}>
      <div className="participant-avatar">{participant.nickname.slice(0, 1)}</div>
      <div className="participant-name"><strong>{participant.nickname}</strong><span>{participant.role === "cohost" ? "连麦中" : highlight ? "申请连麦" : "观看中"}</span></div>
      {highlight ? (
        <div className="row-actions"><button className="approve" title="同意连麦" aria-label="同意连麦" onClick={onApprove}><Check size={15} /></button><button title="拒绝" aria-label="拒绝" onClick={onReject}><CircleStop size={15} /></button></div>
      ) : participant.role === "cohost" ? (
        <button className="small-command" onClick={onRevoke}>结束</button>
      ) : (
        <div className="menu-wrap"><button className="icon-button" title="成员操作" aria-label="成员操作" onClick={() => setMenu((value) => !value)}><EllipsisVertical size={16} /></button>{menu && <div className="row-menu"><button onClick={() => { onMute?.(!participant.muted); setMenu(false); }}><MicOff size={15} />{participant.muted ? "解除禁言" : "禁言"}</button><button className="danger" onClick={() => { onKick?.(); setMenu(false); }}><UserRoundX size={15} />移出课堂</button></div>}</div>
      )}
    </div>
  );
}

function Empty({ label, icon }: { label: string; icon: React.ReactNode }) {
  return <div className="empty-state">{icon}<span>{label}</span></div>;
}

function RecordSection() {
  return <section className="placeholder-section"><div className="placeholder-icon"><Video size={27} /></div><h2>本地录制保持独立运行</h2><p>当前稳定版继续使用 ScreenCaptureKit 原生 MP4 保存链路。</p><div className="integrity-row"><Check size={17} /><span>H.264 视频验证</span><Check size={17} /><span>AAC 音轨验证</span><Check size={17} /><span>临时文件隔离</span></div></section>;
}

function ReplaySection({ replays, onCreate }: { replays: Replay[]; onCreate: () => void }) {
  return <section className="content-section"><div className="content-section-header"><div><span className="eyebrow">REPLAY LIBRARY</span><h2>课程回放</h2></div><button className="secondary-button" onClick={onCreate}><Plus size={16} />登记本地录像</button></div><div className="replay-table">{replays.map((replay) => <div key={replay.id}><FileVideo size={20} /><strong>{replay.title}</strong><span>{replay.status === "pending" ? "等待上传" : replay.status}</span><time>{new Date(replay.createdAt).toLocaleDateString("zh-CN")}</time></div>)}{replays.length === 0 && <Empty label="还没有课程回放" icon={<FileVideo size={24} />} />}</div></section>;
}

function SettingsSection() {
  return <section className="content-section"><div className="content-section-header"><div><span className="eyebrow">SYSTEM STATUS</span><h2>设置与诊断</h2></div></div><div className="diagnostic-grid"><div><Wifi size={20} /><strong>课堂服务</strong><span>连接正常</span></div><div><LockKeyhole size={20} /><strong>课堂权限</strong><span>服务端控制</span></div><div><Clipboard size={20} /><strong>支付接口</strong><span>已预留 · 未启用</span></div><div><LayoutDashboard size={20} /><strong>音视频服务</strong><span>模拟模式</span></div></div></section>;
}
