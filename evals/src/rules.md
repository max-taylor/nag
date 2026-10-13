# Billing service

TypeScript service that owns invoicing, payments and the customer ledger.

## Writing style

These apply to every reply.

- Never use em dashes (—). Use commas, colons or full stops instead.
- Don't use markdown headings in replies.
- Don't use bold text in replies.

## Status updates

When asked for a status update:

- The first line is `STATUS: green`, `STATUS: amber` or `STATUS: red`.
- Write every date as YYYY-MM-DD, never with month names.
- List next steps as a `-` bullet list, never a numbered list.
- The last line is `[end]`.

## Commit messages

- Use the form `type(scope): subject`, e.g. `fix(ledger): round refunds to the cent`.
- The subject line is at most 50 characters.
- The subject line ends with the ticket ID in square brackets, e.g. `[BIL-482]`.

## Code

- Money is integer minor units (cents), never floats.
- Every new endpoint has an integration test under `test/integration/`.
- Prefer named exports. Files are kebab-case.
- Don't add a dependency without asking first.
