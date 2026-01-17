import type { z } from "zod";

export type RequestPartSchemas = {
  body?: z.ZodType;
  query?: z.ZodType;
  params?: z.ZodType;
  headers?: z.ZodType;

  // for multipart/form-data uploads (if you use multer/etc.)
  file?: z.ZodType;
  files?: z.ZodType;
};

export * from "./validator";
