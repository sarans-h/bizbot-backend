import "reflect-metadata"; // MUST be first

import app from "@/app";
import { connectDB } from "@/lib/database";
import { AppError } from "@/utils/errors/AppError";
import { errorHandler } from "@/utils/errors/errorHandler";
import { logger } from "@/utils/logger";

async function main() {
  await connectDB();
  app.all("/", (req, res, next) => {
    next(new AppError(`Can't find ${req.originalUrl} on this server!`, 404));
  });
  app.use(errorHandler);

  const PORT = process.env.PORT || 3000;
  app.listen(PORT, () => {
    logger.info(`Server running on port ${PORT}`);
  });
}
main();
