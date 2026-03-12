# NateBot

A native Swift macOS daemon that listens for iMessages from a trusted Apple ID, processes slash commands and natural language, and executes actions on macOS via the Claude API.

---

## Architecture

```
NateBot/
├── main.swift                  # Entry point — wires everything together
├── Claude/
│   └── ClaudeAPI.swift         # Raw HTTP client for Anthropic API
├── Config/
│   └── Config.swift            # JSON config loader & decodable structs
├── Watcher/
│   └── MessageWatcher.swift    # SQLite poller for ~/Library/Messages/chat.db
├── Router/
│   ├── CommandRouter.swift     # Deterministic slash-command parser
│   └── NLPRouter.swift         # Natural language → Claude → action JSON
├── Actions/
│   ├── CalendarAction.swift    # EventKit calendar (add, bulk parse)
│   ├── ReminderAction.swift    # EventKit reminders (add, bulk parse)
│   ├── StatusAction.swift      # HTTP health checks for registered apps
│   ├── SystemAction.swift      # CPU/RAM/disk stats, Docker, restarts
│   └── ReplyAction.swift       # osascript iMessage sender
├── Scheduler/
│   ├── ProactiveMonitor.swift  # App health, Docker, system monitors
│   └── MorningBriefing.swift   # Daily 07:00 briefing from EventKit
├── Log/
│   └── ActivityLog.swift       # JSON activity log (capped at max_entries)
└── Resources/
    └── natebot.json            # Config template
```

---

## Setup

### 1. Configure `natebot.json`

Edit `natebot/Resources/natebot.json` (or place it at `~/.config/natebot/natebot.json`):

```json
{
  "trusted_sender": "you@icloud.com",
  "passphrase": "yourpassphrase",
  "claude_api_key": "sk-ant-...",
  ...
}
```

**Config search order at startup:**
1. `<executable directory>/Resources/natebot.json`
2. `./Resources/natebot.json` (working directory)
3. `~/.config/natebot/natebot.json`
4. `~/Library/Application Support/NateBot/natebot.json`

### 2. Build with Xcode

1. Open `natebot.xcodeproj` in Xcode.
2. Add all new Swift files to the `natebot` target:
   - `Claude/ClaudeAPI.swift`
   - `Config/Config.swift`
   - `Watcher/MessageWatcher.swift`
   - `Router/CommandRouter.swift`
   - `Router/NLPRouter.swift`
   - `Actions/CalendarAction.swift`
   - `Actions/ReminderAction.swift`
   - `Actions/StatusAction.swift`
   - `Actions/SystemAction.swift`
   - `Actions/ReplyAction.swift`
   - `Scheduler/ProactiveMonitor.swift`
   - `Scheduler/MorningBriefing.swift`
   - `Log/ActivityLog.swift`
3. Link `libsqlite3.tbd` (target → Build Phases → Link Binary With Libraries → add `libsqlite3.tbd`).
4. Add `natebot.json` to the Copy Bundle Resources build phase.
5. Set Deployment Target to **macOS 14.0**.
6. Product → Archive, then export the binary.

**Or build from command line (Swift Package Manager):**
```bash
cd /Users/nathanblatter/Desktop/natebot
swift build -c release
# Binary: .build/release/natebot
```
(Requires `Package.swift` — create one if using SPM.)

### 3. Grant macOS Permissions

NateBot requires several permissions. Grant them **before** installing:

| Permission | Where | Why |
|---|---|---|
| **Full Disk Access** | System Settings → Privacy & Security → Full Disk Access | Read `~/Library/Messages/chat.db` |
| **Calendars** | System Settings → Privacy & Security → Calendars | Create/read events |
| **Reminders** | System Settings → Privacy & Security → Reminders | Create/read reminders |
| **Automation → Messages** | System Settings → Privacy & Security → Automation | Send iMessages via osascript |
| **Contacts** | May be prompted when Messages.app is first scripted | Required by osascript/Messages |

> **Tip:** Run NateBot manually from Terminal first so macOS prompts you for each permission. Only then install as a daemon.

### 4. Install Binary

```bash
# Copy the binary to a system location
sudo cp .build/release/natebot /usr/local/bin/natebot
sudo chmod +x /usr/local/bin/natebot
```

### 5. Copy Config

```bash
mkdir -p ~/.config/natebot
cp natebot/Resources/natebot.json ~/.config/natebot/natebot.json
# Edit with your real values:
nano ~/.config/natebot/natebot.json
```

### 6. Install launchd Agent

```bash
cp com.natebot.daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.natebot.daemon.plist
```

Verify it's running:
```bash
launchctl list | grep natebot
```

### 7. Test

Send yourself an iMessage from `trusted_sender`:
```
/help
```

You should receive a help message back within a few seconds.

---

## Command Reference

### Calendar
```
/cal add dentist Friday at 2pm
/cal add team standup tomorrow 9am 30min
/cal parse [paste a block of text with multiple events]
```

### Reminders
```
/remind call mom tomorrow
/remind submit assignment by Thursday midnight
/remind parse [paste a list of tasks or assignments]
```

### Status
```
/status               → all apps
/status survivorapp   → single app + stats
```

### System
```
/sys                          → CPU · RAM · Disk
/docker                       → Docker containers
/restart survivorapp pass123  → restart (passphrase required)
```

### Scheduler
```
/snooze 30m     → snooze alerts 30 minutes
/snooze 1h      → snooze 1 hour
/briefing       → morning briefing on demand
```

### Misc
```
/log    → last 10 activity entries
/help   → command reference
```

### Natural Language
Any message without a leading `/` is sent to Claude for interpretation:
```
add dentist friday at 2
remind me to call mom tomorrow
how are my apps doing
here's my assignment list: [...]
```

---

## Logs

- **Activity log:** `~/Library/Application Support/NateBot/activity.log`
- **stdout:** `/tmp/natebot.stdout.log`
- **stderr:** `/tmp/natebot.stderr.log`

```bash
tail -f /tmp/natebot.stdout.log
tail -f /tmp/natebot.stderr.log
```

## Stopping / Restarting

```bash
launchctl unload ~/Library/LaunchAgents/com.natebot.daemon.plist
launchctl load   ~/Library/LaunchAgents/com.natebot.daemon.plist
```

## Security Notes

- Only messages from `trusted_sender` are processed; all others are silently ignored.
- The passphrase is required for `/restart` and is never written to logs.
- `chat.db` is opened read-only.
- The Claude API key is read from config at startup and never logged.
