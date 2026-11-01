# Example prompts

Each file is a ready-to-use prompt. Run from your project directory:

```bash
/path/to/kiro-docker/run.sh -f /path/to/kiro-docker/examples/run-tests.md
```

| File | What it does |
| --- | --- |
| `run-tests.md` | Detects the stack, installs deps, runs tests, reports results |
| `fix-failing-tests.md` | Runs tests and fixes the code until they pass |
| `code-review.md` | Reviews the project and writes `REVIEW.md` |
| `write-docs.md` | Generates or improves the project README |

For a read-only run (agent cannot change your files), add `-r`.
