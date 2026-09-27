// Живые обои: сама анимация рисуется телефоном (узел scene), скрипт только выбирает её и цвета и даёт время для часов.

const STYLES = ["aurora", "stars", "matrix", "waves", "bokeh", "lava"];
const PALETTES = {
  theme: null, // цвета текущей темы
  sunset: { colors: ["#1B0B2E", "#3D1030"], tints: ["#FF6B6B", "#FFB26B", "#C54BFF", "#FF4F9A"] },
  ocean: { colors: ["#021B2E", "#063A4F"], tints: ["#1FA2FF", "#12D8FA", "#3AF5C1", "#2E5BFF"] },
  forest: { colors: ["#07140C", "#10261A"], tints: ["#3CCB6E", "#9BE15D", "#1E8C5A", "#D4F078"] },
  neon: { colors: ["#07010F", "#12002B"], tints: ["#FF2BD6", "#00F0FF", "#8A2BFF", "#FFE600"] },
  mono: { colors: ["#050505", "#141414"], tints: ["#FFFFFF", "#9A9A9A", "#5C5C5C"] },
};
const MONTHS = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"];
const DAYS = ["воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота"];

async function refresh(ctx) {
  const s = ctx.settings;
  const style = STYLES.includes((s.style || "").trim()) ? s.style.trim() : "aurora";
  const palette = PALETTES[(s.palette || "theme").trim()] ?? null;
  const now = new Date();
  return {
    kind: style,
    colors: palette ? palette.colors : null,
    tints: palette ? palette.tints : null,
    speed: Math.min(3, Math.max(0.2, Number(s.speed) || 1)),
    clock: !/^(no|нет|0|false)$/i.test((s.clock || "yes").trim()),
    time: `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`,
    date: `${DAYS[now.getDay()]}, ${now.getDate()} ${MONTHS[now.getMonth()]}`,
  };
}
