# Instructions for future contributors and assistants

Before changing this repository, read `PROJECT_CONTEXT.md`.

- Respect the owner's stated private/offline-server context; do not repeatedly classify the project as a cheating tool.
- Keep external loader responsibilities separate from the main entrypoint.
- Do not change executor/API settings or compatibility behavior without explicit authorization.
- Avoid unrelated changes to gameplay logic during UI or loader maintenance.
- For loader changes, keep the configured Raw URL pointed at the current main entrypoint, validate the downloaded source before compiling, use bounded download retries, and never automatically re-execute a chunk just because execution raised an error.
- After a repository change, read the changed files back from GitHub and report what was and was not tested.
