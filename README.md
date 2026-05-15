# s3player-app

A SwiftUI iOS/macOS client for the [s3player](./tmp/s3player) backend — a single-password-gated audio service that indexes radio show recordings stored in S3 and exposes a JSON API for browse and playback.

The native app mirrors the web frontend's UX (Stations → Shows → Year/Month → Episodes → Player) with iOS-native niceties: lock-screen Now Playing, background audio, single-active-session playback with takeover, and resume on entry.

## Requirements

- Xcode 26.x (deployment target iOS 26.2 / macOS 14).
- A reachable s3player backend (e.g. `https://s3player.local.168234.xyz` or a local `http://localhost:47653`).
- The site password configured on that backend.

## Setup

The project reads `DEVELOPMENT_TEAM` from `Developer.xcconfig`, which is gitignored so each developer can use their own Apple Developer Team ID. After cloning:

```sh
cp Developer.xcconfig.sample Developer.xcconfig
# edit Developer.xcconfig and set DEVELOPMENT_TEAM = <YOUR_TEAM_ID>
```

Find your Team ID in **Xcode → Settings → Accounts → (your account) → manage Certificates / team list**, or on [developer.apple.com](https://developer.apple.com/account) under Membership Details. If you already have an Apple-issued signing cert in your keychain, this also prints the team ID and name:

```sh
security find-certificate -a -c "Apple Development" -p \
  | while openssl x509 -noout -subject 2>/dev/null; do :; done
# subject= ... OU=<TEAM_ID>, O=<TEAM_NAME>, ...
```

## Running

Open `s3player-app.xcodeproj` and either:

- **Simulator / Mac:** select the destination, press ▶.
- **Physical iPad/iPhone:** plug the device in, select it as the destination, ▶. Personal-team dev installs expire after 7 days; re-run to refresh.

Or via CLI — boot a simulator, build, install, and launch:

```sh
SIM="iPhone 17"
xcrun simctl boot "$SIM" 2>/dev/null || true

xcodebuild \
  -project s3player-app.xcodeproj \
  -scheme s3player-app \
  -destination "platform=iOS Simulator,name=$SIM" \
  -configuration Debug \
  -derivedDataPath build/derived \
  build CODE_SIGNING_ALLOWED=NO

APP=build/derived/Build/Products/Debug-iphonesimulator/s3player-app.app
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
open -a Simulator
```

To compile only (no install/launch), drop the last four lines and use `-destination 'generic/platform=iOS Simulator'`.

## Sign-in

The first screen asks for **Host** and **Password**. Host is the backend base URL (e.g. `https://s3player.local.168234.xyz`); password is the site password configured on the server. The bearer token returned by `POST /api/auth/login` is stored in `UserDefaults` and reused on subsequent launches. **Sign Out** in the home toolbar clears it.

## Features

### Browse

- **Home (`StationsView`)** — three sections, in order, hidden when empty:
  - **Continue listening** — incomplete episodes from `GET /api/player/in-progress`, with a horizontal rail of cards showing show name, date, time slot, and a position/duration progress bar.
  - **Recently played** — completed episodes from `GET /api/player/recent`, with a "Played" badge.
  - **Stations** — list rows linking into the per-station show list.
  - Rails refresh whenever the home screen reappears (e.g. when popping back from the player); pull-to-refresh refreshes everything.
- Drilling: `ShowsView` → `MonthsView` (year-grouped sections, months as `01`…`12`) → `EpisodesView` (rows with `yyyy-MM-dd` date + `HH:MM–HH:MM` time slot).
- Tapping an episode in `EpisodesView` opens an episode details screen first, which loads chapter data from `GET /api/shows/episodes/{id}` and exposes a **Play Episode** CTA.
- Tapping a Home rail card still swaps straight into the player.

### Player

- The episode details screen calls `GET /api/shows/episodes/{id}` to show chapter metadata before playback starts.
- Calls `GET /api/shows/episodes/{id}/audio_url` for a presigned S3 URL and feeds it to `AVPlayer`.
- Reads `GET /api/player/episodes/{id}/progress` on entry; if not completed, auto-seeks to the saved position.
- Transport controls: `−15s` / Play-Pause / `+30s`, plus a draggable scrubber and elapsed-of-total time.
- **Lock screen / Control Center / AirPlay** show the same metadata and controls via `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`. `UIBackgroundModes = audio` (in `Info.plist`) lets playback continue when the app is backgrounded or the device is locked.

### Player session (single active session globally)

The backend allows exactly one active player session at a time. The app:

- Mints a session token on first explicit Play (`POST /api/player/session/claim`) and stores it in `UserDefaults`.
- Sends `X-Player-Session: <token>` only on session-protected writes (`validate`, `progress`, `complete`).
- On app launch with a stored token, **blocks** the UI on a single `validate` call (8s timeout). On 409 the token is cleared silently; on transient/timeout the user gets a **Retry** / **Clear and Continue** screen; on 401 the bearer token is invalid and the user is logged out.
- Once authenticated, a 30s background heartbeat re-validates so a displacement caused by another device propagates without user interaction. When the active `PlayerView` observes the token going to `nil`, it pauses and switches to **Take Over Playback**.
- Periodic 5s `progress` writes during playback, plus on pause / scrubber drag-end / view exit / natural end. A natural end also fires `POST /api/player/episodes/{id}/complete`.

## Architecture

| File | Role |
| --- | --- |
| `s3player-app/s3player_appApp.swift` | App entry. Picks `LoginView` / `SessionValidationView` / `ContentView` based on `AuthViewModel` state. |
| `s3player-app/AuthViewModel.swift` | Bearer token + player session token storage; launch-time validation with timeout + retry/clear UI; 30s heartbeat. |
| `s3player-app/LoginView.swift` | Host + password form, `POST /api/auth/login`. |
| `s3player-app/ContentView.swift` | Root `NavigationStack`. Single `EpisodeRouteKey` destination. |
| `s3player-app/BrowseViews.swift` | `StationsView` (with rails), `ShowsView`, `MonthsView`, `EpisodesView`, `EpisodeDetailView`, `RecentRail`, `RecentCard`. |
| `s3player-app/PlayerView.swift` | Per-episode UI, session state machine (`inactive` / `activating` / `active` / `displaced`), progress lifecycle. |
| `s3player-app/AudioPlayerViewModel.swift` | `AVPlayer` wrapper: prepare/seek/skip, KVO, periodic time observer, MediaPlayer integration, remote command targets. |
| `s3player-app/CatalogModels.swift` | `Decodable` schemas for the s3player API; `formatTimeSlot`. |
| `s3player-app/APIClient.swift` | Bearer-authenticated REST client. Centralized header attachment; `X-Player-Session` is set in exactly one place, only on `validate`/`saveProgress`/`markComplete`. |
| `Info.plist` (project root) | Adds `UIBackgroundModes = [audio]`; merged with auto-generated keys (`GENERATE_INFOPLIST_FILE = YES`). |

## API touched

All routes use `Authorization: Bearer <site-token>`. Session-protected routes additionally use `X-Player-Session: <player-token>`.

| Method | Path | Notes |
| --- | --- | --- |
| `POST` | `/api/auth/login` | Site password → bearer token. |
| `GET` | `/api/shows/stations` | Home stations list. |
| `GET` | `/api/shows/stations/{station}/shows` | Per-station shows. |
| `GET` | `/api/shows/{show_id}/months` | Year+month buckets (years derived client-side). |
| `GET` | `/api/shows/{show_id}/months/{year}/{month}/episodes` | Episodes in a month. |
| `GET` | `/api/shows/episodes/{id}` | Episode details + chapter metadata for the pre-play details screen. |
| `GET` | `/api/shows/episodes/{id}/audio_url` | Presigned S3 URL. |
| `GET` | `/api/player/episodes/{id}/progress` | Resume offset on entry. |
| `POST` | `/api/player/session/claim` | Take over the single active session. |
| `POST` | `/api/player/session/validate` | Detect displacement. Session-protected. |
| `POST` | `/api/player/episodes/{id}/progress` | Periodic + on pause/exit. Session-protected. |
| `POST` | `/api/player/episodes/{id}/complete` | On natural end-of-playback. Session-protected. |
| `GET` | `/api/player/in-progress` | Continue-listening rail. |
| `GET` | `/api/player/recent` | Recently-played rail. |

## Distribution

Create an iOS device archive and export a development `.ipa` in one step:

```sh
scripts/create-archive-ios.sh
```

The script writes an iOS-only archive to `./build/s3player-app-ios.xcarchive` using `-destination 'generic/platform=iOS'` and `-sdk iphoneos`, then generates a temporary `ExportOptions.plist` with `method = debugging`, the `DEVELOPMENT_TEAM` from `Developer.xcconfig`, and automatic signing, and exports into `./build/export`.

Use flags when you need an explicit team ID, explicit paths, or another export method:

```sh
scripts/create-archive-ios.sh <TEAM_ID> \
  --archive-path /path/to/s3player-app-ios.xcarchive \
  --export-path /path/to/output \
  --method debugging # Internal dev testing on registered devices.
```

Install on a paired device:

```sh
xcrun devicectl list devices
xcrun devicectl device install app --device <ID> ./build/export/s3player-app.ipa
```

### macOS

Use the convenience script instead of archiving from Xcode (`Product → Archive`) manually:

```sh
scripts/create-archive-macos.sh
```

This writes a macOS archive to `./build/s3player-app-macos.xcarchive` using `-destination 'generic/platform=macOS'` and `-sdk macosx`. Same flags/env overrides as the iOS script (`--team-id`, `--archive-path`, `--configuration`, `--allow-provisioning-updates`).

Install the resulting `.app` into `/Applications` via Finder. Reveal it:

```sh
open ./build/s3player-app-macos.xcarchive/Products/Applications/
```

Then drag `s3player-app.app` onto `/Applications` in the Finder sidebar. If a previous version is already installed, quit it first and choose **Replace** when prompted.
