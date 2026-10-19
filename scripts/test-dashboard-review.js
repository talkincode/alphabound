#!/usr/bin/env node
// Tests for the review-chart pure logic embedded in dashboard/index.html.
// Run: node scripts/test-dashboard-review.js
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const htmlPath = path.join(__dirname, "..", "dashboard", "index.html");
const html = fs.readFileSync(htmlPath, "utf8");

const BEGIN = "/* REVIEW-CHART-LOGIC-BEGIN */";
const END = "/* REVIEW-CHART-LOGIC-END */";
const start = html.indexOf(BEGIN);
const end = html.indexOf(END);
if (start < 0 || end <= start) {
  console.error("review chart logic markers not found in dashboard/index.html");
  process.exit(1);
}

const source = html.slice(start + BEGIN.length, end);
const api = vm.runInContext(
  "(function () {\n" + source +
    "\nreturn { lastBarIndex, snapBar, computeReviewViewport, RV_DEFAULT_VISIBLE_BARS, RV_RIGHT_OFFSET };\n})()",
  vm.createContext({})
);
const { lastBarIndex, snapBar, computeReviewViewport } = api;

let failed = 0;
function test(name, fn) {
  try {
    fn();
    console.log("ok - " + name);
  } catch (err) {
    failed++;
    console.error("not ok - " + name);
    console.error(err && err.stack ? err.stack : err);
  }
}
function eq(actual, expected, message) {
  // Objects created inside the vm realm have a different Object.prototype,
  // so compare value-only copies.
  const normalized = JSON.parse(JSON.stringify(actual));
  if (message === undefined) assert.deepStrictEqual(normalized, expected);
  else assert.deepStrictEqual(normalized, expected, message);
}

test("default viewport shows the last 100 bars plus right offset", () => {
  eq(computeReviewViewport(180, [], null, 0, true, null), {
    range: { from: 80, to: 182 },
    needFit: false,
    defaulted: true,
  });
});

test("default viewport clamps to the first bar when data is short", () => {
  eq(computeReviewViewport(60, [], null, 0, true, null), {
    range: { from: 0, to: 62 },
    needFit: false,
    defaulted: true,
  });
});

test("polling preserves a user zoom/pan range", () => {
  eq(computeReviewViewport(180, [], { from: 40, to: 140 }, 180, false, null), {
    range: { from: 40, to: 140 },
    needFit: false,
    defaulted: false,
  });
});

test("appended bars shift the range only when pinned to the right edge", () => {
  eq(computeReviewViewport(181, [], { from: 80, to: 182 }, 180, false, null), {
    range: { from: 81, to: 183 },
    needFit: false,
    defaulted: false,
  });
  eq(computeReviewViewport(181, [], { from: 40, to: 140 }, 180, false, null), {
    range: { from: 40, to: 140 },
    needFit: false,
    defaulted: false,
  });
});

test("1D decisions snap to OKX UTC+8 opens without assuming UTC alignment", () => {
  const day = 86400;
  const open = 57600; // 16:00 UTC == 00:00 UTC+8
  const times = [open, open + day, open + 2 * day];
  eq(snapBar(times, open, day), open);
  eq(snapBar(times, open + day - 1, day), open);
  eq(snapBar(times, open + day, day), open + day);
  eq(snapBar(times, open + 3 * day, day), null);
  eq(snapBar(times, open - 1, day), null);
});

test("snapBar treats bars as half-open [open, open + barSec)", () => {
  const times = [0, 1800, 3600];
  eq(snapBar(times, 0, 900), 0);
  eq(snapBar(times, 899, 900), 0);
  eq(snapBar(times, 900, 900), null); // gap: no 15m candle at this minute
  eq(snapBar(times, 1799, 900), null);
  eq(snapBar(times, 1800, 900), 1800);
  eq(snapBar(times, 3600 + 900, 900), null);
});

test("lastBarIndex handles empty, exact, and invalid inputs", () => {
  eq(lastBarIndex([], 1), -1);
  eq(lastBarIndex([10, 20, 30], 9), -1);
  eq(lastBarIndex([10, 20, 30], 10), 0);
  eq(lastBarIndex([10, 20, 30], 25), 1);
  eq(lastBarIndex([10, 20, 30], 30), 2);
  eq(lastBarIndex([10, 20, 30], null), -1);
  eq(lastBarIndex([10, 20, 30], NaN), -1);
});

test("selecting an off-screen decision centers its bar", () => {
  const times = Array.from({ length: 200 }, (_, i) => i * 900);
  const plan = computeReviewViewport(
    200, times, { from: 0, to: 100 }, 200, false, 150 * 900
  );
  eq(plan.range, { from: 100, to: 200 });
});

test("selecting a visible decision does not move the viewport", () => {
  const times = Array.from({ length: 200 }, (_, i) => i * 900);
  const plan = computeReviewViewport(
    200, times, { from: 0, to: 100 }, 200, false, 50 * 900
  );
  eq(plan.range, { from: 0, to: 100 });
});

test("centering on the default window keeps the span", () => {
  const times = Array.from({ length: 200 }, (_, i) => i * 900);
  const plan = computeReviewViewport(
    200, times, null, 0, true, 20 * 900
  );
  eq(plan.range, { from: -31, to: 71 });
});

test("AB-to-review time-scale subscription is removed", () => {
  assert(!/abChart\.timeScale\(\)\.subscribeVisibleTimeRangeChange/.test(html),
    "AB chart must not write its visible range back into the review chart");
  assert(/reviewChart\.timeScale\(\)\.subscribeVisibleTimeRangeChange/.test(html),
    "review -> AB single-direction link should remain");
});

test("updateReviewChart never calls fitContent directly", () => {
  const fnStart = html.indexOf("function updateReviewChart()");
  const fnEnd = html.indexOf("\nfunction ", fnStart + 10);
  assert(fnStart >= 0 && fnEnd > fnStart, "updateReviewChart not found");
  const body = html.slice(fnStart, fnEnd);
  assert(!body.includes("fitContent()"), "polling must not reset the viewport");
  assert(body.includes("applyReviewViewport("), "viewport helper must be used");
});

if (failed) {
  console.error(failed + " test(s) failed");
  process.exit(1);
}
console.log("all review-chart logic tests passed");
