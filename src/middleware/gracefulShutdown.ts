import type { Request, Response, NextFunction } from "express";

let activeRequests = 0;

export function inFlightRequestTracker(
  req: Request,
  res: Response,
  next: NextFunction,
): void {
  activeRequests += 1;

  let finalized = false;
  const finalize = () => {
    if (finalized) return;
    finalized = true;
    activeRequests = Math.max(0, activeRequests - 1);
  };

  res.on("finish", finalize);
  res.on("close", finalize);
  next();
}

export function getActiveRequests(): number {
  return activeRequests;
}

export async function waitForActiveRequestsToDrain(options?: {
  timeoutMs?: number;
  pollMs?: number;
}): Promise<void> {
  const timeoutMs = options?.timeoutMs ?? 25_000;
  const pollMs = options?.pollMs ?? 100;

  const start = Date.now();
  while (activeRequests > 0) {
    if (Date.now() - start > timeoutMs) {
      throw new Error(
        `Timed out waiting for in-flight requests to drain (active=${activeRequests})`,
      );
    }
    await new Promise((r) => setTimeout(r, pollMs));
  }
}

export function shutdownGate(
  req: Request,
  res: Response,
  next: NextFunction,
): void {
  const isShuttingDown = Boolean(req.app.locals.isShuttingDown);
  if (!isShuttingDown) return next();

  res.setHeader("Connection", "close");
  res.setHeader("Retry-After", "5");
  res.status(503).json({
    ok: false,
    message: "Server is shutting down",
  });
}
