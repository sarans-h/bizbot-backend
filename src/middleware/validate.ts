import type { Request, Response, NextFunction } from "express";

export function initValidated(
  req: Request,
  _res: Response,
  next: NextFunction,
) {
  // Always present; overwritten by validate() when schemas are used.
  req.validated = {
    body: req.body,
    query: req.query,
    params: req.params,
    headers: req.headers,
  };
  next();
}
