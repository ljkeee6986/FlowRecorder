import { config as loadEnv } from "dotenv";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const workspaceEnvFile = fileURLToPath(new URL("../../../.env", import.meta.url));
const workspaceRoot = fileURLToPath(new URL("../../../", import.meta.url));
loadEnv({ path: workspaceEnvFile, quiet: true });

export function resolveWorkspacePath(filePath: string): string {
  return resolve(workspaceRoot, filePath);
}

const isProduction = process.env.NODE_ENV === "production";
const defaultJwtSecret = "flowrecorder-classroom-local-development-only";
const defaultTeacherAccessCode = "jack-demo";
const persistenceDriver = process.env.PERSISTENCE_DRIVER ?? (isProduction ? "postgres" : "file");
const persistenceFile = resolveWorkspacePath(process.env.PERSISTENCE_FILE ?? ".data/classroom-state.json");
const zeroCostMode = process.env.ZERO_COST_MODE !== "false";

export const config = {
  isProduction,
  port: Number(process.env.PORT ?? 4100),
  webOrigin: process.env.WEB_ORIGIN ?? "http://localhost:4173",
  publicWebUrl: process.env.PUBLIC_WEB_URL ?? "http://localhost:4173",
  zeroCostMode,
  jwtSecret: process.env.JWT_SECRET ?? defaultJwtSecret,
  teacherAccessCode: process.env.TEACHER_ACCESS_CODE ?? defaultTeacherAccessCode,
  paymentsEnabled: process.env.PAYMENTS_ENABLED === "true",
  persistence: {
    driver: persistenceDriver as "memory" | "file" | "postgres",
    filePath: persistenceFile,
    databaseUrl: process.env.DATABASE_URL ?? ""
  },
  trtc: {
    enabled: process.env.TRTC_ENABLED === "true",
    sdkAppId: Number(process.env.TRTC_SDK_APP_ID ?? 0),
    secretKey: process.env.TRTC_SECRET_KEY ?? "",
    strictPermissions: process.env.TRTC_STRICT_PERMISSIONS === "true"
  }
};

if (isProduction && config.jwtSecret === defaultJwtSecret) {
  throw new Error("Production requires an explicit JWT_SECRET");
}

if (isProduction && config.teacherAccessCode === defaultTeacherAccessCode) {
  throw new Error("Production requires an explicit TEACHER_ACCESS_CODE");
}

if (!(["memory", "file", "postgres"] as const).includes(config.persistence.driver)) {
  throw new Error("PERSISTENCE_DRIVER must be memory, file, or postgres");
}

if (isProduction && config.persistence.driver !== "postgres") {
  throw new Error("Production requires PERSISTENCE_DRIVER=postgres");
}

if (config.persistence.driver === "postgres" && !config.persistence.databaseUrl) {
  throw new Error("PostgreSQL persistence requires DATABASE_URL");
}

if (config.trtc.enabled && (!config.trtc.sdkAppId || !config.trtc.secretKey)) {
  throw new Error("TRTC_ENABLED requires TRTC_SDK_APP_ID and TRTC_SECRET_KEY");
}

if (config.trtc.enabled && !config.trtc.strictPermissions) {
  throw new Error("TRTC_ENABLED requires TRTC_STRICT_PERMISSIONS=true after enabling PrivateMapKey checks in Tencent Cloud");
}

if (config.zeroCostMode && (config.trtc.enabled || config.paymentsEnabled)) {
  throw new Error("ZERO_COST_MODE forbids TRTC and payment providers; set ZERO_COST_MODE=false only after approving paid cloud usage");
}
