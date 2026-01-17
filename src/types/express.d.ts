import "express-serve-static-core";

declare module "express-serve-static-core" {
  interface Request {
    /**
     * Single contract for controllers: read user input ONLY from req.validated.*
     * Populated by initValidated() + validate(schema).
     */
    validated: {
      params: unknown;
      query: unknown;
      headers: unknown;
      body: unknown;
      file?: unknown;
      files?: unknown;
    };

    // optional, if using multer
    file?: unknown;
    files?: unknown;
    user?: {
      id?: string;
    };
    // from requestId middleware
    requestId?: string;
  }
}
