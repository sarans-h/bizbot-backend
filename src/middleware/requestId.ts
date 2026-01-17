import type { NextFunction, Request, RequestHandler, Response } from "express";
import { v4 as uuidv4 } from "uuid";

export const requestIdMiddleware: RequestHandler = function (
  req: Request,
  res: Response,
  next: NextFunction,
) {
  const requestId: string = (req.header("x-request-id") as string) || uuidv4();

  req.headers["x-request-id"] = requestId;
  res.setHeader("x-request-id", requestId);

  // Attach to request object (TypeScript-safe usage via casting)
  req.requestId = requestId;

  next();
};
