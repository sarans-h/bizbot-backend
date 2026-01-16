// src/database.ts
import "reflect-metadata";
import config from "@/config";
import { DataSource } from "typeorm";
import { logger } from "@/utils/logger";

export const AppDataSource = new DataSource({
  type: "postgres",
  host: config.POSTGRES_HOST ?? "localhost",
  port: config.POSTGRES_PORT ? Number(config.POSTGRES_PORT) : 5432,
  username: config.POSTGRES_USER ?? "postgres",
  password: config.POSTGRES_PASSWORD ?? "postgres",
  database: config.POSTGRES_DB ?? "postgres",
  synchronize: true, // Auto-create tables in dev; disable in prod
  logging: false,
  entities: ["src/entities/**/*.ts"], // source files
  migrations: ["src/migrations/**/*.ts"],
  subscribers: [],
});
/**
 * Connect to database
 */
export async function connectDB(): Promise<void> {
  try {
    if (!AppDataSource.isInitialized) {
      await AppDataSource.initialize();
      logger.info("Postgres connected");
    }
  } catch (error) {
    logger.error("Database connection failed", { error });
    process.exit(1);
  }
}
