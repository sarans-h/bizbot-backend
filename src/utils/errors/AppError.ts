import type { ValidationDetails } from "@/types/validation";

export class AppError extends Error {
  public readonly statusCode: number;
  public readonly isOperational: boolean;
  public readonly details: ValidationDetails | unknown;

  constructor(
    message: string,
    statusCode: number = 500,
    isOperational = true,
    details?: ValidationDetails | unknown,
  ) {
    super(message);
    this.isOperational = isOperational;
    this.statusCode = statusCode;
    this.details = details;
    Error.captureStackTrace(this, this.constructor);
  }
}
