import { arrow, compose, label, when, withAlpha } from "../canvas";
import type { DrawFn } from "../canvas";
import type { DiagramArrow, DiagramLayout, Rect, VersionNode } from "./types";
import { buildDotPath, insideRect, positionOnPath, TRAVEL_DURATION, type Dot } from "./dots";
import { shortVersion } from "../api";

const CHAMFER = 8;
const BAR_H = 2;

const C = {
  systemFill: "rgba(4, 100, 106, 0.12)",
  systemStroke: "#00848B",
  textPrimary: "rgba(255, 255, 255, 0.82)",
  textSecondary: "#869597",
  arrowStroke: "#04646A",
  gridDot: "rgba(4, 100, 106, 0.25)",
};

const STATUS = {
  active: {
    label: "ACTIVE",
    stroke: "#4CBEC5",
    fill0: "rgba(4, 100, 106, 0.30)",
    fill1: "rgba(0, 16, 18, 0.92)",
    bar: "rgba(76, 190, 197, 0.80)",
    barEnd: "rgba(76, 190, 197, 0)",
    glow: 20,
    lw: 1.5,
  },
  ramping: {
    label: "RAMPING",
    stroke: "#CF7C01",
    fill0: "rgba(80, 48, 0, 0.28)",
    fill1: "rgba(0, 16, 18, 0.92)",
    bar: "rgba(207, 124, 1, 0.80)",
    barEnd: "rgba(207, 124, 1, 0)",
    glow: 10,
    lw: 1.5,
  },
  draining: {
    label: "DRAINING",
    stroke: "#4C5B5C",
    fill0: "rgba(4, 100, 106, 0.08)",
    fill1: "rgba(0, 16, 18, 0.88)",
    bar: "rgba(76, 91, 92, 0.45)",
    barEnd: "rgba(76, 91, 92, 0)",
    glow: 0,
    lw: 1,
  },
  inactive: {
    label: "INACTIVE",
    stroke: "#2A3A3B",
    fill0: "rgba(4, 100, 106, 0.04)",
    fill1: "rgba(0, 16, 18, 0.80)",
    bar: "rgba(42, 58, 59, 0.35)",
    barEnd: "rgba(42, 58, 59, 0)",
    glow: 0,
    lw: 1,
  },
} as const;

// Traces a chamfered (cut-corner) path onto ctx — does not fill or stroke
function chamferPath(ctx: CanvasRenderingContext2D, r: Rect, c: number): void {
  ctx.beginPath();
  ctx.moveTo(r.x + c, r.y);
  ctx.lineTo(r.x + r.w - c, r.y);
  ctx.lineTo(r.x + r.w, r.y + c);
  ctx.lineTo(r.x + r.w, r.y + r.h - c);
  ctx.lineTo(r.x + r.w - c, r.y + r.h);
  ctx.lineTo(r.x + c, r.y + r.h);
  ctx.lineTo(r.x, r.y + r.h - c);
  ctx.lineTo(r.x, r.y + c);
  ctx.closePath();
}

function versionAlpha(node: VersionNode): number {
  const base = node.status === "inactive" ? 0.35 : node.status === "draining" ? 0.6 : 1;

  return base * node.progress;
}

function fmtTotal(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  return `${n}`;
}

