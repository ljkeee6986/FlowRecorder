import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { resolveWorkspacePath } from "./config.js";

describe("workspace configuration paths", () => {
  it("resolves persistence files from the Classroom workspace", () => {
    const expected = fileURLToPath(new URL("../../../.data/classroom-state.json", import.meta.url));

    expect(resolveWorkspacePath(".data/classroom-state.json")).toBe(expected);
  });

  it("preserves absolute persistence paths", () => {
    expect(resolveWorkspacePath("/tmp/flowrecorder-state.json")).toBe("/tmp/flowrecorder-state.json");
  });
});
