// Live wallpaper: the phone draws the animation itself (the scene node); the script only picks it and its colours and gives the time for the clock.

const STYLES = ["aurora", "stars", "matrix", "waves", "bokeh", "lava", "snow", "rain", "gradient"];
const PALETTES = {
  theme: null, // the current theme's colours
  sunset: { colors: ["#1B0B2E", "#3D1030"], tints: ["#FF6B6B", "#FFB26B", "#C54BFF", "#FF4F9A"] },
  ocean: { colors: ["#021B2E", "#063A4F"], tints: ["#1FA2FF", "#12D8FA", "#3AF5C1", "#2E5BFF"] },
  forest: { colors: ["#07140C", "#10261A"], tints: ["#3CCB6E", "#9BE15D", "#1E8C5A", "#D4F078"] },
  neon: { colors: ["#07010F", "#12002B"], tints: ["#FF2BD6", "#00F0FF", "#8A2BFF", "#FFE600"] },
  mono: { colors: ["#050505", "#141414"], tints: ["#FFFFFF", "#9A9A9A", "#5C5C5C"] },
  winter: { colors: ["#0B1426", "#1C2B4A"], tints: ["#FFFFFF", "#CFE3FF", "#9CC3FF"] },
  storm: { colors: ["#0E1319", "#1F2833"], tints: ["#9DB4CC", "#C9D6E3", "#6F8BA6"] },
};
// "auto": the theme's colours, but winter ones for snow and storm ones for rain.
const AUTO = { snow: "winter", rain: "storm" };

async function refresh(ctx) {
  const s = ctx.settings;
  const style = STYLES.includes((s.style || "").trim()) ? s.style.trim() : "aurora";
  const choice = (s.palette || "auto").trim();
  const palette = PALETTES[choice === "auto" ? AUTO[style] || "theme" : choice] ?? null;
  const now = new Date();
  return {
    kind: style,
    colors: palette ? palette.colors : null,
    tints: palette ? palette.tints : null,
    speed: Math.min(3, Math.max(0.2, Number(s.speed) || 1)),
    clock: !/^(no|off|нет|0|false)$/i.test((s.clock || "yes").trim()),
    time: format.time(now),
    date: format.date(now, "weekday"),
  };
}
