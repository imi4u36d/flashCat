import type { CSSProperties, ReactNode } from "react";

/* 图标：SF Symbols 的手绘等价物。统一 16×16 视框、1.4 描边、圆头圆角，
   与原生侧 `Image(systemName:)` 的视觉重量对齐。不引第三方图标库。 */

export type IconName =
  | "grid"
  | "bubble"
  | "stack"
  | "cpu"
  | "doc"
  | "slider"
  | "flask"
  | "panel"
  | "plus"
  | "chevron"
  | "copy"
  | "up"
  | "stop"
  | "sun"
  | "moon"
  | "gear"
  | "bolt"
  | "down";

const paths: Record<IconName, ReactNode> = {
  grid: (
    <>
      <rect x="1.75" y="1.75" width="5.5" height="5.5" rx="1.5" />
      <rect x="8.75" y="1.75" width="5.5" height="5.5" rx="1.5" />
      <rect x="1.75" y="8.75" width="5.5" height="5.5" rx="1.5" />
      <rect x="8.75" y="8.75" width="5.5" height="5.5" rx="1.5" />
    </>
  ),
  bubble: (
    <>
      <path d="M2.3 7.3c0-2.6 2.4-4.4 5.7-4.4s5.7 1.8 5.7 4.4-2.4 4.4-5.7 4.4c-.65 0-1.3-.05-1.9-.16L3.6 13.3l.5-1.95C3 10.5 2.3 9.1 2.3 7.3Z" />
    </>
  ),
  stack: (
    <>
      <path d="M8 1.9 2.7 4.6 8 7.3l5.3-2.7L8 1.9Z" />
      <path d="M2.7 7.8 8 10.5l5.3-2.7" />
      <path d="M2.7 11 8 13.7l5.3-2.7" />
    </>
  ),
  cpu: (
    <>
      <rect x="4.1" y="4.1" width="7.8" height="7.8" rx="1.8" />
      <rect x="6.6" y="6.6" width="2.8" height="2.8" rx="0.8" />
      <path d="M6.3 1.6v2.5M9.7 1.6v2.5M6.3 11.9v2.5M9.7 11.9v2.5M1.6 6.3h2.5M1.6 9.7h2.5M11.9 6.3h2.5M11.9 9.7h2.5" />
    </>
  ),
  doc: (
    <>
      <path d="M9.2 1.8H4.6c-.9 0-1.6.7-1.6 1.6v9.2c0 .9.7 1.6 1.6 1.6h6.8c.9 0 1.6-.7 1.6-1.6V5.4l-3.8-3.6Z" />
      <path d="M9 2v3.4h3.5" />
      <path d="M5.4 9h5.2M5.4 11.6h3.4" />
    </>
  ),
  slider: (
    <>
      <path d="M2 4.6h3.1M7.3 4.6h6.7M2 11.4h6.9M11.1 11.4h2.9" />
      <circle cx="6.2" cy="4.6" r="1.5" />
      <circle cx="10" cy="11.4" r="1.5" />
    </>
  ),
  flask: (
    <>
      <path d="M6.2 1.9h3.6M6.9 1.9v4.4L3.3 12.6c-.35.65.1 1.5.85 1.5h7.7c.75 0 1.2-.85.85-1.5L9.1 6.3V1.9" />
      <path d="M5.1 9.4h5.8" />
    </>
  ),
  panel: (
    <>
      <rect x="1.9" y="2.6" width="12.2" height="10.8" rx="2.2" />
      <path d="M6.4 2.6v10.8" />
    </>
  ),
  plus: <path d="M8 3.4v9.2M3.4 8h9.2" />,
  chevron: <path d="M4.4 6.3 8 9.7l3.6-3.4" />,
  copy: (
    <>
      <rect x="5.9" y="5.9" width="7.6" height="7.6" rx="1.8" />
      <path d="M10.6 5.9V4.1c0-.9-.7-1.6-1.6-1.6H4.1c-.9 0-1.6.7-1.6 1.6v4.9c0 .9.7 1.6 1.6 1.6h1.8" />
    </>
  ),
  up: <path d="M8 12.8V3.4M4.2 7.2 8 3.4l3.8 3.8" />,
  down: <path d="M8 3.2v9.4M4.2 8.8 8 12.6l3.8-3.8" />,
  stop: <rect x="4.7" y="4.7" width="6.6" height="6.6" rx="1.4" fill="currentColor" stroke="none" />,
  sun: (
    <>
      <circle cx="8" cy="8" r="3.1" />
      <path d="M8 1.4v1.7M8 12.9v1.7M1.4 8h1.7M12.9 8h1.7M3.4 3.4l1.2 1.2M11.4 11.4l1.2 1.2M12.6 3.4l-1.2 1.2M4.6 11.4l-1.2 1.2" />
    </>
  ),
  moon: <path d="M13.2 9.6A5.6 5.6 0 0 1 6.4 2.8a5.7 5.7 0 1 0 6.8 6.8Z" />,
  gear: (
    <>
      <circle cx="8" cy="8" r="2.2" />
      <path d="M8 1.9v1.6M8 12.5v1.6M1.9 8h1.6M12.5 8h1.6M3.7 3.7l1.1 1.1M11.2 11.2l1.1 1.1M12.3 3.7l-1.1 1.1M4.8 11.2l-1.1 1.1" />
    </>
  ),
  bolt: <path d="M9.1 1.7 4.4 9h3.1l-.7 5.3 4.8-7.4H8.4l.7-5.2Z" />,
};

export function Icon({
  name,
  size = 13,
  strokeWidth = 1.4,
  className,
  style,
}: {
  name: IconName;
  size?: number;
  strokeWidth?: number;
  className?: string;
  style?: CSSProperties;
}) {
  return (
    <svg
      className={className}
      style={style}
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name]}
    </svg>
  );
}
