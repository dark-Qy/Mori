# Security Policy

Watch Companion handles sensitive health context. Security and privacy defects are product defects, even when they do not enable conventional code execution.

## Supported versions

The project is pre-release. Security fixes are applied only to the latest development branch until a release support policy is published.

## Reporting a vulnerability

Do not file a public issue containing a vulnerability, secret, health record, personal conversation, or reproduction data tied to a real person.

Use the repository host's private security-advisory feature when available. If it is not available, contact the maintainers through a private channel listed on the project owner profile and request a secure reporting address before sending details.

Include:

- affected revision and component;
- impact and prerequisite permissions;
- minimal synthetic reproduction steps;
- whether credentials or personal data may have been exposed;
- suggested mitigation, if known.

Maintainers should acknowledge a report within seven days, provide an initial assessment within fourteen days, and coordinate disclosure after a fix is available. Timelines may change for platform-dependent issues, but reporters should receive an update.

## Sensitive-data expectations

- Use synthetic fixtures in tests and issue reports.
- Keep HealthKit samples on device unless a documented feature requires bounded server processing and the user has explicitly consented.
- Minimize fields and time windows sent to a server or narration provider.
- Never use health data for advertising, data brokerage, or unrelated profiling.
- Redact secrets and health payloads from diagnostics, crash metadata, analytics, screenshots, and AI request logs.
- Delete server-side request bodies after processing unless a documented retention policy and user-facing purpose require storage.
- Apply access control and data-owner checks independently in both directions of a friendship.

## Secret handling

Provider keys belong only in the server-side environment or an approved secret manager. The iPhone and Watch binaries are public clients and cannot safely contain shared secrets.

Any credential pasted into chat, an issue, a commit, a screenshot, or application logs must be considered compromised and rotated. Removing it from the latest commit is not sufficient; purge it from history where appropriate and review provider access logs.

## AI trust boundary

AI output is untrusted. Validate it against a strict schema and content rules. The narration model must not:

- modify growth, inventory, quests, commitments, relationships, or story facts;
- bypass quiet hours, notification budgets, consent, or sharing scopes;
- diagnose, label a health measurement as abnormal, or prescribe treatment;
- perform social actions on a user's behalf.

When validation, the provider, or the network fails, return a deterministic local template without changing authoritative state.
