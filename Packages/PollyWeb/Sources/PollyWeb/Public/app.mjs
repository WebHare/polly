import { createDashboard } from "./dashboard.mjs";
import { motionAllowed } from "./presentation.mjs";
import { createPoller } from "./reliability.mjs";

export function initializeControls(document) {
  const root = document.documentElement;
  const theme = document.getElementById("theme");
  theme.addEventListener("click", () => {
    const light = root.dataset.theme !== "light";
    root.dataset.theme = light ? "light" : "dark";
    theme.setAttribute("aria-pressed", String(light));
    theme.textContent = light ? "Dark theme" : "Light theme";
  });
  const motion = document.getElementById("motion");
  const reduced = matchMedia("(prefers-reduced-motion: reduce)");
  let enabled = true;
  let inView = true;
  const updateMotion = () => {
    root.dataset.motion = motionAllowed({ enabled, reduced:reduced.matches, hidden:document.hidden, inView }) ? "on" : "off";
    motion.textContent = reduced.matches ? "Reduced motion" : enabled ? "Motion on" : "Motion off";
    motion.setAttribute("aria-pressed", String(enabled && !reduced.matches));
    motion.disabled = reduced.matches;
    document.dispatchEvent(new Event("pollymotionchange"));
  };
  motion.addEventListener("click", () => { enabled = !enabled; updateMotion(); });
  reduced.addEventListener("change", updateMotion);
  document.addEventListener("visibilitychange", updateMotion);
  const observer = new IntersectionObserver(entries => { inView = entries[0].isIntersecting; updateMotion(); });
  observer.observe(document.getElementById("mascot"));
  updateMotion();
}

export function startDashboard() {
  const dashboard = createDashboard(document);
  initializeControls(document);
  const poller = createPoller({onSnapshot:dashboard.render, onUnavailable:dashboard.disconnected});
  document.addEventListener("visibilitychange", () => poller.setVisible(!document.hidden));
  window.addEventListener("online", () => poller.retry());
  window.addEventListener("offline", () => poller.retry());
  window.addEventListener("pagehide", () => poller.stop());
  window.addEventListener("pageshow", () => poller.start());
  poller.setVisible(!document.hidden);
  poller.start();
}

// The preview imports the same controls; only the production entry point starts network polling.
if (document.querySelector('script[src="/app.mjs"]')) startDashboard();
