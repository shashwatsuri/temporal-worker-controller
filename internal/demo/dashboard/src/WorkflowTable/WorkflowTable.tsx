import type { VersionedExecution, RetainedVersionInfo } from "../services/api";
import { VersionChart } from "../VersionChart";
import { shortVersion } from "../services/api";
import { useDrip } from "./useDrip";

const STATUS_COLOR: Record<string, string> = {
  active:   "#4CBEC5",
  ramping:  "#CF7C01",
  draining: "#4C5B5C",
  inactive: "#334041",
};

type Props = {
  executions: VersionedExecution[];
  versions:   Record<string, RetainedVersionInfo>;
};

export function WorkflowTable({ executions, versions }: Props) {
  const { displayed, paused, togglePause } = useDrip(executions, versions);

  return (
    <div className="workflow-panel">
      <div className="workflow-panel__header">
        <span className="workflow-panel__title">EXECUTIONS</span>
        <div className="workflow-panel__header-right">
          <button className="wf-pause-btn" onClick={togglePause}>
            {paused ? (
              <svg width="8" height="9" viewBox="0 0 8 9">
                <polygon points="0,0 8,4.5 0,9" fill="currentColor" />
              </svg>
            ) : (
              <svg width="8" height="9" viewBox="0 0 8 9">
                <rect x="0" y="0" width="3" height="9" fill="currentColor" />
                <rect x="5" y="0" width="3" height="9" fill="currentColor" />
              </svg>
            )}
          </button>
          <span className="workflow-panel__count">{executions.length.toLocaleString()}</span>
        </div>
      </div>

      <VersionChart executions={executions} versions={versions} />

      <div className="workflow-panel__cols">
        <span>ID</span>
        <span>VERSION</span>
        <span>TIME</span>
      </div>

      <div className={`workflow-panel__list${paused ? " workflow-panel__list--paused" : ""}`}>
        {displayed.map((ex) => {
          const color   = STATUS_COLOR[ex.displayStatus];
          const shortId = ex.id.split("-").pop() ?? ex.id.slice(-7);
          const time    = new Date(ex.receivedAt).toLocaleTimeString("en-US", {
            hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
          });

          return (
            <div key={ex.id} className="wf-row" onClick={togglePause}>
              <span className="wf-id">#{shortId}</span>
              <span className="wf-version" style={{ color }}>
                {shortVersion(ex.version).toUpperCase()}
              </span>
              <span className="wf-time">{time}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
