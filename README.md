# Wanderer

Strava for city exploration. Plan a day as an ordered set of places on a map, press **Start day**, put the phone in your pocket, and later see where you've been and where you're going next.

Native SwiftUI, iOS 17+, iPhone only. No backend, no accounts, no API keys: everything is stored on the phone and maps, walking routes and place search come from Apple Maps.

## Using it

1. **Import an itinerary.** Tap **+ → Import itinerary**, tap **Copy prompt**, paste it into ChatGPT with what you want to do, then paste ChatGPT's reply back. You can also paste a Google Maps directions link. The preview geocodes every place with Apple Maps and flags anything ambiguous or not found before saving. There is also a Milan sample (Via Gian Giacomo Mora, Via Cesare Correnti, Via Santa Marta, Via San Maurilio, Brera).
2. **Plan.** A day opens as a map with numbered stops and walking routes. In the panel: drag to reorder, swipe to edit or delete, long-press a row to move it to another day. Add places by search or by long-pressing the map. **⋯ → Optimise walking order** reorders by shortest walk, keeping the first stop.
3. **Explore.** **Start day**. The live screen shows your walked path (solid), the rest of the plan (dashed), the next stop with distance and walking time, and distance, time, steps and places visited. Visits are detected automatically; you can also tap **I'm here**, skip, undo, choose **Go here next**, reorder, or add a place on the fly. The arrow button opens Apple Maps or Google Maps directions (pick which in Settings).
4. **Finish** shows the day's summary. Finished days stay under the trip as **Walked**.

## Itinerary JSON format

```json
{
  "version": 1,
  "trip_name": "Milan, November 2026",
  "days": [
    {
      "name": "Navigli to Brera",
      "date": "2026-11-25",
      "places": [
        {
          "name": "Pinacoteca di Brera",
          "address": "Via Brera 28, 20121 Milano MI, Italy",
          "lat": 45.4719, "lng": 9.1879,
          "category": "museum",
          "description": "Why it's worth it.",
          "opening_hours": "Tue–Sun 8:30–19:15",
          "visit_minutes": 90,
          "notes": "Book ahead",
          "radius_m": 40
        }
      ]
    }
  ]
}
```

Only `name` is required per place. `address` is strongly recommended because it's what gets geocoded. The parser is lenient with LLM output: it strips code fences and surrounding prose, and accepts `latitude`/`longitude`, `location: {lat, lng}`, `coordinates: [lat, lng]`, `duration_minutes`, `"1h 30m"`, a bare list of place names, and a top-level `places` list. Problems are reported as warnings in the preview rather than failing the import.

## Installing on your iPhone

You already have a paid Apple Developer account (the App Store Connect app *Wanderer*, bundle ID `wander.wowfrang.com`). No extra capabilities need to be ticked on the App ID: background location is a background mode in `Info.plist`, not a capability.

### One-time setup

