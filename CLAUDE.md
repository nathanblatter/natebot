# CI/CD

- **Org:** github.com/nathanblatter
- **Runner:** Native macOS GitHub Actions runner on Mac Mini (launchd service at ~/actions-runner)
- **Deploy trigger:** Push to `main` branch
- **Deploy workflow:** `.github/workflows/deploy.yml` — pulls latest code in `/Users/nathanblatter/Desktop/natebot`, builds release binary with `swift build -c release`, copies to `~/.local/bin/natebot`, restarts launchd daemon
- **Secrets:** `~/.config/natebot/natebot.json` on host (natebot.json gitignored) — contains Claude API key, FinForge API key, passphrase
- **Infrastructure:** Native Swift daemon (not Docker), runs as launchd agent `com.natebot.daemon`
