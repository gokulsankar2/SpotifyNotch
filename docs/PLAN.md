# SpotifyNotch — Dynamic Island for Spotify on macOS

## Context

The user wants a native macOS app that turns the physical display notch on their MacBook Pro (M5, macOS 26, notch-equipped) into an iPhone-style "Dynamic Island" for Spotify: a passive glance-and-control surface for whatever is currently playing, fully automatic after initial setup — no separate app to remember to open, no manual re-triggering. The project directory (`~/Desktop/Projects/SpotifyNotch`) is currently empty — this is a greenfield build, not a modification of existing code.

Confirmed decisions from discovery:
- **Data/control source:** Spotify Web API via OAuth (not the system-wide MediaRemote private framework, not AppleScript to the local Spotify app). This is what makes "works no matter where Spotify is actually playing from" possible — Web API reflects Spotify Connect state regardless of which device (this Mac, a phone, a speaker) is actually outputting audio.
- **Scope:** Real physical notch only — no simulated-notch fallback for non-notch Macs/displays.
- **Distribution:** Intended to be shared as an open-source / downloadable app eventually (not App Store) — needs Developer ID signing + notarization, README, license.
- **Interaction model:** Hover-to-expand/collapse, matching iOS Dynamic Island behavior. "Replay"/Previous = standard semantics (restart current track if >3s in, else go to the prior track).
- **Zero-touch operation:** After one-time Spotify login, the app should auto-launch at login and run continuously in the background. The user should never need to "start the app" and then separately "start Spotify" — the notch reacts automatically to whatever Spotify is doing, from any device.
- **Auto-hide when redundant:** If the actual Spotify desktop app window is frontmost/focused on the Mac, the notch overlay should temporarily disappear (the user is already looking at the full player) and reappear the moment they switch to another app — mirroring how iOS's Dynamic Island doesn't duplicate the now-playing bar while you're inside Spotify itself.
- **Visual identity:**
  - **Idle/mini state** (something is playing, Spotify not frontmost): left lobe of the notch shows a small album-art thumbnail; right lobe shows an animated "sound wave" bar visualization, color-tinted using colors extracted from the album art.
  - **Hover/expanded state:** full-size album art, full track/artist/album details, progress bar, and Previous / Play-Pause / Next controls.
  - **True idle** (nothing playing, or Spotify frontmost): notch shows nothing extra — just the plain hardware notch.
- **Waveform data source (resolved):** Spotify's Web API no longer exposes real tempo/beat/amplitude data to apps created after Nov 2024 (Audio Features/Audio Analysis endpoints were deprecated for new apps), so a literally beat-accurate visualizer isn't available from Spotify directly. Decision: ship a **decorative, album-color-tinted pulse animation** as the always-working baseline (works identically for local or remote/Connect playback, needs no extra permissions). Layer in an **optional, best-effort tempo enhancement**: the user found a third-party service, RapidAPI's ["Track Analysis"](https://rapidapi.com/soundnet-soundnet-default/api/track-analysis), that may provide BPM/beat data independent of Spotify. Its actual response schema, reliability, pricing/rate limits, and terms of use could **not be verified via automated fetch during planning** (the page is a JS-rendered RapidAPI listing with no accessible docs from a plain fetch) — so it must be evaluated hands-on early in implementation (sign up, inspect a real response) before committing to it. Architected as a pluggable, optional data source that gracefully falls back to the decorative animation if it's unavailable, unreliable, rate-limited, or turns out not worth the dependency.

## Goals

- Fully automatic: one-time Spotify login, then the app runs as a login item and reacts to playback state with no further user action, regardless of which device is actually outputting audio.
- Idle-state notch shows album art (left) + color-tinted animated waveform (right); expands on hover to full detail + transport controls.
- Auto-suppresses itself while the real Spotify desktop window is frontmost; reappears on app switch.
- Reflects real Spotify playback state within a few seconds, including changes made from other Connect devices.
- Runs with no Dock icon; login-item behavior is automatic post-setup (with a menu-bar toggle to disable if the user wants).
- Buildable and shareable by others: signed, notarized, packaged, documented.

## Non-goals (for this pass)

- Non-Spotify media sources (Apple Music, browsers, etc.) — Spotify only.
- Simulated notch for non-notch Macs.
- Lyrics, queue management, playlist actions, or other Spotify features beyond now-playing + transport controls.
- App Store distribution.
- Guaranteed real-time, beat-accurate audio reactivity — best-effort only, contingent on the unverified third-party tempo API; decorative animation is the reliable fallback and acceptable end state if the real-data path doesn't pan out.

## Architecture Overview

