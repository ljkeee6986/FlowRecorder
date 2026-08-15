import { describe, expect, it } from "vitest";
import { classroomDeviceId, statusLabel } from "./utils";

describe("classroom utilities", () => {
  it("keeps the same anonymous device identity", () => {
    const values = new Map<string, string>();
    const storage = {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => values.set(key, value)
    };
    expect(classroomDeviceId(storage)).toBe(classroomDeviceId(storage));
  });

  it("uses unambiguous room status labels", () => {
    expect(statusLabel("scheduled")).toBe("未开播");
    expect(statusLabel("live")).toBe("直播中");
    expect(statusLabel("ended")).toBe("已结束");
  });
});
