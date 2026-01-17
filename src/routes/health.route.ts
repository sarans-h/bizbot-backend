import { Router } from "express";
import { AppDataSource } from "@/lib/database";

const router = Router();

router.get("/health", (_req, res) => {
  res.status(200).json({ status: "ok" });
});
router.get("/ready", async (_req, res, next) => {
  try {
    // 1. DB connectivity
    await AppDataSource.query("SELECT 1");

    // 2. Migrations applied
    const hasPendingMigrations =
      AppDataSource.showMigrations && (await AppDataSource.showMigrations());

    if (hasPendingMigrations) {
      return res.status(503).json({
        status: "not-ready",
        reason: "pending migrations",
      });
    }

    res.status(200).json({ status: "ready" });
  } catch (err) {
    next(err); // centralized error handler logs via winston
  }
});
export default router;
