import type { LiveRoom, PublicRoom } from "@flowrecorder/contracts";
import { Maximize2, MonitorUp, Radio, VideoOff } from "lucide-react";
import { useRef, type RefObject } from "react";
import { statusLabel } from "./utils";

interface StageProps {
  room: LiveRoom | PublicRoom;
  teacher?: boolean;
  localVideoRef?: RefObject<HTMLVideoElement | null>;
  cohostName?: string;
}

export function Stage({ room, teacher = false, localVideoRef, cohostName }: StageProps) {
  const stageRef = useRef<HTMLDivElement>(null);
  const isLive = room.status === "live";

  return (
    <div className="stage" ref={stageRef}>
      <div className="stage-toolbar">
        <span className={`live-indicator ${isLive ? "is-live" : ""}`}>
          <Radio size={13} /> {statusLabel(room.status)}
        </span>
        <button
          className="icon-button on-dark"
          title="全屏"
          aria-label="全屏"
          onClick={() => stageRef.current?.requestFullscreen?.()}
        >
          <Maximize2 size={17} />
        </button>
      </div>

      <div className="slide-canvas">
        <div className="slide-kicker">FLOW · 01</div>
        <h2>把复杂内容<br />讲得清楚</h2>
        <div className="slide-rule" />
        <div className="slide-columns">
          <div><b>01</b><span>建立框架</span></div>
          <div><b>02</b><span>现场演示</span></div>
          <div><b>03</b><span>答疑复盘</span></div>
        </div>
        <div className="slide-corner">JACK CLASSROOM</div>
      </div>

      <div className="teacher-camera">
        <div className="camera-portrait">
          <img src="/icon_128x128.png" alt="讲师" />
        </div>
        <div className="camera-label"><span />Jack 讲师</div>
      </div>

      {localVideoRef && (
        <div className="cohost-camera">
          <video ref={localVideoRef} muted playsInline autoPlay />
          <div className="camera-label"><span />{cohostName ?? "连麦中"}</div>
        </div>
      )}

      {!isLive && (
        <div className="stage-state">
          {room.status === "ended" ? <VideoOff size={28} /> : <MonitorUp size={28} />}
          <strong>{room.status === "ended" ? "本场课堂已结束" : teacher ? "开播画面预览" : "讲师正在准备"}</strong>
        </div>
      )}
    </div>
  );
}
