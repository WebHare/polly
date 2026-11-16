/* Invoked by: python3 /absolute/path/to/polly/scripts/test-container.py
   Runs in a separate Node container; the ephemeral viewer password arrives on stdin. */
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
const password = await new Promise(resolve => {
  let input = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", part => { input += part; });
  process.stdin.on("end", () => resolve(input));
});
assert.ok(password.length >= 12);
const base = "http://polly:8088";
const authorization = `Basic ${Buffer.from(`viewer:${password}`).toString("base64")}`;
async function request(path, auth = authorization, method = "GET") {
  return fetch(base + path, {method, headers: auth ? {authorization: auth} : {}, redirect: "manual", signal: AbortSignal.timeout(5000)});
}
const deadline = performance.now() + 60000;
let snapshot;
while (performance.now() < deadline) {
  try {
    const response = await request("/api/status");
    if (response.ok) {
      snapshot = await response.json();
      if (snapshot.coverage.fresh === 1) break;
    }
  } catch {}
  await new Promise(resolve => setTimeout(resolve, 500));
}
assert.equal(snapshot?.coverage.fresh, 1, "Container did not poll the real mock");
assert.equal(snapshot.counts.hosts, 6);
assert.equal(snapshot.counts.services, 23);
for (const path of ["/", "/api/status", "/healthz", "/app.mjs", "/dashboard.css", "/fonts.css"]) {
  assert.equal((await request(path, null)).status, 401);
  const response = await request(path);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
}
assert.equal((await request("/", `Basic ${Buffer.from("viewer:wrong").toString("base64")}`)).status, 401);
for (const path of ["/run/secrets/polly.yaml", "/polly.yaml", "/viewer.hash", "/.git/config", "/__test__/fixtures.mjs", "/api/command"]) {
  assert.equal((await request(path)).status, 404);
}
for (const method of ["POST", "PUT", "PATCH", "DELETE"]) {
  assert.equal((await request("/api/status", authorization, method)).status, 405);
}
const publicDirectory = new URL("../Packages/PollyWeb/Sources/PollyWeb/Public/", import.meta.url);
let assets = 0;
for (const path of await readdir(publicDirectory, {recursive: true})) {
  if (path === "fonts") continue;
  const expected = await readFile(new URL(path, publicDirectory));
  const response = await request("/" + path);
  assert.equal(response.status, 200, path);
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), expected, `Served asset differs: ${path}`);
  if (path.endsWith(".woff2")) assert.equal(response.headers.get("content-type"), "font/woff2");
  assets++;
}
const body = JSON.stringify(snapshot);
for (const secret of [password, "nagiosadmin", "http://mock:"]) assert.ok(!body.includes(secret));
console.log(`✅ Separate-container HTTP: ${assets} exact assets, authenticated routes, real Nagios counts, no writes or private files.`);
