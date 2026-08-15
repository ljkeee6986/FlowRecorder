import { config } from "./config.js";
import { createClassroomServer } from "./app.js";

const { httpServer, store } = createClassroomServer();

httpServer.listen(config.port, "0.0.0.0", () => {
  const room = store.listRooms()[0];
  console.log(`Classroom API: http://localhost:${config.port}`);
  console.log(`Teacher console: ${config.publicWebUrl}/teacher`);
  console.log(`Demo classroom: ${config.publicWebUrl}/live/${room.shareCode}`);
  console.log(`Media provider: ${process.env.TRTC_ENABLED === "true" ? "trtc" : "mock"}`);
});
