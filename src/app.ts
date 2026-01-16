import "reflect-metadata"; // MUST be first

import express from "express";
import dotenv from "dotenv";
import helmet from "helmet";

dotenv.config();

const app = express();
app.use(helmet());
app.use(express.json());
export default app;
