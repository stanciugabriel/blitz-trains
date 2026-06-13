# Agent Notes

## Project Vision
- Build "Raily" – a glassmorphic, Flighty-style native iOS app tracking CFR Călători trains.
- Fuse offline GTFS schedule data with live OCR (StationBoardScanner) for platform/delay truth.
- Keep MapKit visible at all times, layering glass cards and sheets for content.

## Key Components
1. **Trip / TripStore**: merges offline GTFS data, live OCR platform/delay, seat + booking state, and coordinate polylines.
2. **MainDashboardView**: map background with straight geodesic overlays, floating "My Trips" glass sheet, Flighty-style list, add-trip modal, and empty-state arrow.
3. **TripDetailView**: detail screen with map showing every station pin + curved path, vertical timeline (TimelineRowView), metadata grid (platform hero, seat + booking editables), and "Where is my train?" progress banner.
4. **Add Trip Modal**: Flighty-like picker w/ train-number search, Yesterday/Today/Tomorrow/Pick Date pills, and GTFS results list.

## Visual + UX Requirements
- Full-screen MapKit background.
- Glass Flighty aesthetic: `.ultraThinMaterial` / `.systemMaterialDark`, SF Pro Rounded, white text plus safety orange / signal green accents.
- Dashboard sheet anchored to lower 40% with "My Trips" header, + button, empty-state arrow, and operator/date/route layout.
- Detail sheet: vertical timeline at top, metadata grid in middle, platform tile emphasized, "Where is my train?" progress + copy at bottom.

