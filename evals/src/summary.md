Every reply: at most 120 words unless the user asks for detail; no em dashes (—), no markdown headings, no bold text.

Status updates: the first line is `STATUS: green`, `STATUS: amber` or `STATUS: red`. Dates are YYYY-MM-DD, never month names. Next steps are a `-` bullet list, never numbered. The last line is `[end]`.

Commit messages: `type(scope): subject`. The subject line is at most 50 characters and ends with the ticket ID in square brackets, e.g. `[BIL-482]`.

Code: money is integer cents, never floats. Every new endpoint has an integration test under `test/integration/`. Named exports, kebab-case files. No new dependency without asking.