function versionBox(node: VersionNode): DrawFn {
  const { rect: r, key, status, running, ramping, total } = node;
  const s = STATUS[status];
  const cx = r.x + r.w / 2;
  const sub =
    status === "inactive"
      ? `drained · ${fmtTotal(total)} total`
      : ramping > 0 && ramping < 100
        ? `${ramping}% · ${running} running · ${fmtTotal(total)}`
        : `${running} running · ${fmtTotal(total)} total`;

  return withAlpha(versionAlpha(node), (ctx) => {
    // 1 — gradient fill
    ctx.save();
    chamferPath(ctx, r, CHAMFER);
    const fillGrad = ctx.createLinearGradient(r.x, r.y, r.x, r.y + r.h);
    fillGrad.addColorStop(0, s.fill0);
    fillGrad.addColorStop(1, s.fill1);
    ctx.fillStyle = fillGrad;
    ctx.fill();
    ctx.restore();

    // 2 — accent bar (clipped to chamfer so corners are cut)
    ctx.save();
    chamferPath(ctx, r, CHAMFER);
    ctx.clip();
    const barGrad = ctx.createLinearGradient(r.x, r.y, r.x + r.w * 0.65, r.y);
    barGrad.addColorStop(0, s.bar);
    barGrad.addColorStop(1, s.barEnd);
    ctx.fillStyle = barGrad;
    ctx.fillRect(r.x, r.y, r.w, BAR_H);
    ctx.restore();

    // 3 — stroke with optional glow
    ctx.save();
    if (s.glow > 0) {
      ctx.shadowColor = s.stroke;
      ctx.shadowBlur = s.glow;
    }
    chamferPath(ctx, r, CHAMFER);
    ctx.strokeStyle = s.stroke;
    ctx.lineWidth = s.lw;
    ctx.stroke();
    ctx.restore();

    // 4 — three-line label stack: status · key · count
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";

    // Status word — colored, tracked, small
    ctx.letterSpacing = "1.5px";
    ctx.font = '700 8px "Inter", system-ui, sans-serif';
    ctx.fillStyle = s.stroke;
    ctx.fillText(s.label, cx, r.y + 18);

    // Version key — white, mono, prominent
    ctx.letterSpacing = "2px";
    ctx.font = 'bold 13px "Roboto Mono", ui-monospace, monospace';
    ctx.fillStyle = C.textPrimary;
    if (s.glow > 0) {
      ctx.shadowColor = s.stroke;
      ctx.shadowBlur = 8;
    }
    ctx.fillText(shortVersion(key).toUpperCase(), cx, r.y + r.h / 2 + 2);
    ctx.shadowBlur = 0;

    // Running count — muted, small
    ctx.letterSpacing = "1px";
    ctx.font = '600 9px "Inter", system-ui, sans-serif';
    ctx.fillStyle = C.textSecondary;
    ctx.fillText(sub.toUpperCase(), cx, r.y + r.h - 14);

    ctx.letterSpacing = "0px";
    ctx.restore();
  });
}

function systemBox(r: Rect, name: string): DrawFn {
  return (ctx) => {
    // fill
    ctx.save();
    chamferPath(ctx, r, CHAMFER);
    ctx.fillStyle = C.systemFill;
    ctx.fill();
    ctx.restore();

    // stroke with subtle glow
    ctx.save();
    ctx.shadowColor = C.systemStroke;
    ctx.shadowBlur = 6;
    chamferPath(ctx, r, CHAMFER);
    ctx.strokeStyle = C.systemStroke;
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.restore();

    // label
    ctx.save();
    ctx.letterSpacing = "1.5px";
    ctx.font = '600 11px "Inter", system-ui, sans-serif';
    ctx.fillStyle = "rgba(188, 236, 239, 0.75)";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(name.toUpperCase(), r.x + r.w / 2, r.y + r.h / 2);
    ctx.letterSpacing = "0px";
    ctx.restore();
  };
}

function diagramArrow(a: DiagramArrow): DrawFn {
  const mx = (a.from.x + a.to.x) / 2;
  const my = (a.from.y + a.to.y) / 2;
  const vertSign = Math.sign(a.to.y - a.from.y) || -1;

  return withAlpha(
    a.alpha ?? 1,
    compose(
      arrow(a.from, a.to, { stroke: C.arrowStroke, fill: C.arrowStroke, lineWidth: 0.75 }, 5),
      when(
        a.label.length > 0,
        label(a.label, mx + 6, my + vertSign * 14, {
          fill: C.textSecondary,
          font: '11px "Roboto Mono", ui-monospace, monospace',
          textAlign: "left",
          textBaseline: "middle",
        }),
      ),
    ),
  );
}

function dotColor(version: string, layout: DiagramLayout): string {
  const node = layout.versionNodes.find((n) => n.key === version);
  if (!node) return STATUS.draining.stroke;
  return STATUS[node.status].stroke;
}