## Recent Implementation Notes
- Trip detail sheet now always shows a "Good to Know" arrival weather card fed by WeatherKit, falling back to status text when the API is unavailable and styled with a thin 20pt-corner border.
- Travel summary row in TripDetailView keeps duration/distance inline with an overnight badge plus moon icon, while the arrival time shows a small `+1` chip when crossing midnight.
- Good to Know area now stacks weather with mocked departure/arrival ops cards (dot.radiowaves delay label + concentric green status circles and ops copy).
- TripDetailView ends with a "My History on This Route" panel (route subtitle, rides/distance/time stats with SF symbols) framed by a thin bordered rectangle.
- Dashboard map auto-fits either all saved trips or the currently selected trip, applies a northward offset so routes stay visible above the sheet, and exposes Apple's center-on-location control.
- Home sheet trip rows show live countdowns (with arrival/departure states), chronological sorting, auto-pruning 20 minutes after arrival, and offer a Past Rides sheet via the profile icon.
- TripDetailView sports a "Sync Status" button that runs an InfoFer session handshake, scrapes the live delay/platform text, updates the status/Platform labels inline, and logs the fetch result.
- InfoFerScraper mirrors the site's form submission: it loads the shell page with stored cookies, mirrors every hidden input (including confirmation/reCAPTCHA fields), reposts to `/Trains/TrainsResult`, and parses the returned HTML.
- Sync button supports a long-press “forget delay/platform” gesture, and cleared values are persisted/propagate back to the dashboard.
- TripDetailView now allows editing coach/seat info via sheet-based forms, persists past trip statistics, and hosts a floating blue-glass “Ticket QR” action that scans or displays stored QR codes.
- InfoFer scraping now captures platform plus per-station arrival/departure delays, letting us persist that data on each stop and surface it inside a dedicated “Station Delays” sheet accessible from the detail toolbar.
- Terminal cards in TripDetailView read that per-stop delay state so the clock, color, and status copy stay in sync (e.g., early arrivals show green time with “X m early” and no strikethrough).
- Map view only surfaces the user-location dot and Apple’s center-on-me button from 10 minutes before departure through arrival, keeping them hidden on the dashboard and outside the rider’s active window.
- Live train marker now appears only after the consist leaves its origin stop (and persists through arrival) while user vs. train indicators remain mutually exclusive.
- TripDetailView now opens with an InfoFer status banner directly under the header, showing the exact paragraph scraped from the site with green/red chrome based on the latest delay state.
- Added an Operator section (CFR logo, contact actions, report CTA) and an Arrival Forecast card (mock stats + colored distribution bars) beneath History to spotlight operator touchpoints and historical reliability.
- Trip rows reuse the same per-terminal delay heuristics as the detail sheet: departure/arrival times adjust independently using station-level delay data, and their colors turn red/green per terminal rather than sharing a single delay tint.
- GTFS access now comes from the baked `static_data.sqlite` schema; a new datasource layer maps trains, stations, and segments so we can search/service routes without the old GTFS tables.
- Detail + dashboard maps draw their polylines from the full `trip_segments` chain while dots only appear on commercial stops (or forced termini), keeping overlays clean but accurate.
- Trip timing uses `ScheduleDateUtils` to normalize post-midnight arrivals; overnight runs show the `+1` badge correctly and stay on the active list until 20 minutes after the real (delay‑adjusted) arrival.
- TripDetailView ends with a live "Track Speed Limit" card: it evaluates the currently active `trip_segments` window (delay‑aware) and animates the km/h readout / copy in sync with the device clock.
- Past Rides sheet is now a full profile pane: avatar + name editor, "My Rail Log" subtitle, live stats (distance, ride time, most-used station, trip count), and inline Past Rides ledger rows that mirror the latest profile photo/name.
- Profile edits (name + photo) persist via `ProfilePreferences`, sync to the dashboard avatar button, and expose a sheet-based profile editor plus a form-driven Settings page (notifications, trip auto-archive, map style, privacy actions).
- TripDetailView hosts mock experiential sections: a speedometer/speed-limit experience, a train-formation inspector, and a bistro menu card so content remains rich even without live data.
- Main sheet now uses a native SwiftUI `TabView` with tabs for My Trips, Friends, Log, and `Tab(role: .search)` for the add-trip/search flow. Search is locked to the large sheet detent; normal tabs keep `.fraction(0.3)`, `.medium`, and `.large`.
- Search tab remembers the previous tab and Cancel returns there. Autofocus is intentionally handled with a single pending focus flag from `TextField.onAppear`; avoid adding multiple timer/task-based focus paths because UIKit logs invalid keyboard sessions when focus fires before the native search tab is visible.
- Past trips opened from Log/detail context pass `isPastTrip` into `TripDetailSheet`; past-trip detail hides the InfoFer banner/status text and the Sync toolbar button.
- Log tab now replaces the old Past Rides entry point for the main history view. It has side-padded rows plus a Rail Log summary card aggregating all past rides: trip count, total distance, total ride time, and unique visited stations using each ride's origin/destination only.
- Log tab also has a Delay Pattern card. It should compute delay metrics from the same effective live/header delay source used by compact `TripRowView`: `LiveDelayStore.shared.info(for:)` first, then `trip.delayMinutes`, then destination station delay data if needed.
- Compact trip rows now show "Arrived On Time" for completed on-time rides instead of "Departs On Time".
- Trip detail travel summary duration is delay-aware: it uses adjusted departure and adjusted arrival dates, so terminal delay/earlyness changes the displayed ride time.
- Detail sheet no longer renders the mock Train Composition or Bistro Menu sections; the editable "About the Train" section remains.
- App launch now auto-syncs saved active trips once via InfoFer and persists delay/platform data into `LiveDelayStore` and stored stop delay fields. Newly added trips also trigger the same single-trip sync immediately after finalizing the add flow.
- Map marker state was corrected conceptually: before boarding, show the interpolated train marker from service origin to user's boarding station; between user's boarding and destination arrival, prefer user location; after user destination arrival until final train arrival, show the interpolated train marker again. Avoid shifting same-day future segment timelines to yesterday; base map segment timelines on the selected travel date's start of day.
- InfoFer map scraping now calls `/Trains/LoadTrainMapPartial` separately from the delay/platform scrape. The map endpoint is used for route polylines and live train coordinates; delay/platform/station delay data still comes from the `/Trains/TrainsResult` form-post flow. A refresh therefore does a session handshake, then delay scrape, then the map scrape only when needed/allowed.
- `Trip.routePolylines` persists InfoFer route geometry. New trips attempt to fetch the map polyline once after add; if the user is offline or the scrape fails, maps fall back to the existing static route/segment path and manual refresh retries the polyline only while it is still missing. Launch auto-sync should not fetch map polylines.
- Map interpolation now prefers saved InfoFer polylines and falls back to existing segment/stop interpolation. The train marker is green when driven by a trusted InfoFer GPS/CFR-reported coordinate and blue when driven by interpolation.
- InfoFer coordinate parsing accepts real location labels containing `Ultima poziție GPS la` or `RAPORTAT de personalul CFR la`. It rejects `Poziție ESTIMATĂ pe baza raportării CFR`; when that estimated-only label appears, mark the trip as `infoFerGPSUnavailable` and avoid future coordinate attempts for that trip unless a route polyline is still missing. Do not age-gate GPS/reported coordinates by their InfoFer timestamp because the site can compute that timestamp incorrectly.
- Manual InfoFer refresh should be ignored more than 30 minutes before the train's service-origin departure, not the user's boarding departure. The detail header currently shows "The train does not have data from its trip yet." for that case.
- `static_platforms.sqlite` supplies fallback platform data by `station_id`, `train_id`, and `platform`. Scraper/platform data has priority; static data fills main trip and Live Activity header platforms when live platform data is absent. The SQLite currently has only a small development subset, so missing rows are expected.
- Live Activity work added a shared `TrainLiveActivityAttributes` model in `Shared/`, a `LiveActivityManager`, and the `blitzWidget` ActivityKit/Dynamic Island UI. The app starts a Live Activity after adding an active trip, exposes a Live toggle in trip detail, refreshes running Live Activities on delay-store updates/app foreground/active-app minute ticks, and manual sync now updates the activity with the station-delay-applied trip.
- `blitzWidget` now declares `.supplementalActivityFamilies([.small, .medium])` and `TrainLiveActivityView` switches on `@Environment(\.activityFamily)` so the Live Activity has a compact Apple Watch Smart Stack layout for `.small` while keeping the existing iPhone layout for the default case. `@Environment(\.isLuminanceReduced)` is also wired into the watch variant for Always-On display dimming.
- Timing architecture migration has started: `ScheduleDateUtils` was extracted from `TripDetailSheet.swift` into `blitz/ScheduleDateUtils.swift`, and `blitz/TripTimingResolver.swift` now centralizes the first pass of trip timing resolution. The resolver accepts `Trip`, optional `DelayInfo`, a reference date, and an injectable `TripScheduleProviding`; `GTFSDataSource` conforms in production and tests use a mock provider.
- `TripTimingResolver` currently resolves scheduled vs adjusted user departure/arrival, station-level delay overrides, header-delay fallback, early/late/on-time status text, trip phase (`preDeparture`/`inTransit`/`completed`), user-origin platform, next stop, and stations remaining. It intentionally does not own persistence or InfoFer sync.
- Added focused resolver tests in `blitzTests/blitzTests.swift` for station delay overriding header delay, live station delays/platform, header fallback, and overnight arrival normalization. Verified with `xcodebuild -project blitz.xcodeproj -scheme blitz -destination generic/platform=iOS -derivedDataPath /private/tmp/blitz-derived CODE_SIGNING_ALLOWED=NO build` and `xcodebuild test -project blitz.xcodeproj -scheme blitz -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /private/tmp/blitz-derived CODE_SIGNING_ALLOWED=NO`; both passed.

