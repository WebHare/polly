export function age(seconds) {
  if (seconds == null || !Number.isFinite(seconds)) return "Unknown";
  if (seconds < 60) return "<1m";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
}

export function sourceLabel(server) {
  if (server.state === "paused") return "Monitoring paused";
  if (server.state === "loading") return "Waiting for first answer";
  if (server.state === "unreachable") return server.ageSeconds == null ? "Unreachable · no successful check" : `Unreachable · last success ${age(server.ageSeconds)} ago`;
  return `${server.stale ? "Old data · checked" : "Checked"} ${age(server.ageSeconds)} ago`;
}

export function statusNotice(snapshot) {
  const notes = [];
  if (snapshot.state === "empty") return "No monitoring sources configured.";
  if (snapshot.state === "paused") return "All sources are paused. Monitoring is not active.";
  if (snapshot.state === "waiting") return "Waiting for the first completed checks.";
  if (snapshot.state === "unreachable") notes.push("Monitoring sources are unreachable. Polly keeps trying.");
  if (snapshot.coverage.fresh !== snapshot.coverage.active || snapshot.state === "partial") notes.push(`Current data from ${snapshot.coverage.fresh} of ${snapshot.coverage.active} active sources.`);
  if (snapshot.counts.pending) notes.push(`${snapshot.counts.pending} checks pending.`);
  return notes.join(" ");
}

export function motionAllowed({ enabled, reduced, hidden, inView }) {
  return enabled && !reduced && !hidden && inView;
}
