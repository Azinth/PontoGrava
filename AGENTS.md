# Repository instructions

## Local validation

- Run the relevant checks locally after every change.
- For Swift or app changes, run `./scripts/test.sh` and `swift build`.
- For Discord helper changes, also run `npm test --prefix DiscordBot`.
- For documentation-only changes, run `git diff --check` and validate any changed links or commands.
- Do not claim that a change was validated when a required local check failed or could not run; report the limitation instead.

## GitHub Actions

- Local checks are the completion gate for a task. When the relevant local checks pass, the task may be marked complete.
- Do not wait for, poll, or monitor GitHub Actions before reporting a task as complete.
- Treat GitHub Actions as an asynchronous confirmation of the same checks already run locally.
- If a GitHub Actions result is already available without waiting, it may be mentioned, but it is not required for task completion.
