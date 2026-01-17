import { logger } from "@/utils/logger";
import type { Request, Response, NextFunction, RequestHandler } from "express";

export const requestLogger: RequestHandler = (
  req: Request,
  res: Response,
  next: NextFunction,
) => {
  const start = process.hrtime.bigint();

  res.on("finish", () => {
    const durationMs = Number(process.hrtime.bigint() - start) / 1_000_000;

    const logLevel =
      res.statusCode >= 500 ? "error" : res.statusCode >= 400 ? "warn" : "info";

    logger.log(logLevel, "http_request", {
      requestId: req.requestId,
      route: req.route?.path ?? req.originalUrl,
      method: req.method,
      path: req.originalUrl,
      statusCode: res.statusCode,
      durationMs: Math.round(durationMs),
      userId: req.user?.id ?? null,

      ip: req.ip,
      userAgent: req.get("user-agent"),
    });
  });

  next();
};
