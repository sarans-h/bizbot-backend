import compression from "compression";

export const compressionMiddleware = compression({
  threshold: 1024, // only compress >1KB
});
