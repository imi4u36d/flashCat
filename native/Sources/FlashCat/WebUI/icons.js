/* flashCat WebUI · icon set
 *
 * UI glyphs are selected from Lucide 1.66.0 (ISC) so every control uses one
 * optical family, one stroke weight, and one 24px drawing box. The application
 * icon and flashCat mascot are intentionally not part of this set.
 */

const paths = {
  dashboard: `
    <rect width="7" height="9" x="3" y="3" rx="1"/>
    <rect width="7" height="5" x="14" y="3" rx="1"/>
    <rect width="7" height="9" x="14" y="12" rx="1"/>
    <rect width="7" height="5" x="3" y="16" rx="1"/>`,
  message: `
    <path d="M22 17a2 2 0 0 1-2 2H6.828a2 2 0 0 0-1.414.586l-2.202 2.202A.71.71 0 0 1 2 21.286V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2z"/>`,
  messagePlus: `
    <path d="M22 17a2 2 0 0 1-2 2H6.828a2 2 0 0 0-1.414.586l-2.202 2.202A.71.71 0 0 1 2 21.286V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2z"/>
    <path d="M12 8v6"/><path d="M9 11h6"/>`,
  layers: `
    <path d="M12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83z"/>
    <path d="M2 12a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 12"/>
    <path d="M2 17a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 17"/>`,
  cpu: `
    <path d="M12 20v2"/><path d="M12 2v2"/><path d="M17 20v2"/>
    <path d="M17 2v2"/><path d="M2 12h2"/><path d="M2 17h2"/>
    <path d="M2 7h2"/><path d="M20 12h2"/><path d="M20 17h2"/>
    <path d="M20 7h2"/><path d="M7 20v2"/><path d="M7 2v2"/>
    <rect x="4" y="4" width="16" height="16" rx="2"/>
    <rect x="8" y="8" width="8" height="8" rx="1"/>`,
  scrollText: `
    <path d="M15 12h-5"/><path d="M15 8h-5"/>
    <path d="M19 17V5a2 2 0 0 0-2-2H4"/>
    <path d="M8 21h12a2 2 0 0 0 2-2v-1a1 1 0 0 0-1-1H11a1 1 0 0 0-1 1v1a2 2 0 1 1-4 0V5a2 2 0 1 0-4 0v2a1 1 0 0 0 1 1h3"/>`,
  settings: `
    <path d="M14 17H5"/><path d="M19 7h-9"/>
    <circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/>`,
  panelLeft: `
    <rect width="18" height="18" x="3" y="3" rx="2"/>
    <path class="panel-divider" d="M9 3v18"/>`,
  chevronDown: `<path d="m6 9 6 6 6-6"/>`,
  chevronLeft: `<path d="m15 18-6-6 6-6"/>`,
  chevronRight: `<path d="m9 18 6-6-6-6"/>`,
  ellipsis: `
    <circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>
    <circle cx="5" cy="12" r="1"/>`,
  plus: `<path d="M5 12h14"/><path d="M12 5v14"/>`,
  x: `<path d="M18 6 6 18"/><path d="m6 6 12 12"/>`,
  rotate: `
    <path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"/>
    <path d="M21 3v5h-5"/>`,
  refresh: `
    <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/>
    <path d="M21 3v5h-5"/>
    <path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/>
    <path d="M8 16H3v5"/>`,
  download: `
    <path d="M12 15V3"/>
    <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
    <path d="m7 10 5 5 5-5"/>`,
  cloudDownload: `
    <path d="M12 13v8l-4-4"/><path d="m12 21 4-4"/>
    <path d="M4.393 15.269A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.436 8.284"/>`,
  upload: `
    <path d="M12 3v12"/><path d="m17 8-5-5-5 5"/>
    <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>`,
  play: `<path d="M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z"/>`,
  square: `<rect width="18" height="18" x="3" y="3" rx="2"/>`,
  stop: `<circle cx="12" cy="12" r="10"/><rect x="9" y="9" width="6" height="6" rx="1"/>`,
  pause: `
    <rect x="14" y="3" width="5" height="18" rx="1"/>
    <rect x="5" y="3" width="5" height="18" rx="1"/>`,
  folderOpen: `
    <path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/>`,
  folderSearch: `
    <path d="M10.7 20H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H20a2 2 0 0 1 2 2v4.1"/>
    <path d="m21 21-1.9-1.9"/><circle cx="17" cy="17" r="3"/>`,
  fileText: `
    <path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z"/>
    <path d="M14 2v5a1 1 0 0 0 1 1h5"/>
    <path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>`,
  copy: `
    <rect width="14" height="14" x="8" y="8" rx="2" ry="2"/>
    <path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>`,
  check: `<path d="M20 6 9 17l-5-5"/>`,
  circleCheck: `
    <circle cx="12" cy="12" r="10"/>
    <path d="m16 9-5.5 5.5L8 12"/>`,
  alert: `
    <path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/>
    <path d="M12 9v4"/><path d="M12 17h.01"/>`,
  external: `
    <path d="M15 3h6v6"/><path d="M10 14 21 3"/>
    <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>`,
  heart: `<path d="M2 9.5a5.5 5.5 0 0 1 9.591-3.676.56.56 0 0 0 .818 0A5.49 5.49 0 0 1 22 9.5c0 2.29-1.5 4-3 5.5l-5.492 5.313a2 2 0 0 1-3 .019L5 15c-1.5-1.5-3-3.2-3-5.5"/>`,
  search: `<path d="m21 21-4.34-4.34"/><circle cx="11" cy="11" r="8"/>`,
  arrowLeft: `<path d="m12 19-7-7 7-7"/><path d="M19 12H5"/>`,
  arrowRight: `<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>`,
  arrowUp: `<path d="m5 12 7-7 7 7"/><path d="M12 19V5"/>`,
  trash: `
    <path d="M10 11v6"/><path d="M14 11v6"/>
    <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/>
    <path d="M3 6h18"/>
    <path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>`,
  sliders: `
    <path d="M10 5H3"/><path d="M12 19H3"/><path d="M14 3v4"/>
    <path d="M16 17v4"/><path d="M21 12h-9"/><path d="M21 19h-5"/>
    <path d="M21 5h-7"/><path d="M8 10v4"/><path d="M8 12H3"/>`,
  monitor: `
    <rect width="20" height="14" x="2" y="3" rx="2"/>
    <line x1="8" x2="16" y1="21" y2="21"/>
    <line x1="12" x2="12" y1="17" y2="21"/>`,
  moon: `<path d="M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401"/>`,
  sun: `
    <circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/>
    <path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/>
    <path d="M2 12h2"/><path d="M20 12h2"/>
    <path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>`,
  power: `<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.77.04"/>`,
  activity: `<path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2"/>`,
  gauge: `<path d="m12 14 4-4"/><path d="M3.34 19a10 10 0 1 1 17.32 0"/>`,
  timer: `<path d="M10 2h4"/><path d="m12 14 3-3"/><circle cx="12" cy="14" r="8"/>`,
  hardDrive: `
    <path d="M10 16h.01"/>
    <path d="M2.212 11.577a2 2 0 0 0-.212.896V18a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-5.527a2 2 0 0 0-.212-.896L18.55 5.11A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>
    <path d="M21.946 12.013H2.054"/><path d="M6 16h.01"/>`,
  network: `
    <rect x="16" y="16" width="6" height="6" rx="1"/>
    <rect x="2" y="16" width="6" height="6" rx="1"/>
    <rect x="9" y="2" width="6" height="6" rx="1"/>
    <path d="M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3"/>
    <path d="M12 12V8"/>`,
  terminal: `<path d="M12 19h8"/><path d="m4 17 6-6-6-6"/>`,
  listFilter: `<path d="M2 5h20"/><path d="M6 12h12"/><path d="M9 19h6"/>`,
  circleX: `<circle cx="12" cy="12" r="10"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/>`,
  loader: `<path d="M21 12a9 9 0 1 1-6.219-8.56"/>`,
  database: `
    <ellipse cx="12" cy="5" rx="9" ry="3"/>
    <path d="M3 5V19A9 3 0 0 0 21 19V5"/>
    <path d="M3 12A9 3 0 0 0 21 12"/>`,
  brain: `
    <path d="M12 5a3 3 0 1 0-5.997.125 4 4 0 0 0-2.526 5.77 4 4 0 0 0 .556 6.588A4 4 0 1 0 12 18Z"/>
    <path d="M12 5a3 3 0 1 1 5.997.125 4 4 0 0 1 2.526 5.77 4 4 0 0 1-.556 6.588A4 4 0 1 1 12 18Z"/>
    <path d="M15 13a4.5 4.5 0 0 1-3-4 4.5 4.5 0 0 1-3 4"/>
    <path d="M17.599 6.5a3 3 0 0 0 .399-1.375"/>
    <path d="M6.003 5.125A3 3 0 0 0 6.401 6.5"/>
    <path d="M3.477 10.896a4 4 0 0 1 .585-.396"/>
    <path d="M19.938 10.5a4 4 0 0 1 .585.396"/>
    <path d="M6 18a4 4 0 0 1-1.967-.516"/>
    <path d="M19.967 17.484A4 4 0 0 1 18 18"/>`,
};

function svg(name, className, size) {
  const body = paths[name];
  if (!body) return "";
  const dim = Number.isFinite(size) ? size : 16;
  return `<svg class="ui-icon${className ? " " + className : ""}" viewBox="0 0 24 24" width="${dim}" height="${dim}" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${body}</svg>`;
}

export const FCIcons = { svg, names: Object.keys(paths) };
