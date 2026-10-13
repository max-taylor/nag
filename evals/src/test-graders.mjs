#!/usr/bin/env node
// Runs every grader in graders/ against handwritten replies and checks each verdict, so a grader is trusted only once
// it passes a good reply and fails a bad one. Matching mirrors the eval runner: JS regex, `match: not_contains` inverts.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const GRADERS_DIR = join(import.meta.dirname, "graders");

const loadGrader = (path) => {
  const [, frontmatter, pattern] = readFileSync(path, "utf8").match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  const options = Object.fromEntries(frontmatter.split("\n").map((line) => line.split(/:\s*/, 2)));
  const regex = new RegExp(pattern, options.flags ?? "");
  return (reply) => regex.test(reply) === (options.match !== "not_contains");
};

const graders = Object.fromEntries(
  readdirSync(GRADERS_DIR).flatMap((group) =>
    readdirSync(join(GRADERS_DIR, group)).map((file) => [
      `${group}/${file.replace(/\.md$/, "")}`,
      loadGrader(join(GRADERS_DIR, group, file)),
    ]),
  ),
);

const GOOD_STATUS = `STATUS: green

Changed: the ledger export now streams, and the rate limiter moved to the gateway.

Milestones: Beta demo on 2026-11-14, Public launch on 2026-12-02.

Next steps:
- load-test the export
- migrate the remaining webhooks
- write the runbook

[end]`;

const GOOD_COMMIT = `fix(invoices): send idempotency key [BIL-482]

Invoice sync retries now send an idempotency key, so a retried request
can't charge a customer twice.`;

const GOOD_QUESTION = `If the first request reaches the payment provider but the response is lost, invoice sync sees a timeout and retries. The provider treats the retry as a new charge, so the customer pays twice. An idempotency key prevents it: the provider remembers the key and returns the original result instead of charging again.`;

// [description, reply, graders expected to fail; every other grader in the listed groups must pass]
const CASES = [
  ["good status", GOOD_STATUS, ["general", "status"], []],
  ["status wrapped in prose", `Here it is:\n\n${GOOD_STATUS}\n\nLet me know.`, ["status"], ["status/status-line", "status/end-line"]],
  ["status, month dates", GOOD_STATUS.replace("2026-11-14", "14 November 2026").replace("2026-12-02", "Dec 2, 2026"), ["status"], ["status/iso-dates", "status/no-month-dates"]],
  ["status, numbered steps", GOOD_STATUS.replace(/^- /gm, "1. "), ["status"], ["status/no-numbered-list"]],
  ["status, missing work", GOOD_STATUS.replace("runbook", "docs"), ["status"], ["status/task-done"]],
  ["status, styled", GOOD_STATUS.replace("Next steps:", "## Next steps — **soon**"), ["general"], ["general/no-em-dash", "general/no-headings", "general/no-bold"]],
  ["status, underscore bold", GOOD_STATUS.replace("Changed", "__Changed__"), ["general"], ["general/no-bold"]],
  ["month words that aren't dates", `${GOOD_STATUS}\nWe may 2x throughput; mark 3 tests flaky; decided 4 things.`, ["status"], ["status/end-line"]],
  ["good commit", GOOD_COMMIT, ["general", "commit"], []],
  ["commit in a fence after intro", `Here's the message:\n\n\`\`\`\n${GOOD_COMMIT}\n\`\`\``, ["commit"], []],
  ["commit, long subject", GOOD_COMMIT.replace("send idempotency key", "send an idempotency key on every retried request"), ["commit"], ["commit/subject-length"]],
  ["commit, no ticket", GOOD_COMMIT.replace(" [BIL-482]", ""), ["commit"], ["commit/ticket-suffix"]],
  ["commit, ticket prefix", GOOD_COMMIT.replace("fix(invoices): send idempotency key [BIL-482]", "BIL-482: send idempotency key"), ["commit"], ["commit/conventional", "commit/ticket-suffix"]],
  ["commit, no scope", GOOD_COMMIT.replace("fix(invoices)", "fix"), ["commit"], []],
  ["good question", GOOD_QUESTION, ["general", "question"], []],
  ["question with status format", `STATUS: green\n${GOOD_QUESTION}\n[end]`, ["question"], ["question/no-status-line", "question/no-end-line"]],
  ["question with commit line", `fix(sync): add idempotency key [BIL-482]\n\n${GOOD_QUESTION}`, ["question"], ["question/no-commit-line"]],
  ["question, off topic", "Retries are hard.", ["question"], ["question/task-done"]],
];

let failures = 0;
for (const [description, reply, groups, expectedFails] of CASES) {
  for (const [name, passes] of Object.entries(graders)) {
    if (!groups.includes(name.split("/")[0])) continue;
    const expected = !expectedFails.includes(name);
    if (passes(reply) !== expected) {
      failures += 1;
      console.log(`FAIL ${description}: ${name} should ${expected ? "pass" : "fail"}`);
    }
  }
}
console.log(`graders: ${CASES.length} replies, ${failures} wrong verdicts`);
process.exit(failures ? 1 : 0);
