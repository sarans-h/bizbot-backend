// src/metrics.ts
import client from "prom-client";

client.collectDefaultMetrics();

export const httpRequestCount = new client.Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "route", "status"],
});

export const httpRequestDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request latency",
  buckets: [0.1, 0.3, 0.5, 1, 2, 5],
  labelNames: ["method", "route", "status"],
});

export const register = client.register;
