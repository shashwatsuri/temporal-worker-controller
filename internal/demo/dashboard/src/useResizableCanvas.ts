import { useEffect, useRef, useState } from "react";

export function useResizableCanvas() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [size, setSize] = useState({ w: 800, h: 600 });

  useEffect(() => {
    const update = () => {
      const canvas = canvasRef.current;
      if (canvas) {
        const { width, height } = canvas.getBoundingClientRect();
        setSize({ w: width, h: height });
      }
    };

    update();
    window.addEventListener("resize", update);
    return () => window.removeEventListener("resize", update);
  }, []);

  return { canvasRef, size };
}
