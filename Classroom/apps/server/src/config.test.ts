import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { resolveAutomaticPublicWebUrl, resolveWorkspacePath } from "./config.js";

describe("workspace configuration paths", () => {
  it("resolves persistence files from the Classroom workspace", () => {
    const expected = fileURLToPath(new URL("../../../.data/classroom-state.json", import.meta.url));

    expect(resolveWorkspacePath(".data/classroom-state.json")).toBe(expected);
  });

  it("preserves absolute persistence paths", () => {
    expect(resolveWorkspacePath("/tmp/flowrecorder-state.json")).toBe("/tmp/flowrecorder-state.json");
  });

  it("prefers the active Wi-Fi address and applies the public web port", () => {
    const candidates = [
      { name: "utun3", address: "100.64.0.2", family: "IPv4", internal: false },
      { name: "en7", address: "192.168.31.251", family: "IPv4", internal: false },
      { name: "en0", address: "192.168.1.206", family: "IPv4", internal: false },
      { name: "lo0", address: "127.0.0.1", family: "IPv4", internal: true }
    ];

    expect(resolveAutomaticPublicWebUrl(candidates, 4173)).toBe("http://192.168.1.206:4173");
  });

  it("falls back to localhost when no external IPv4 address exists", () => {
    expect(resolveAutomaticPublicWebUrl([], 4100)).toBe("http://localhost:4100");
  });
});