**Stack:** Swift 6 / SwiftUI for UI, AppKit interop for window management, `URLSession` + `async/await` for networking, Keychain Services for token storage, `AuthenticationServices` (`ASWebAuthenticationSession`) for the OAuth browser hand-off, `NSWorkspace` notifications for frontmost-app tracking, `SMAppService` for login-item registration. Minimum deployment target: macOS 14 (Sonoma).

**Subsystems, bridged through a shared `PlaybackViewModel` (`ObservableObject`):**

1. **Notch window subsystem** — screen geometry detection + a borderless, high-level `NSPanel` rendering idle/mini/expanded SwiftUI states, hover-driven expand/collapse animation.
2. **Spotify subsystem** — OAuth (PKCE), token refresh/storage, polling current playback state, issuing transport-control calls.
3. **Focus subsystem** — watches which app is frontmost; tells the notch window to suppress itself while Spotify's own window is focused.
4. **Visual subsystem** — album-art color extraction; waveform rendering (decorative baseline, optional tempo-driven mode).

## Key Technical Decisions (validated against current docs/prior art)

- **Notch detection & geometry:** `NSScreen.safeAreaInsets.top` detects a notched screen (`> 0`); notch width/x-origin derived from `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (the notch is the gap between these two unobscured top-corner rects). Apple-documented, sanctioned mechanism.
- **Window:** Borderless, non-activating `NSPanel` at a high window level (status-bar/screen-saver tier), positioned from the computed notch rect, hosting SwiftUI via `NSHostingView`. Idle-state shape matches the hardware notch exactly; mini-state widens slightly to fit the album art + waveform lobes while still visually reading as "the notch, extended"; expanded state animates to the full card.
  - **Prior art for reference only** (do not copy code — most are GPL, which would force this project's license if reused verbatim): [boring.notch](https://github.com/TheBoredTeam/boring.notch) (closest match — SwiftUI hover-to-expand notch music control center), [top-notch](https://github.com/techuila/top-notch) (pixel-precise idle sizing), [macnotch](https://github.com/codewithkevin/macnotch) (borderless-`NSPanel`-anchored-under-notch pattern).
- **Frontmost-app suppression:** Observe `NSWorkspace.shared.notificationCenter` for `didActivateApplicationNotification`; when the activated app's bundle identifier is `com.spotify.client`, hide/suppress the notch overlay; on any other app activating, restore it (subject to normal playing/not-playing state).
- **OAuth flow:** Authorization Code with PKCE (no stored client secret) via `ASWebAuthenticationSession`.
  - **Redirect URI:** Spotify now requires loopback (`http://127.0.0.1:PORT/callback`) rather than `localhost` or custom URL schemes (tightened rules, fully enforced Nov 2025). Plan to run a short-lived local HTTP listener on an ephemeral port to catch the redirect.
  - **Scopes:** `user-read-currently-playing`, `user-read-playback-state`, `user-modify-playback-state`.
  - Tokens stored in Keychain; refresh handled transparently. Persisted so the app never needs re-login after the first time, enabling true zero-touch startup.
- **Playback control constraints (must be handled in UI):** Modify-playback endpoints require Spotify **Premium** (403 otherwise) and an **active Spotify Connect device** (404 "No active device" otherwise). Needed empty/error states: logged out, free-tier account, no active device anywhere, normal playing/paused.
- **Polling strategy:** No push mechanism exists; poll `/me/player/currently-playing`. No fixed published rate limit (rolling ~30s window, 429 + `Retry-After` on breach). Plan: ~3–5s polling while notch is in mini/expanded state, back off when truly idle (nothing playing) or suppressed (Spotify frontmost), exponential backoff on 429. Local timer interpolates progress between polls for smooth animation.
- **Automatic startup:** On first successful Spotify connect, auto-register the app as a login item via `SMAppService.mainApp.register()` (with a menu-bar toggle to opt out later) so the user never has to think about relaunching it.
- **Album color extraction:** Downsample the album art image and extract a small palette (dominant + 1–2 accent colors) via Core Image (`CIAreaAverage` over sub-regions or a lightweight quantization pass) — no external dependency needed for the baseline.
- **Waveform rendering:** SwiftUI `Canvas`/`TimelineView`-driven animated bars, gradient-tinted from the extracted album palette. Decorative baseline pulses independent of real audio timing. If the third-party tempo API (see below) proves usable, its BPM/beat data drives the pulse timing instead — implemented behind a small `TempoDataProvider` protocol so the rest of the UI doesn't care which mode is active.

## Open Item to Resolve Early in Implementation

