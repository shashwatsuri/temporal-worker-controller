import { useVersioningState } from "./useVersioningState";
import { useDiagram } from "./services/diagram/useDiagram";
import { useDots } from "./services/diagram/useDots";
import { drawDiagram, drawDots } from "./services/diagram/draw";
import { useAnimationLoop } from "./services/canvas";
import { useResizableCanvas } from "./useResizableCanvas";
import { POLL_INTERVAL } from "./services/api";
import { WorkflowTable } from "./WorkflowTable/WorkflowTable";
import "./App.css";

export default function App() {
  const { versions, executions, lastPolledAt, reset } = useVersioningState();

  const { canvasRef, size } = useResizableCanvas();

  const tickDiagram = useDiagram(versions, size.w, size.h);
  const dotsRef = useDots(executions);

  useAnimationLoop(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const dpr = window.devicePixelRatio ?? 1;
    const { width, height } = canvas.getBoundingClientRect();

    if (canvas.width !== width * dpr || canvas.height !== height * dpr) {
      canvas.width = width * dpr;
      canvas.height = height * dpr;
    }

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, width, height);

    const now = Date.now();
    const layout = tickDiagram(now);

    drawDiagram(layout)(ctx);
    drawDots(dotsRef.current, layout, now)(ctx);
  }, true);

  return (
    <div className="app">
      <header className="app-header">
        <div className="app-header__brand">
          <span className="app-header__overline">TEMPORAL</span>
          <h1 className="app-header__title">Worker Versioning</h1>
        </div>
        <div className="app-header__controls">
          <div className="app-header__live">
            <span className="live-dot" />
            LIVE
          </div>
          <span className="meta">
            {lastPolledAt
              ? `polled ${new Date(lastPolledAt).toLocaleTimeString()} · every ${POLL_INTERVAL / 1000}s`
              : "waiting for first poll…"}
          </span>
          <button onClick={reset}>Reset</button>
        </div>
      </header>
      <div className="main">
        <canvas ref={canvasRef} className="diagram-canvas" />
        <WorkflowTable executions={executions} versions={versions} />
      </div>
    </div>
  );
}
