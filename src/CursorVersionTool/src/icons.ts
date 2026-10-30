/** Inline SVG icons — Phosphor-like outline style, themed via currentColor */

const svg = (body: string, size = 22) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 256 256" fill="none" aria-hidden="true">${body}</svg>`;

const stroke = `stroke="currentColor" stroke-width="16" stroke-linecap="round" stroke-linejoin="round"`;

export const icons = {
  warn: svg(`
    <path ${stroke} d="M128 36 L228 212 H28 Z" />
    <path ${stroke} d="M128 104 v48" />
    <circle cx="128" cy="180" r="10" fill="currentColor" />
  `),

  confirm: svg(`
    <circle ${stroke} cx="128" cy="128" r="96" />
    <path ${stroke} d="M128 72 v72" />
    <circle cx="128" cy="176" r="10" fill="currentColor" />
  `),

  success: svg(`
    <circle ${stroke} cx="128" cy="128" r="96" />
    <path ${stroke} d="M84 132 l28 28 60-64" />
  `),

  error: svg(`
    <circle ${stroke} cx="128" cy="128" r="96" />
    <path ${stroke} d="M96 96 l64 64 M160 96 l-64 64" />
  `),

  info: svg(`
    <circle ${stroke} cx="128" cy="128" r="96" />
    <path ${stroke} d="M128 116 v56" />
    <circle cx="128" cy="84" r="10" fill="currentColor" />
  `),

  close: svg(`
    <path ${stroke} d="M72 72 l112 112 M184 72 L72 184" />
  `, 18),
} as const;

export type IconName = keyof typeof icons;