- **Evaluate RapidAPI "Track Analysis"** (`https://rapidapi.com/soundnet-soundnet-default/api/track-analysis`) hands-on: sign up, make a real request, inspect what it actually returns (tempo/BPM? a beat grid with timestamps? just high-level energy/danceability?), what input it needs (Spotify track ID vs artist/title search vs audio upload), its free-tier limits and pricing, and whether its terms of service are compatible with redistributing an open-source app that depends on it. If it pans out, wire it in as the optional `TempoDataProvider`; if not (unreliable, paywalled, ToS-incompatible, or data too coarse to be useful), ship with the decorative animation only and note the limitation in the README rather than blocking on it.

## Implementation Plan

**Phase 0 — Project setup**
- `git init`; create the Xcode project (SwiftUI App target, `LSUIElement` = true, no Dock icon).
- Register the app on the Spotify Developer Dashboard: Client ID + loopback redirect URI.
- Add `.gitignore`, `LICENSE` (MIT/Apache-2.0 recommended — avoid GPL entanglement from reference prior art), `README.md` stub.

**Phase 1 — Notch geometry & window shell**
- `Notch/NotchGeometry.swift`: notch detection/rect computation.
- `Notch/NotchWindowController.swift`: borderless `NSPanel`, positioned/sized for idle, mini, and expanded states.
- Manual verification: idle overlay is visually indistinguishable from the real notch at rest.

**Phase 2 — Spotify OAuth & API client**
- `Spotify/SpotifyAuthManager.swift`: PKCE flow, `ASWebAuthenticationSession`, loopback redirect listener, Keychain token storage + refresh.
- `Spotify/SpotifyAPIClient.swift`: currently-playing fetch, play/pause/next/previous calls, device-list fallback, 401/403/404/429 handling with backoff.

**Phase 3 — Playback state & progress engine**
- `PlaybackViewModel.swift`: polling loop publishing track/artist/album-art URL/progress/`is_playing`/device+premium state; adjusts polling cadence based on notch visibility state.
- `Spotify/PlaybackProgressTimer.swift`: local interpolation timer for smooth progress.
- In-memory album art image cache.

**Phase 4 — Focus suppression**
- `Focus/SpotifyFocusMonitor.swift`: `NSWorkspace` frontmost-app observer, publishes whether Spotify.app is currently focused.
- Wire into `NotchWindowController` to suppress/restore the overlay.

**Phase 5 — Visual identity (album art + waveform)**
- `Visual/AlbumColorExtractor.swift`: palette extraction from album art.
- `Visual/WaveformView.swift`: decorative baseline animation, tinted from extracted palette; pluggable `TempoDataProvider` protocol for future real-data mode.
- Mini-state layout: album art thumbnail (left) + waveform (right).

**Phase 6 — Expand/collapse interaction & full UI**
- Hover detection driving animated transition between mini and expanded states.
- Expanded card: full album art, track/artist/album, progress bar, Previous/Play-Pause/Next controls wired to `PlaybackViewModel`.
- Empty/error states: logged out, free-tier, no active device, nothing playing.

**Phase 7 — App lifecycle & menu bar**
- `NSStatusItem` menu: Connect/Disconnect Spotify, Launch-at-Login toggle (`SMAppService`, on by default after first connect), Quit.
- Multi-display handling: attach only to the built-in notched screen.

**Phase 8 — Tempo enhancement (conditional)**
- Only if Phase-0-adjacent evaluation of the RapidAPI service (see "Open Item" above) checks out: implement a `TempoDataProvider` backed by it, cached per-track (not polled per-frame), feeding real beat timing into `WaveformView`.

**Phase 9 — Polish & distribution**
- App icon, README (setup instructions, Spotify Client ID/quota-mode notes — Development Mode caps at ~25 users, worth flagging if this gets shared widely).
- Developer ID signing + notarization (requires an active Apple Developer Program membership — flag as a prerequisite/cost).
- Package as `.app` in a DMG for GitHub Releases.
- Stretch/later: Sparkle auto-update integration.

## Verification

Primarily manual, run directly on the user's MacBook (screen-space overlay + live OAuth + live Spotify playback aren't meaningfully automatable):

- Idle overlay pixel-alignment with the real notch.
- OAuth login end-to-end; confirm token persists across app relaunch/reboot with no re-login needed.
- Local playback: hover shows correct track/artist/art/progress; Play/Pause/Next/Previous control it.
- Remote/Connect playback (e.g. playing from phone, Mac app just running in background): confirm the notch still reflects and can control it.
- Frontmost-suppression: open Spotify's window → notch disappears; switch to another app → it reappears.
- Reboot the Mac without manually opening anything → confirm the app auto-launches and the notch works once music starts.
- Edge cases: logged out, free-tier account tapping a control, nothing playing, no active device anywhere, rapid skip presses (backoff doesn't hang the UI).
- External monitor connected → no stray windows on non-notch displays.
- Unit-testable slice: `SpotifyAPIClient` request/response parsing and `PlaybackProgressTimer` interpolation math, with mocked `URLSession` responses.
