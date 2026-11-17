/* node --test /absolute/path/to/polly/scripts/web/presentation.test.mjs */
import test from "node:test";
import assert from "node:assert/strict";
import { age, sourceLabel, statusNotice, motionAllowed } from "../../Packages/PollyWeb/Sources/PollyWeb/Public/presentation.mjs";

test("age keeps the largest unit, including missing and future measurements", () => {
  for (const [value, expected] of [[null, "Unknown"], [NaN, "Unknown"], [-2, "<1m"], [59, "<1m"], [60, "1m"], [3599, "59m"], [3600, "1h"], [86400, "1d"]]) assert.equal(age(value), expected);
});

test("source labels distinguish paused, waiting, unreachable, stale and fresh", () => {
  assert.equal(sourceLabel({state:"paused"}), "Monitoring paused");
  assert.equal(sourceLabel({state:"loading"}), "Waiting for first answer");
  assert.equal(sourceLabel({state:"unreachable",ageSeconds:20}), "Unreachable · last success <1m ago");
  assert.equal(sourceLabel({state:"ok",stale:true,ageSeconds:170}), "Old data · checked 2m ago");
  assert.equal(sourceLabel({state:"ok",stale:false,ageSeconds:20}), "Checked <1m ago");
});

test("coverage and pending warnings remain alongside critical problems", () => {
  const snapshot = {state:"problems", coverage:{active:2,fresh:1},counts:{pending:0}};
  assert.equal(statusNotice(snapshot), "Current data from 1 of 2 active sources.");
  assert.equal(statusNotice({...snapshot, coverage:{active:2,fresh:2}}), "");
  assert.equal(statusNotice({...snapshot, counts:{pending:3}}), "Current data from 1 of 2 active sources. 3 checks pending.");
});

test("all non-healthy empty states have an explicit explanation", () => {
  for (const state of ["empty", "paused", "waiting", "partial", "unreachable"]) assert.ok(statusNotice({state,coverage:{active:0,fresh:0},counts:{pending:0}}).length);
});

test("loops require user permission, visible tab and mascot, and no reduced motion", () => {
  const visible = {enabled:true,reduced:false,hidden:false,inView:true};
  assert.equal(motionAllowed(visible),true);
  for (const change of [{enabled:false},{reduced:true},{hidden:true},{inView:false}]) assert.equal(motionAllowed({...visible,...change}),false);
});
