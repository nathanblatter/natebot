# CI/CD

- **Org:** github.com/nathanblatter
- **Runner:** Native macOS GitHub Actions runner on Mac Mini (launchd service at ~/actions-runner)
- **Deploy trigger:** Push to `main` branch
- **Deploy workflow:** `.github/workflows/deploy.yml` — checks out into the runner workspace (`~/actions-runner/_work`), builds with `swift build -c release --scratch-path ~/.natebot-scratch`, copies binary to `~/.local/bin/natebot`, restarts launchd daemon. Never build or clone under `~/Desktop`/`~/Documents` — iCloud Drive evicts files and git/swiftc fail with "Resource deadlock avoided" (EDEADLK on mmap of dataless files).
- **Secrets:** `~/.config/natebot/natebot.json` on host (natebot.json gitignored) — contains Claude API key, FinForge API key, passphrase
- **Infrastructure:** Native Swift daemon (not Docker), runs as launchd agent `com.natebot.daemon`
