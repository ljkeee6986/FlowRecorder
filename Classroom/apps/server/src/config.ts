import "dotenv/config";

const isProduction = process.env.NODE_ENV === "production";
const defaultJwtSecret = "flowrecorder-classroom-local-development-only";

export const config = {
  isProduction,
  port: Number(process.env.PORT ?? 4100),
  webOrigin: process.env.WEB_ORIGIN ?? "http://localhost:4173",
  publicWebUrl: process.env.PUBLIC_WEB_URL ?? "http://localhost:4173",
  jwtSecret: process.env.JWT_SECRET ?? defaultJwtSecret,
  teacherAccessCode: process.env.TEACHER_ACCESS_CODE ?? "jack-demo",
  paymentsEnabled: process.env.PAYMENTS_ENABLED === "true",
  trtc: {
    enabled: process.env.TRTC_ENABLED === "true",
    sdkAppId: Number(process.env.TRTC_SDK_APP_ID ?? 0),
    secretKey: process.env.TRTC_SECRET_KEY ?? ""
  }
};

if (isProduction && config.jwtSecret === defaultJwtSecret) {
  throw new Error("Production requires an explicit JWT_SECRET");
}

if (config.trtc.enabled && (!config.trtc.sdkAppId || !config.trtc.secretKey)) {
  throw new Error("TRTC_ENABLED requires TRTC_SDK_APP_ID and TRTC_SECRET_KEY");
}
