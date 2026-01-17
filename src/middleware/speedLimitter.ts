import slowDown from "express-slow-down";

export const speedLimiter = slowDown({
  windowMs: 60 * 1000,
  delayAfter: 100, // allow 100 req/min without delay
  delayMs: () => 500, // 500ms per request after limit
});
