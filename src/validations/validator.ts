// import type { ZodError } from "zod/v3";\

import type { RequestPartSchemas } from ".";
import type { NextFunction, Request, RequestHandler, Response } from "express";
import { AppError } from "@/utils/errors/AppError";

//a generic functio, to validate the parts of request
function validatePart<T>(
  schemaName: string,
  schema: RequestPartSchemas[keyof RequestPartSchemas] | undefined,
  value: T,
): { ok: true; data: unknown } | { ok: false; error: AppError } {
  if (!schema) {
    return { ok: true, data: value };
  }
  const result = schema.safeParse(value);
  if (result.success) return { ok: true, data: result.data };
  const details = result.error.issues.map((i) => ({
    path: i.path.join("."),
    message: i.message,
    code: i.code,
  }));
  const err = new AppError(
    `Validation Failed for ${schemaName}`,
    400,
    true,
    details,
  );
  return { ok: false, error: err };
}
export function validate(schemas: RequestPartSchemas): RequestHandler {
  return (req: Request, res: Response, next: NextFunction) => {
    // initValidated() should have already initialized this,
    // but keep this defensive in case a route forgets to mount it.
    req.validated ??= {
      params: req.params,
      query: req.query,
      headers: req.headers,
      body: req.body,
    };

    // params (do NOT assign to req.params to avoid getter-only issues)
    const params = validatePart("params", schemas.params, req.params);
    if (!params.ok) return next(params.error);
    req.validated.params = params.data;

    // query (do NOT assign to req.query)
    const query = validatePart("query", schemas.query, req.query);
    if (!query.ok) return next(query.error);
    req.validated.query = query.data;

    // headers (store separately)
    const headers = validatePart("headers", schemas.headers, req.headers);
    if (!headers.ok) return next(headers.error);
    req.validated.headers = headers.data;

    // body (usually safe to overwrite; also store copy)
    const body = validatePart("body", schemas.body, req.body);
    if (!body.ok) return next(body.error);
    req.validated.body = body.data;

    // multipart (optional)
    const file = validatePart("file", schemas.file, req.file);
    if (!file.ok) return next(file.error);
    if (schemas.file) req.validated.file = file.data;

    const files = validatePart("files", schemas.files, req.files);
    if (!files.ok) return next(files.error);
    if (schemas.files) req.validated.files = files.data;

    return next();
  };
}
