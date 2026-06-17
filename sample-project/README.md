# sample-project — fixture for `check-req.py`

A minimal, self-contained stand-in for a real target checkout, so `check-req.py`
can be exercised without an external repo:

```bash
./check-req.py sample-project
```

It supplies only the **repo-local** artifacts the checker inspects under `repo_root`:

| Path | Satisfies |
|------|-----------|
| `env.sh` | the datasource / DB-name check (points at `/hello`, matching the default `--database`) |
| `sample.env.sh` | the template the `env.sh` fix copies from |
| `platform24-spa/node_modules/.package-lock.json` | the "deps installed" marker |
| `platform24-spa/node_modules/playwright-core/browsers.json` | the pinned Chromium revision |
| `platform24-bff/target/release/platform24-bff` | the prebuilt-binary probe (an inert stub — never executed) |
| `scripts/pixi.toml` | the pixi project config |

**What it can't fake:** the host-level checks (JDK, Node, Docker, Postgres, pixi,
system Python) inspect *the machine*, not this directory — their results reflect
your box. Likewise the Playwright **browser** itself lives in a global cache
(`~/.cache/ms-playwright`), not under `repo_root`, so that check still depends on
the host; only the *required revision* comes from here.

The directory names (`platform24-spa`, `platform24-bff`) mirror the layout
hardcoded in `lib/dev/` — see the `SPA_DIR` / `ENV_FILE` / `BFF_DIR` constants,
which are flagged for revision toward making the layout configurable.