1. **Xcode account.** Xcode → Settings → Accounts → **+** → Apple ID. Sign in with the Apple ID that's in your developer team.
2. **Team ID.** Find it at [developer.apple.com/account](https://developer.apple.com/account) → Membership details. Create `Config/Local.xcconfig` (gitignored) containing:
   ```
   DEVELOPMENT_TEAM = ABCDE12345
   ```
   (Alternatively pick the team in Xcode under Wanderer target → Signing & Capabilities; that writes it into the project file instead.)
3. **Open `Wanderer.xcodeproj`** in Xcode 16 or newer.

### Option A: run straight from Xcode (fastest iteration, Mac and phone together)

1. Connect the iPhone by cable and tap **Trust** on the phone.
2. On the phone: Settings → Privacy & Security → **Developer Mode** → on, then restart. (The switch only appears after the phone has been connected to Xcode once.)
3. In Xcode choose your iPhone as the run destination and press **⌘R**. Automatic signing registers the device and creates the profile.
4. After the first run the phone shows up over Wi-Fi as long as it's on the same network as the Mac, so the cable is optional from then on.

Builds installed this way with a paid account last a year.

### Option B: TestFlight from GitHub Actions (no Mac needed)

`.github/workflows/testflight.yml` runs on every push to `main` (Markdown-only changes are skipped) and can be started by hand from the Actions tab. It runs the core tests, then archives, signs and uploads to TestFlight on a GitHub macOS runner. Signing is cloud-managed through an App Store Connect API key, so no certificates or profiles are stored anywhere.

One-time setup:

1. App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → **+**, role **Admin** (needed so Xcode can create the distribution certificate). Download the `.p8` (only possible once) and note the **Key ID** and **Issuer ID**.
2. GitHub → wowfrang/wanderer → Settings → Secrets and variables → Actions → add `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the full file contents) and `APPLE_TEAM_ID`.
3. App Store Connect → Wanderer → TestFlight: create an Internal Testing group with yourself and enable automatic distribution. Install the TestFlight app on the phone.

Builds appear in TestFlight roughly 15 minutes after a push (runner + Apple processing). macOS runner minutes count 10× against private-repo Actions quotas.

### Option C: TestFlight from your Mac

1. In App Store Connect → Wanderer → **TestFlight**, add yourself under Internal Testing (create a group, add your Apple ID).
2. Install the **TestFlight** app on the phone and sign in with the same Apple ID.
3. On the Mac: `scripts/testflight.sh`. It archives, signs and uploads with a timestamp build number. Processing takes about 5 to 15 minutes, then TestFlight offers the update.

The first upload may ask you to accept agreements in App Store Connect, or to answer the export compliance question (already answered as "no" via `ITSAppUsesNonExemptEncryption`).

### Battery

GPS is the expensive part, so by default it runs **only while Wanderer is open on screen** during an active day. Put the phone away and GPS switches off completely. The motion coprocessor keeps counting steps and walking distance (CMPedometer, negligible battery), and when you take the phone out again the path continues in a new segment. Gaps are drawn as a faint dotted link. If you're standing at a planned place when you open the app, a banner offers a one-tap **Visited**.

**Settings → Battery → Track with the screen locked** switches on pocket tracking for days you want the full trace and automatic visits: GPS continues with the screen locked at ~10 m accuracy, a 15 m distance filter and automatic pausing. It uses noticeably more battery.

### Permissions on first start

- **Location: Allow While Using App** is enough, also for the optional pocket tracking (it starts in the foreground with background location enabled, shown as the blue pill in the status bar). Keep **Precise Location** on.
- **Motion & Fitness** for steps. If declined, steps show as "–"; they're never estimated.
- **Notifications** (optional, pocket tracking only): a silent notification when a visit is detected while the phone is locked.

## Development

```
open Wanderer.xcodeproj                         # app
cd Packages/WandererCore && swift test          # core logic tests (macOS or Linux)
```

There are no third-party dependencies.

## Architecture

```
Wanderer/                 SwiftUI app (MapKit, CoreLocation, CoreMotion)
  App/                    AppModel (store, settings), LiveSession (engine ↔ GPS/pedometer/UI)
  Services/               RouteService (MKDirections + cache), MapKitGeocoder, LocationTracker, Pedometer
  Views/                  Trips → Trip → Day (map + panel) → Explore (full screen) → Summary
Packages/WandererCore/    Pure Swift, no UI frameworks, unit tested
  Models.swift            Trip, Day, Place, RouteLeg | ExplorationSession, GPSSample, VisitEvent
  Store.swift             SQLite schema, migrations, typed queries
  Import.swift            JSON parser, Google Maps URL parser, geocoding resolver
  VisitDetection.swift    VisitDetector, PathAccumulator, SessionClock, NextDestination
  SessionEngine.swift     One exploration session, persisted as it happens
```

### Decisions

- **Native SwiftUI instead of Expo.** Apple's MapKit gives walking directions and place search with no API keys, quotas to pay for, or licensing worries; CoreLocation background tracking and CMPedometer are more dependable natively; and an Xcode build onto the phone takes seconds. The cost is no over-the-air updates: each change needs a rebuild (Option A) or a TestFlight upload (Option B).
- **Plan and reality are separate.** Trips, days and places are the plan. A session, its GPS samples and its visit events are what happened. Visit status is derived from an append-only event log (visited, skipped, reset), so undo is just another event, and history survives editing or deleting the plan (events keep a snapshot of the place name).
- **Raw SQLite with versioned migrations.** `PRAGMA user_version` tracks the schema; migrations are append-only and each runs in a transaction. A failed database open never deletes data: the app runs in memory and says so.
- **Routes cached by coordinate pair**, not by place, so reordering reuses legs and nothing is refetched across launches. Straight-line fallbacks (no network, rate limit) are drawn dotted and never cached.
- **LLM coordinates aren't trusted.** If a place has an address, it's geocoded with Apple Maps; disagreement of more than 1 km with supplied coordinates, several far-apart matches, or a match far from the rest of the trip is flagged in the preview.
- **Visits needn't follow the plan.** After visiting #3 the next stop is #4, with #2 still pending. A manual "Go here next" overrides that.

### Visit detection

All in `VisitDetector`, tunable live in **Settings → Visit detection** (no rebuild):

- A fix counts only if its accuracy is better than 65 m.
- You're *inside* when your distance minus the uncertainty (capped at 20 m) is within the arrival radius (35 m by default, or the place's own `radius_m`, e.g. 60 m for a street).
- **Lingering:** inside for 75 s while your net movement since arriving is under 0.7 m/s, so you're not just walking through.
- **Strolling:** inside for 180 s at any pace (walking the length of a street counts).
- You only *leave* when a fix is clearly beyond radius + 30 m. The band in between absorbs GPS wobble.
- Undoing an automatic visit suppresses that place until you've left it.

The walked path drops fixes worse than 40 m, steps shorter than 6 m (standing-still jitter) and jumps faster than 9 m/s. Pauses and app restarts start a new path segment so the line never bridges a gap.

## Limitations and what needs a real device

- **Untested on a device yet**: background tracking, pedometer, visit detection thresholds and battery use can only be validated by walking around. Expect to tune the detection settings.
- With pocket tracking off (the default), visits are only detected while the app is open; the walked distance in the pocket comes from the pedometer, and the drawn path has dotted gaps.
- If iOS terminates the app in the background, tracking stops until you reopen it; the session resumes with a gap.
- MKDirections is rate limited (roughly 50 requests a minute). Big days fetch legs one by one; failures show dotted lines and retry later.
- Google Maps short links (`maps.app.goo.gl`) are expanded over the network; very long Google routes that embed place IDs without coordinates are geocoded by name.
