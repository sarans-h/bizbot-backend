import cors, { type CorsOptions } from "cors";

const allowlist: readonly string[] = [
  "https://example.com",
  "https://app.example.com",
];

const corsOptions: CorsOptions = {
  origin(
    origin: string | undefined,
    callback: (err: Error | null, allow?: boolean) => void,
  ) {
    // Allow server-to-server or curl (no origin)
    if (!origin) return callback(null, true);

    if (allowlist.includes(origin)) {
      return callback(null, true);
    }

    return callback(new Error("Not allowed by CORS"));
  },
  credentials: true,
  exposedHeaders: ["x-request-id"],
};

export const corsMiddleware = cors(corsOptions);
