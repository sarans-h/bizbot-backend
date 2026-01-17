import fs from "node:fs";
import { createLogger, format, transports } from "winston";

fs.mkdirSync("logs", { recursive: true });

const { combine, timestamp, printf, colorize, uncolorize, errors } = format;
const logFormat = printf((info) => {
  const { level, message, timestamp, stack, ...meta } = info as Record<
    string,
    unknown
  >;

  const metaStr =
    meta && Object.keys(meta).length > 0 ? ` ${JSON.stringify(meta)}` : "";

  return `${timestamp} ${level}: ${stack ?? message}${metaStr}`;
});

const baseFormat = combine(
  timestamp({ format: "YYYY-MM-DD HH:mm:ss" }),
  errors({ stack: true }),
  logFormat,
);

export const logger = createLogger({
  level: "info", // default log level
  transports: [
    new transports.Console({
      format: combine(colorize(), baseFormat),
    }),
    new transports.File({
      filename: "logs/error.log",
      level: "error",
      format: combine(uncolorize(), baseFormat),
    }),
    new transports.File({
      filename: "logs/combined.log",
      format: combine(uncolorize(), baseFormat),
    }),
  ],
  exitOnError: false,
});
