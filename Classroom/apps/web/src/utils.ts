export function classroomDeviceId(storage: Pick<Storage, "getItem" | "setItem"> = localStorage): string {
  const key = "flowrecorder.classroom.deviceId";
  const existing = storage.getItem(key);
  if (existing) return existing;
  const value = typeof crypto.randomUUID === "function"
    ? crypto.randomUUID()
    : `device-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  storage.setItem(key, value);
  return value;
}

export function formatClock(iso: string): string {
  return new Intl.DateTimeFormat("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(iso));
}

export function statusLabel(status: "scheduled" | "live" | "ended"): string {
  if (status === "live") return "直播中";
  if (status === "ended") return "已结束";
  return "未开播";
}

export async function copyText(value: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(value);
    return true;
  } catch {
    return false;
  }
}
