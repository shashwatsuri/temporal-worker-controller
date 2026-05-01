import { z } from "zod";

const EnvSchema = z.object({
  VITE_API_BASE_URL:    z.string().default(""),
  VITE_LOCAL_DEMO_MODE: z.string().optional().transform((v) => v === "true"),
});

export const env = EnvSchema.parse(import.meta.env);
