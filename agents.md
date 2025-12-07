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
- Map view shows Apple’s user-location dot at all times via `UserAnnotation()` while the default “center on me” button remains available (slightly inset) so the map still respects the glassmorphic overlay.
- TripDetailView now opens with an InfoFer status banner directly under the header, showing the exact paragraph scraped from the site with green/red chrome based on the latest delay state.
- Added an Operator section (CFR logo, contact actions, report CTA) and an Arrival Forecast card (mock stats + colored distribution bars) beneath History to spotlight operator touchpoints and historical reliability.
- Trip rows reuse the same per-terminal delay heuristics as the detail sheet: departure/arrival times adjust independently using station-level delay data, and their colors turn red/green per terminal rather than sharing a single delay tint.
