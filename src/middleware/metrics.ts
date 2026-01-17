// src/middlewares/metrics.ts
import type { NextFunction, Request, Response } from "express";
import { httpRequestCount, httpRequestDuration } from "../metrics";

export const metricsMiddleware = (
  req: Request,
  res: Response,
  next: NextFunction,
) => {
  const start = process.hrtime();

  res.on("finish", () => {
    const duration = process.hrtime(start)[0] + process.hrtime(start)[1] / 1e9;

    const labels = {
      method: req.method,
      route: req.route?.path || "unknown",
      status: res.statusCode.toString(),
    };

    httpRequestCount.inc(labels);
    httpRequestDuration.observe(labels, duration);
  });

  next();
};
