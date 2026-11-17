import { createDashboard } from "/dashboard.mjs";
import { initializeControls } from "/app.mjs";
import { fixtures } from "/__test__/fixtures.mjs";
const dashboard = createDashboard(document);
initializeControls(document);
const params = new URLSearchParams(location.search);
const name = params.get("state") ?? "critical";
if (!Object.hasOwn(fixtures, name)) throw new Error("Unknown fixture");
dashboard.render(fixtures[name]);
