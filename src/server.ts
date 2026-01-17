import "reflect-metadata"; // MUST be first

import app from "@/app";
import { connectDB, disconnectDB } from "@/lib/database";
import { errorHandler } from "@/utils/errors/errorHandler";
import { logger } from "@/utils/logger";
import {
  getActiveRequests,
  waitForActiveRequestsToDrain,
} from "@/middleware/gracefulShutdown";
import type { Server } from "http";
import type { Socket } from "net";
import { asynchHandler } from "@/middleware/asyncHandler";
import { register } from "./metrics";

async function main() {
  await connectDB();
  app.get(
    "/__debug/sleep",
    asynchHandler(async (req, res) => {
      const msParam = Array.isArray(req.query.ms)
        ? req.query.ms[0]
        : req.query.ms;
      const requestedMs = msParam ? Number(msParam) : 10_000;
      const sleepMs = Math.min(60_000, Math.max(0, Number(requestedMs) || 0));

      await new Promise((r) => setTimeout(r, sleepMs));
      return res.status(200).json({ ok: true, sleptMs: sleepMs });
    }),
  );
  app.get(
    "/metrics",
    (req, res, next) => {
      const ip = req.ip ?? ""; // default to empty string

      if (!ip.startsWith("10.")) {
        res.status(403).send("Forbidden");
        return;
      }
      next();
    },
    async (_req, res) => {
      res.setHeader("Content-Type", register.contentType);
      res.end(await register.metrics());
    },
  );

  app.use(errorHandler);

  const PORT = process.env.PORT || 3000;

  app.locals.isShuttingDown = false;

  const server = app.listen(PORT, () => {
    logger.info(`Server running on port ${PORT}`);
  });

  attachGracefulShutdown(server);
}

function attachGracefulShutdown(server: Server) {
  const sockets = new Set<Socket>();
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });

  let shutdownStarted = false;
  const shutdownTimeoutMs = 30000;

  const startShutdown = async (signal: string) => {
    if (shutdownStarted) {
      logger.warn("Second shutdown signal received; forcing exit", {
        signal,
        activeRequests: getActiveRequests(),
      });
      for (const socket of sockets) socket.destroy();
      process.exit(1);
    }
    shutdownStarted = true;

    app.locals.isShuttingDown = true;
    logger.info("Graceful shutdown started", {
      signal,
      activeRequests: getActiveRequests(),
    });

    const forceTimer = setTimeout(() => {
      logger.error("Graceful shutdown timed out; forcing close", {
        activeRequests: getActiveRequests(),
      });
      for (const socket of sockets) socket.destroy();
      process.exit(1);
    }, shutdownTimeoutMs);
    forceTimer.unref();

    const serverClosePromise = new Promise<void>((resolve, reject) => {
      server.close((err) => {
        if (err) return reject(err);
        resolve();
      });
    });

    // Nudge keep-alive sockets to close once their current response is done.
    for (const socket of sockets) socket.end();

    try {
      await waitForActiveRequestsToDrain({ timeoutMs: shutdownTimeoutMs });
    } catch (error) {
      logger.warn("Continuing shutdown after drain timeout", {
        error,
        activeRequests: getActiveRequests(),
      });
    }

    await disconnectDB();

    try {
      await Promise.race([
        serverClosePromise,
        new Promise<void>((r) => setTimeout(r, 2_000)),
      ]);
    } catch (error) {
      logger.warn("Server close reported an error", { error });
    }

    clearTimeout(forceTimer);
    logger.info("Graceful shutdown complete");
    process.exit(0);
  };

  process.on("SIGTERM", () => void startShutdown("SIGTERM"));
  process.on("SIGINT", () => void startShutdown("SIGINT"));
}

main();