## Current Architecture Risks / Recommended Next Work
- Continue migrating existing call sites to `TripTimingResolver`. Start with `LiveActivityManager` so Live Activity phase/times/platform/next-stop math comes from the resolver, then migrate `TripRowView`, `TripDetailSheet`, Log delay analytics, pruning/archive cutoff, and map tracking windows. Dashboard rows, detail cards, Log analytics, pruning, and maps should not each reimplement timing logic.
- Extend `TripTimingResolver` as call sites migrate: add duration, archive cutoff, color/status presentation helpers if they remain duplicated, and map tracking window outputs once the map code is moved.
- Extract all sync code from `ContentView` and `TripDetailSheet` into a reusable `TripSyncService`. It should perform InfoFer handshake/fetch, persist `LiveDelayStore`, apply per-station delay/platform data, update the stored trip, update running Live Activities, and return updated `Trip` values.
- When extracting `TripSyncService`, keep map scraping and delay scraping as distinct operations: delay data is always the core refresh, while map scraping is conditional for missing polylines or allowed GPS/CFR coordinates. Preserve the early-refresh guard based on service-origin departure.
- Add "Last synced" UI with timestamp and source state on rows/detail. Users need to distinguish fresh InfoFer data from cached/stale data.
- Add notification preferences later: thresholds such as "notify if delay changes by 5+ min", "notify if platform changes", and "notify if train becomes early". For reliable timely alerts, prefer server-side APNs monitoring; iOS background refresh is best-effort only.
- Make Friends useful through shareable trip cards/live ETA sharing before building broader social features.
- Add more focused tests for date/delay math as migration continues: archive cutoff, map marker phase transitions, next-stop/stations-remaining with intermediate stops, platform absence, and active-service base-date selection for GTFS times over 24 hours.

