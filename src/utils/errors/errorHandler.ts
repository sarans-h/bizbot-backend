import type { NextFunction, Request, Response } from "express";
import { AppError } from "@/utils/errors/AppError";
import { logger } from "@/utils/logger";
import type { ValidationDetails } from "@/types/validation";

export function errorHandler(
  err: Error | AppError,
  _req: Request,
  res: Response,
  next: NextFunction,
) {
  if (res.headersSent) {
    return next(err);
  }

  let statusCode = 500;
  let message = "Something went wrong";
  let details: ValidationDetails | unknown = undefined;

  if (err instanceof AppError) {
    // Operational errors
    statusCode = err.statusCode;
    message = err.message;
    details = err.details;
  } else {
    // Programming or unknown errors
    logger.error("Unexpected error", {
      name: err.name,
      message: err.message,
      stack: err.stack,
    });
  }

  res.status(statusCode).json({
    status: "error",
    message,
    ...(details != undefined ? { details } : {}),
  });
}
