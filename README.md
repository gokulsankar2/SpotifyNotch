# SpotifyNotch

A Dynamic Island for Spotify, living in your MacBook Pro's hardware notch.

SpotifyNotch turns the physical display notch into a passive glance-and-control
surface for whatever Spotify is playing — on this Mac, your phone, or a speaker
across the house. It runs in the background with no Dock icon and no window.
Sign in once, and it is simply always there.

- **Idle** — nothing playing: the bare hardware notch, untouched.
- **Mini** — album art on the left lobe, an album-tinted waveform on the right.
- **Hover** — expands into full art, track details, a progress bar, and
  Previous / Play-Pause / Next.
- **Out of the way** — hides itself whenever Spotify's own window is frontmost,
  and comes back the moment you switch apps.

Because it reads the Spotify Web API rather than local audio, it reflects and
controls **Spotify Connect** state from any device, not just this Mac.

## Requirements

- A **notch-equipped** MacBook Pro or MacBook Air. SpotifyNotch deliberately
  does not simulate a notch on displays that lack one — on a Mac without a
  notch it stays dormant.
- **macOS 14 Sonoma** or later.
- A **Spotify account**. Playback *display* works on Free; the transport
  controls require **Premium**, because Spotify's API rejects playback
  modification for Free accounts (HTTP 403).

## Setup

1. Download the latest `SpotifyNotch.dmg` from Releases, drag the app to
   `/Applications`, and launch it.
2. Click the waveform icon in the menu bar → **Connect Spotify…**.
3. Approve access in the browser window that opens. That's it — the app
   registers itself as a login item on first successful connect, so it will be
   running the next time you boot.

### Using your own Spotify Client ID

SpotifyNotch ships with a Client ID so it works immediately. Spotify caps an
app in *Development Mode* at **25 distinct users**, so if sign-in fails with an
access error, register your own:

1. Go to the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
   and create an app.
2. Add **all three** of these redirect URIs:
   ```
   http://127.0.0.1:8888/callback
   http://127.0.0.1:8889/callback
   http://127.0.0.1:8890/callback
   ```
   Three are registered so the app can fall back if a port is already in use.
   Spotify requires an *exact* redirect-URI match, so the ports cannot be
   chosen dynamically.
3. Paste the Client ID into **Settings…** in the menu bar, then reconnect.

Scopes requested: `user-read-currently-playing`, `user-read-playback-state`,
`user-modify-playback-state`. No client secret is stored — authentication uses
Authorization Code with **PKCE**, and tokens live in the macOS Keychain.

## Building from source

```bash
git clone <repo-url>
cd SpotifyNotch
open SpotifyNotch.xcodeproj
```

Build and run the `SpotifyNotch` scheme. You will need to set your own
`DEVELOPMENT_TEAM` in the target's Signing & Capabilities tab, or set
`AppSettings.bundledClientID` and sign to run locally.

The app is sandboxed and uses only first-party frameworks — there are no
package dependencies to resolve.

## Known limitations

- **The waveform is decorative, not beat-synced.** Spotify deprecated the
  Audio Features and Audio Analysis endpoints for applications created after
  November 2024, so real tempo and beat data is not available to this app. The
  visualisation is an album-colour-tinted animation that does not claim to
  track the actual audio. A `TempoDataProvider` seam exists so a real beat
  source can be dropped in later without touching the UI.
- **Transport controls need Premium and an active device.** With no active
  Spotify Connect device anywhere, Spotify returns 404 and there is nothing to
  control; the app surfaces this rather than failing silently.
- **Refresh tokens expire after 180 days.** Spotify assigns newer apps a
  finite refresh-token lifetime (visible on the dashboard). The app refreshes
  transparently and rotates the token whenever Spotify issues a new one, so
  ordinary day-to-day use never prompts for a login — but an install left
  untouched past the window will ask you to reconnect once from the menu bar.
- **Polling, not push.** Spotify offers no push mechanism for playback state,
  so the app polls every few seconds and interpolates progress locally in
  between. Changes made on another device appear within a few seconds rather
  than instantly. Polling backs off when nothing is playing or the overlay is
  suppressed.
- **Single notched display.** The overlay attaches only to the built-in notched
  screen and never appears on external monitors.

## License

MIT — see [LICENSE](LICENSE).

This project was written from scratch. Existing notch apps
([boring.notch](https://github.com/TheBoredTeam/boring.notch),
[top-notch](https://github.com/techuila/top-notch),
[macnotch](https://github.com/codewithkevin/macnotch)) were consulted as prior
art for the general approach only; no code was copied, deliberately, since
several are GPL-licensed and would have forced that license onto this project.
