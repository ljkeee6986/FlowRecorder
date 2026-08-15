import type { AddressInfo } from "node:net";
import { io as createClient, type Socket } from "socket.io-client";
import { describe, expect, it } from "vitest";
import { createClassroomServer } from "./app.js";
import { signSession } from "./auth.js";
import { ClassroomStore } from "./store.js";

describe("100-person classroom control plane", () => {
  it("accepts 100 simultaneous realtime participants and reports the actual count", async () => {
    const store = new ClassroomStore();
    const room = store.listRooms()[0];
    const server = createClassroomServer(store);
    await new Promise<void>((resolve) => server.httpServer.listen(0, "127.0.0.1", resolve));
    const { port } = server.httpServer.address() as AddressInfo;
    const clients: Socket[] = [];

    try {
      const connections = Array.from({ length: 100 }, async (_, index) => {
        const participant = store.joinRoom(room.id, `load-device-${index}`, `学员${index + 1}`)!;
        store.setParticipantConnected(participant.id, false);
        const token = signSession({
          kind: "participant",
          roomId: room.id,
          participantId: participant.id,
          role: "viewer"
        });
        const client = createClient(`http://127.0.0.1:${port}`, {
          auth: { token },
          transports: ["websocket"],
          forceNew: true,
          reconnection: false
        });
        clients.push(client);
        await new Promise<void>((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error(`participant ${index + 1} connection timed out`)), 5_000);
          client.once("connect", () => {
            clearTimeout(timer);
            resolve();
          });
          client.once("connect_error", (error) => {
            clearTimeout(timer);
            reject(error);
          });
        });
      });

      await Promise.all(connections);
      expect(store.snapshot(room.id)?.actualOnline).toBe(100);
    } finally {
      clients.forEach((client) => client.disconnect());
      server.io.close();
      server.httpServer.closeAllConnections();
    }
  }, 15_000);
});