## Implementation References / Gotchas
- `TripDetailSheet.syncDelay()` is the current manual sync reference path. If refactoring, preserve its behavior: service-origin early guard, refresh InfoFer session, fetch delay/platform, conditionally fetch map info, save `LiveDelayStore`, apply station delays to stops, update route polylines only when missing, update `infoFerGPSUnavailable`, update the selected trip, and refresh running Live Activities.
- InfoFer can include disruption blocks under "Alte info tren" with `.alert-warning.alert`, including bus-transfer notices such as "Trenul are transfer cu autobuzul de la stația Timișoara Nord până la stația Caransebeș" plus CFR contact numbers. Future scraper work should detect and preserve these warnings as trip disruption metadata instead of treating them as normal delay/platform text.
- `InfoFerScraper.fetchMapInfo(...)` is the current map reference path. It requests `RunningNumber`, `DepartureDateTime` using the train service-origin departure time, and a millisecond cache buster. It parses `L.PolylineUtil.decode("...")` route segments plus `theoreticalGpsPositionLatitude/Longitude`.
- `DelayInfo.liveCoordinate` stores the latest accepted InfoFer coordinate. If a refresh has no usable coordinate because the network/map scrape failed, marker rendering falls back to blue interpolation. If the old stored coordinate remains present, be careful when changing this behavior so stale green markers do not accidentally persist contrary to the desired refresh semantics.
- `TripRowView` is still the current compact-row display reference for effective delay/status wording until it is migrated to `TripTimingResolver`. Log delay analytics should stay consistent with this row during the transition.
- `ScheduleDateUtils` now lives in `blitz/ScheduleDateUtils.swift`; it handles post-midnight arrival normalization and shifted-forward date math. Keep overnight behavior intact.
- `TripTimingResolver` is the target source of truth for user-trip timing. Prefer adding missing timing behavior there with tests instead of adding another local timing helper in a view.
- Next concrete migration step: migrate `LiveActivityManager.contentState(...)` to call `TripTimingResolver.resolve(...)` instead of using its local `timeline(...)`, `serviceBaseDate(...)`, `terminalDelay(...)`, `nextStop(...)`, and `platform(...)` helpers. After build/tests pass, delete the duplicated helpers from `LiveActivityManager`.
- Useful verification commands after timing/live-activity changes:
  - `xcodebuild -project blitz.xcodeproj -scheme blitz -destination generic/platform=iOS -derivedDataPath /private/tmp/blitz-derived CODE_SIGNING_ALLOWED=NO build`
  - `xcodebuild test -project blitz.xcodeproj -scheme blitz -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /private/tmp/blitz-derived CODE_SIGNING_ALLOWED=NO`
- Worktree may contain unrelated dirty project metadata/assets from earlier Live Activity/widget work. Do not revert unrelated changes unless explicitly asked.
- `static_data.sqlite` is the source of truth for trains/stations/segments. `GTFSDataSource` maps `trains`, `stations`, and `trip_segments`; old GTFS table assumptions are obsolete.
- Do not reintroduce duplicate focus mechanisms for the Search tab. The native search tab caches content and UIKit is sensitive to repeated focus updates during tab transitions.
