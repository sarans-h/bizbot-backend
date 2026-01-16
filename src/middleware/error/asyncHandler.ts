// to handle asynchronus error
// synchronus error are diverted to express but not follow sae with asynchronus
// use it for every route
import type { NextFunction, Request, Response } from "express";
import type { RequestHandler } from "express-serve-static-core";

export const asynchHandler = (fn: RequestHandler) => {
  return (req: Request, res: Response, next: NextFunction) => {
    return Promise.resolve(fn(req, res, next)).catch(next);
  };
};
