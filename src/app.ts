import "reflect-metadata"; // MUST be first

import express from "express";
import dotenv from "dotenv";
import helmet from "helmet";
import { requestIdMiddleware } from "./middleware/requestId";
import {
  inFlightRequestTracker,
  shutdownGate,
} from "./middleware/gracefulShutdown";
import { corsMiddleware } from "./middleware/enableCors";
import { compressionMiddleware } from "./middleware/compress";
import { rateLimiter } from "./middleware/rateLimitter";
import { speedLimiter } from "./middleware/speedLimitter";
import { requestLogger } from "./middleware/requestLogger";
import { initValidated } from "./middleware/validate";
import { metricsMiddleware } from "./middleware/metrics";

dotenv.config();

const app = express();

app.use(requestIdMiddleware);
app.use(shutdownGate);
app.use(metricsMiddleware);
app.use(inFlightRequestTracker);
app.use(helmet());
app.use(corsMiddleware);
app.use(compressionMiddleware);

app.use(rateLimiter);
app.use(speedLimiter);

app.use(express.json({ limit: "1mb" }));
app.use(express.urlencoded({ extended: true, limit: "1mb" }));
app.use(initValidated);

app.use(requestLogger);
export default app;
