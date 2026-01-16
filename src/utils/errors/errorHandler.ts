import type { Request, Response } from "express";
import { AppError } from "@/utils/errors/AppError";
import { logger } from "@/utils/logger";

export function errorHandler(
  err: Error | AppError,
  req: Request,
  res: Response
) {
  let statusCode = 500;
  let message = "Something went wrong";
  if (err instanceof AppError) {
    // Operational errors
    statusCode = err.statusCode;
    message = err.message;
  } else {
    // Programming or unknown errors
    logger.error("Unexpected error", { err });
  }

  res.status(statusCode).json({
    status: "error",
    message,
  });
}
