/* Invoked by: python3 /absolute/path/to/polly/scripts/test-container.py
   Checks the rendered production container, with an ephemeral password on stdin. */
import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
const { chromium } = await import(process.env.POLLY_PLAYWRIGHT || "playwright");
let password = "";
for await (const part of process.stdin) password += part;
assert.ok(password.length >= 12 && process.env.POLLY_CONTAINER_URL);
const browser = await chromium.launch();
try {
  const page = await browser.newPage({httpCredentials: {username: "viewer", password}, viewport: {width: 1920, height: 1080}});
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(process.env.POLLY_CONTAINER_URL);
  await page.waitForFunction(() => document.querySelector("#connection")?.dataset.connected === "true");
  assert.ok((await page.locator("#sources").textContent()).includes("Container mock"));
  await page.evaluate(() => document.fonts.ready);
  const directory = process.env.POLLY_SCREENSHOTS || "/tmp/polly-container-screens";
  await mkdir(directory, {recursive: true});
  await page.screenshot({path: `${directory}/dark.png`});
  await page.getByRole("button", {name: "Light theme", exact: true}).click();
  await page.screenshot({path: `${directory}/light.png`});
  assert.deepEqual(errors, []);
  console.log(`✅ Production container rendered in Chromium ${browser.version()}, light and dark; no browser errors.`);
} finally {
  await browser.close();
}
