import { config } from "./config.js";
import { createClassroomServer } from "./app.js";
import { createPersistence } from "./persistence.js";
import { ClassroomStore } from "./store.js";

const persistence = createPersistence();
const restoredState = await persistence.load();
const store = new ClassroomStore(!restoredState);
if (restoredState) store.restore(restoredState);
store.setMutationListener(() => persistence.scheduleSave(store.exportState()));
persistence.scheduleSave(store.exportState());

const { httpServer, io } = createClassroomServer(store, persistence.name);

async function shutdown(signal: string): Promise<void> {
  try {
    console.log(`${signal}: saving classroom state...`);
    await persistence.close();
    io.disconnectSockets(true);
    io.close();
    httpServer.closeAllConnections();
    process.exit(0);
  } catch (error) {
    console.error(`${signal}: shutdown failed`, error);
    process.exit(1);
  }
}

process.once("SIGTERM", () => void shutdown("SIGTERM"));
process.once("SIGINT", () => void shutdown("SIGINT"));

httpServer.listen(config.port, "0.0.0.0", () => {
  const room = store.listRooms()[0];
  console.log(`Classroom API: http://localhost:${config.port}`);
  console.log(`Teacher console: ${config.publicWebUrl}/teacher`);
  console.log(`Demo classroom: ${config.publicWebUrl}/live/${room.shareCode}`);
  console.log(`Media provider: ${process.env.TRTC_ENABLED === "true" ? "trtc" : "mock"}`);
  console.log(`Persistence: ${persistence.name}`);
});
