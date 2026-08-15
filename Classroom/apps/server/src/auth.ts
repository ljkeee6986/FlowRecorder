import jwt from "jsonwebtoken";
import type { NextFunction, Request, Response } from "express";
import type { ParticipantRole } from "@flowrecorder/contracts";
import { config } from "./config.js";

export type SessionClaims =
  | { kind: "teacher"; teacherId: string; nickname: string }
  | { kind: "participant"; roomId: string; participantId: string; role: ParticipantRole };

declare global {
  namespace Express {
    interface Request {
      session?: SessionClaims;
    }
  }
}

export function signSession(claims: SessionClaims, expiresIn = "12h"): string {
  return jwt.sign(claims, config.jwtSecret, { expiresIn } as jwt.SignOptions);
}

export function verifySession(token: string): SessionClaims {
  return jwt.verify(token, config.jwtSecret) as SessionClaims;
}

export function requireTeacher(req: Request, res: Response, next: NextFunction): void {
  const token = req.header("authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) {
    res.status(401).json({ error: "需要讲师登录" });
    return;
  }

  try {
    const session = verifySession(token);
    if (session.kind !== "teacher") {
      res.status(403).json({ error: "仅讲师可执行此操作" });
      return;
    }
    req.session = session;
    next();
  } catch {
    res.status(401).json({ error: "登录已失效，请重新登录" });
  }
}