export function drawDots(dots: Dot[], layout: DiagramLayout, now: number): DrawFn {
  return (ctx) => {
    for (const dot of dots) {
      const t = (now - dot.startTime) / TRAVEL_DURATION;
      if (t < 0 || t > 1) continue;

      const path = buildDotPath(layout, dot.version);
      if (!path) continue;

      const { x, y } = positionOnPath(path, t);
      if (insideRect(x, y, layout.cloudRect)) continue;

      const color = dotColor(dot.version, layout);
      ctx.save();
      ctx.shadowColor = color;
      ctx.shadowBlur = 8;
      ctx.beginPath();
      ctx.arc(x, y, 4, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
      ctx.restore();
    }
  };
}

function drawHUDCorners(w: number, h: number): DrawFn {
  const len = 18;
  const m = 14;
  const corners: [number, number][][] = [
    [
      [m, m + len],
      [m, m],
      [m + len, m],
    ],
    [
      [w - m - len, m],
      [w - m, m],
      [w - m, m + len],
    ],
    [
      [m, h - m - len],
      [m, h - m],
      [m + len, h - m],
    ],
    [
      [w - m - len, h - m],
      [w - m, h - m],
      [w - m, h - m - len],
    ],
  ];

  return (ctx) => {
    ctx.save();
    ctx.strokeStyle = "rgba(76, 190, 197, 0.45)";
    ctx.lineWidth = 1;

    for (const [a, b, c] of corners) {
      ctx.beginPath();
      ctx.moveTo(a[0], a[1]);
      ctx.lineTo(b[0], b[1]);
      ctx.lineTo(c[0], c[1]);
      ctx.stroke();
    }

    ctx.restore();
  };
}

function drawLegend(_w: number, h: number): DrawFn {
  const items = [
    { label: "ACTIVE", color: STATUS.active.stroke },
    { label: "RAMPING", color: STATUS.ramping.stroke },
    { label: "DRAINING", color: STATUS.draining.stroke },
    { label: "INACTIVE", color: STATUS.inactive.stroke },
  ];
  const x = 28;
  const lineH = 17;
  const baseY = h - 28 - (items.length - 1) * lineH;

  return (ctx) => {
    ctx.save();
    ctx.letterSpacing = "1px";
    ctx.font = '600 9px "Inter", system-ui, sans-serif';
    ctx.textBaseline = "middle";

    for (let i = 0; i < items.length; i++) {
      const { label: lbl, color } = items[i];
      const y = baseY + i * lineH;

      ctx.beginPath();
      ctx.arc(x, y, 3, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();

      ctx.fillStyle = "rgba(134, 149, 151, 0.65)";
      ctx.fillText(lbl, x + 10, y);
    }

    ctx.letterSpacing = "0px";
    ctx.restore();
  };
}

function drawSpaceBg(layout: DiagramLayout): DrawFn {
  const { canvasW: w, canvasH: h, clientRect, cloudRect } = layout;

  // Anchor glow positions to diagram elements so depth follows content
  const clientCx = clientRect.x + clientRect.w / 2;
  const clientCy = clientRect.y + clientRect.h / 2;
  const cloudCx = cloudRect.x + cloudRect.w / 2;
  const cloudCy = cloudRect.y + cloudRect.h / 2;
  const centerX = (clientCx + cloudCx) / 2;

  return (ctx) => {
    ctx.fillStyle = "#00181b";
    ctx.fillRect(0, 0, w, h);

    // Glow 1 — broad ambient behind diagram center
    const g1 = ctx.createRadialGradient(centerX, h * 0.5, 0, centerX, h * 0.5, w * 0.52);
    g1.addColorStop(0, "rgba(0, 132, 139, 0.10)");
    g1.addColorStop(1, "rgba(0, 0, 0, 0)");
    ctx.fillStyle = g1;
    ctx.fillRect(0, 0, w, h);

    // Glow 2 — tighter bloom under Temporal Client
    const g2 = ctx.createRadialGradient(clientCx, clientCy, 0, clientCx, clientCy, w * 0.22);
    g2.addColorStop(0, "rgba(4, 100, 106, 0.12)");
    g2.addColorStop(1, "rgba(0, 0, 0, 0)");
    ctx.fillStyle = g2;
    ctx.fillRect(0, 0, w, h);

    // Glow 3 — tighter bloom under Temporal Cloud
    const g3 = ctx.createRadialGradient(cloudCx, cloudCy, 0, cloudCx, cloudCy, w * 0.26);
    g3.addColorStop(0, "rgba(4, 100, 106, 0.10)");
    g3.addColorStop(1, "rgba(0, 0, 0, 0)");
    ctx.fillStyle = g3;
    ctx.fillRect(0, 0, w, h);

    // Edge vignette — pure dark at corners
    const vig = ctx.createRadialGradient(w * 0.5, h * 0.5, h * 0.3, w * 0.5, h * 0.5, h * 0.85);
    vig.addColorStop(0, "rgba(0,0,0,0)");
    vig.addColorStop(1, "rgba(0,0,0,0.55)");
    ctx.fillStyle = vig;
    ctx.fillRect(0, 0, w, h);
  };
}

export function drawDiagram(layout: DiagramLayout): DrawFn {
  const { canvasW, canvasH, clientRect, cloudRect, versionNodes, arrows } = layout;

  const clientToCloud: DiagramArrow = {
    from: { x: clientRect.x + clientRect.w, y: clientRect.y + clientRect.h / 2 },
    to: { x: cloudRect.x, y: cloudRect.y + cloudRect.h / 2 },
    label: "",
  };

  return compose(
    drawSpaceBg(layout),
    drawHUDCorners(canvasW, canvasH),
    systemBox(clientRect, "Temporal Client"),
    diagramArrow(clientToCloud),
    systemBox(cloudRect, "Temporal Cloud"),
    ...arrows.map(diagramArrow),
    ...versionNodes.map(versionBox),
    drawLegend(canvasW, canvasH),
  );
}
