import { useMemo } from "react";
import { BarChart, Bar, YAxis, ResponsiveContainer, Tooltip } from "recharts";
import type { VersionedExecution, RetainedVersionInfo } from "./services/api";

type TooltipEntry = { dataKey: string; value: number; stroke: string };
type TooltipCustomProps = { active?: boolean; payload?: TooltipEntry[] };

type Bucket = { time: number } & Record<string, number>;

type Props = {
  executions: VersionedExecution[];
  versions: Record<string, RetainedVersionInfo>;
};

const STATUS_COLOR: Record<string, string> = {
  active: "#4CBEC5",
  ramping: "#CF7C01",
  draining: "#4C5B5C",
  inactive: "#334041",
};

const FALLBACK_COLORS = ["#4CBEC5", "#CF7C01", "#869597", "#4C5B5C"];

const MAX_BUCKETS = 28;
const MIN_BUCKETS_TO_RENDER = 2;

function buildBuckets(executions: VersionedExecution[]): Bucket[] {
  const byTime = new Map<number, Record<string, number>>();

  for (const ex of executions) {
    if (!byTime.has(ex.receivedAt)) byTime.set(ex.receivedAt, {});

    const bucket = byTime.get(ex.receivedAt)!;
    bucket[ex.version] = (bucket[ex.version] ?? 0) + 1;
  }

  return [...byTime.entries()]
    .sort(([tsA], [tsB]) => tsA - tsB)
    .slice(-MAX_BUCKETS)
    .map(([time, counts]) => ({ time, ...counts }));
}

function versionColor(key: string, versions: Record<string, RetainedVersionInfo>, idx: number): string {
  const status = versions[key]?.status;
  return status ? STATUS_COLOR[status] : FALLBACK_COLORS[idx % FALLBACK_COLORS.length];
}

function CustomTooltip({ active, payload }: TooltipCustomProps) {
  if (!active || !payload?.length) return null;

  return (
    <div className="chart-tooltip">
      {payload.map((p) => (
        <div key={p.dataKey} className="chart-tooltip__row">
          <span className="chart-tooltip__dot" style={{ background: p.stroke }} />
          <span className="chart-tooltip__key">{p.dataKey.toUpperCase()}</span>
          <span className="chart-tooltip__val">{p.value}</span>
        </div>
      ))}
    </div>
  );
}

export function VersionChart({ executions, versions }: Props) {
  const buckets = useMemo(() => buildBuckets(executions), [executions]);

  const versionKeys = useMemo(
    () => [...new Set(buckets.flatMap((b) => Object.keys(b).filter((k) => k !== "time")))].filter((k) => k in versions),
    [buckets, versions],
  );

  if (buckets.length < MIN_BUCKETS_TO_RENDER) return <div className="version-chart version-chart--empty" />;

  return (
    <div className="version-chart">
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={buckets} margin={{ top: 8, right: 12, bottom: 4, left: 0 }} barCategoryGap="20%">
          <YAxis
            width={24}
            tick={{ fill: "rgba(134,149,151,0.45)", fontSize: 8, fontFamily: '"Roboto Mono", monospace' }}
            tickLine={false}
            axisLine={false}
            allowDecimals={false}
          />
          <Tooltip content={<CustomTooltip />} cursor={{ fill: "rgba(76,190,197,0.06)" }} />
          {versionKeys.map((key, i) => {
            const color = versionColor(key, versions, i);

            return (
              <Bar key={key} dataKey={key} stackId="a" fill={color} fillOpacity={0.75} isAnimationActive={false} />
            );
          })}
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}
