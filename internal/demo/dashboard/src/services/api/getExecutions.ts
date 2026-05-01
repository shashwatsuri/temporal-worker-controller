import { z } from "zod";
import { env } from "../../env";

const ExecutionSchema = z.object({
  id: z.string(),
  version: z.string(),
});

const VersionInfoSchema = z.object({
  status: z.enum(["active", "ramping", "draining", "inactive"]),
  running: z.number(),
  ramping: z.number(),
});

const ApiResponseSchema = z.object({
  executions: z.array(ExecutionSchema),
  versions: z.record(z.string(), VersionInfoSchema),
});

export type Execution = z.infer<typeof ExecutionSchema>;
export type VersionStatus = z.infer<typeof VersionInfoSchema>["status"];
export type VersionInfo = z.infer<typeof VersionInfoSchema>;
export type ApiResponse = z.infer<typeof ApiResponseSchema>;

export type VersionedExecution = Execution & { receivedAt: number };

export function shortVersion(key: string): string {
  const dash = key.lastIndexOf('-')
  if (dash > 8) return `${key.slice(0, 6)}·${key.slice(dash + 1)}`
  return key
}

export type RetainedVersionInfo = VersionInfo & {
  droppedAt?: number;
  total: number;
};

export async function getExecutions(since: number): Promise<z.infer<typeof ApiResponseSchema>> {
  const res = await fetch(`${env.VITE_API_BASE_URL}/api/executions?since=${since}`, {
    headers: { Accept: "application/json", "Content-Type": "application/json" },
  });

  if (!res.ok) throw new Error(`API ${res.status}`);

  const data = ApiResponseSchema.parse(await res.json());
  data.executions.reverse();

  return data;
}
