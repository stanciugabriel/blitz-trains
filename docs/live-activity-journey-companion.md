# Journey companion: Live Activity and Dynamic Island spec

**Status:** Design approved; app implementation in progress, 2026-09-27. The iOS phase UI, 30-minute start window, same-share journey grouping, and foreground live polling are implemented. The `sbb-rt` backend still needs ActivityKit APNs support for remote content updates while the app is suspended.

In Debug builds, Settings → Experimental → Dynamic Island preview starts a separate sample Live Activity. Select a phase, tap Start preview or Apply phase, use Next phase to advance, and Stop preview to remove it. Touch and hold the compact Island to inspect the expanded view. The control reports ActivityKit registration or errors. The sample uses `IC 2145` / `IC8 to Brig` and does not edit saved trips.

## Goal

At a glance, tell the rider what to do next, where to go, and when. The experience should feel like a calm travel companion: proactive about changes, brief when the journey is going well, and honest when information is uncertain.

## Core rules

- Keep the current train number and operator logo visible wherever the layout permits. During a transfer, identify the next train as well. Never let a decorative Blitz label displace the train identity or next action.
- Lead with an action or useful fact, not a generic status. For example, “Go to platform 8” or “Arrive in Bern at 14:40.”
- Use the rider's destination for arrival guidance. Use the train's GTFS headsign (its advertised final destination) in the pre-departure phases, so the rider can recognize the train on station signs. If there is no trustworthy headsign, omit it.
- Display adjusted times when fresh live data exists. Clearly distinguish scheduled information from live changes. Never present a static platform or an old update as a newly confirmed platform.
- Countdown labels may advance locally from known timestamps. New delays, platforms, boarding evidence, and connection predictions require new data; a widget timer cannot discover those by itself.
- A manually stopped Live Activity stays stopped for that trip and service date until the rider enables it again.

## Phase timeline

`T` is the latest reliable, adjusted departure time for the rider's boarding station. `A` is the latest reliable, adjusted arrival time at the rider's destination. Recalculate time boundaries when a fresh delay changes either time. Times use Europe/Zurich, including overnight services.

| Phase | Entry and exit | Main message | Supporting information |
| --- | --- | --- | --- |
| **Ready to go** | Start at `T−30 min`; end at `T−10 min`. | “IC 8 to Brig · 14:02” | Departure platform, delay if any, operator logo and train number. The headsign is the train's advertised destination, which may differ from where the rider gets off. |
| **Head to your train** | `T−10 min` to `T−5 min`, unless boarding is confidently detected sooner. | “Go to platform 7 · Departs 14:02” | Coach and seat if saved; headsign and train identity remain visible in the expanded view. If platform is unknown: “Find IC 8 to Brig · Departs 14:02.” |
| **On the train layout** | Start on confident boarding detection, or at `T−5 min`; continue until final approach. | “Bern at 14:40 · 38 min left” | Rider's arrival station, arrival time, remaining time, train identity. Before boarding is confirmed, keep a visible “Board now · Platform 7” cue until departure; do not say “You're on board.” After departure without confirmation, show the ride information without claiming the rider boarded. |
| **Prepare to change** | For a linked next leg, enter by `A−15 min`; the last commercial stop may trigger it earlier when that stop is within 20 min of arrival. | “Change at Zürich HB · Next platform 10” | Arrival platform, next train number/operator, next departure time, and current connection outlook. If the next platform is unknown: “Check the departure board for IC 8.” |
| **Prepare to arrive** | Same final approach window when there is no linked connection. | “Get ready to leave · Bern in 8 min” | Arrival time and platform if known. This phase avoids treating the final station like an unexpected end to the activity. |
| **Make the connection** | From confirmed arrival or adjusted `A` until the next leg is boarded or departs. | “Go from platform 7 to 10 · 12 min left” | Next train number/operator and departure time. Show “On track,” “Tight,” or “Likely missed” only when current arrival/departure estimates and a valid minimum transfer time support that judgment. Without enough data, show the time available without a feasibility claim. Boarding or departure of the next leg returns to its on-the-train layout. |
| **Arrived** | At the shared journey's final destination, or the destination of a standalone trip. | “You've arrived in Bern” | Actual or latest known arrival time. End the Live Activity after a short readable period. |

Confirmed boarding or arrival from the existing location detector can advance a phase. A schedule boundary is a fallback, not proof of the rider's physical position. If evidence conflicts with the timetable, keep the instruction useful without asserting an unconfirmed location.

## Attention state

An attention state temporarily takes the primary message slot while the underlying journey phase continues. It should be prominent enough to catch a glance, then yield to the normal next action once resolved or acknowledged.

| Event | Primary copy example | Behavior |
| --- | --- | --- |
| Departure or transfer platform changes | “Platform changed: go to 8” | Show old → new platform in expanded/Lock Screen views. Send a timely notification when enabled; keep the new platform prominent until the rider has had time to see it. |
| Departure becomes earlier | “Now departs 13:58 · Head to platform 8” | Treat as urgent when it reduces available time. Do not bury it behind seat or ETA details. |
| Material delay | “12 min late · Now departs 14:14” | Show the new time. Avoid repeated alerts for small fluctuations; use the rider's notification threshold. |
| Connection becomes tight | “Connection tight · Go to platform 10” | Show minutes available and the transfer minimum in expanded view. Do not promise the train will be held. |
| Connection likely missed | “Connection likely missed” | Show the next train's time and platform if still useful. Offer an in-app action to review alternatives only after that feature exists. |
| Missing or stale live information | “Platform unconfirmed · Check station signs” | Keep the last known time labelled as such, with an update age in expanded/Lock Screen views. Do not issue a false platform-change alert based on stale data. |

Priority when events compete: likely missed connection or an earlier departure; platform change; tight connection; material delay; routine phase content. A newer correction replaces an outdated alert. Critical content should not flicker between messages on each feed refresh.

## Surface hierarchy

### Compact Dynamic Island

- **Leading:** operator logo and train number when they fit. If space is too narrow, preserve a recognizable train number first and show the logo in the expanded view.
- **Trailing:** one actionable value: departure time, platform with minutes to departure, minutes to arrival, or next platform during transfer. Avoid scrolling text and multi-item badges.
- **Minimal:** before departure, show whole minutes remaining with a small raised `m` (for example, `30ᵐ`). Other phases use a recognizable train/brand mark with the attention color when an urgent change is active.

### Expanded Dynamic Island

1. Persistent train identity: operator logo, train number; during transfer, current → next train.
2. One prominent next action or arrival fact.
3. One supporting row for headsign, platform, coach/seat, destination/ETA, or transfer outlook, selected by phase.
4. When a live change occurs, show what changed and the revised value. Tapping opens the relevant trip or connection detail.

The **Ready to go** expanded Island has three compact rows: operator logo and service category plus train number (“IC 2145”); the route and headsign (“IC8 to Brig”) in 20 pt bold with a yellow `P20` badge in 18 pt bold; then a positive countdown (“Departs in 14m 12s”) on the left and car/seat guidance on the right. The last row uses 12 pt medium. Expanded content has 14 pt horizontal margins. If space is tight, omit countdown seconds. Show seat numbers only when one car is saved with one or two seats. For three or more seats, show only that car; for multiple cars, show their numbers without seats.

### Lock Screen and Watch

The Lock Screen has room for the complete instruction, relevant times, platform, coach/seat, and a small “updated X min ago” label when using live data. The Watch Smart Stack favors the next action and one key time/platform; it follows the same phase and attention rules. Text must remain useful with large Dynamic Type and VoiceOver, with colors supplementing words rather than carrying meaning alone.

## Connections and journey identity

- Only legs imported together from the **same SBB shared journey** form a connection. Do not infer connections from independently saved trips with matching stations or times.
- Prefer one continuous Live Activity for a shared journey so the rider does not have to switch between leg activities at the transfer. Standalone trips retain one activity each. This requires the mutable activity state to carry the current and next train identity; ActivityKit attributes alone are fixed at activity creation.
- Match transfer stations by the shared journey's station identity; use the actual GTFS child stops when available to look up a minimum transfer time. A shared leg without an exact GTFS match can still show the next train/time and known platforms, but cannot claim the transfer is feasible without a valid minimum.
- Use the next leg's latest reliable departure and the current leg's latest reliable arrival for time available. If either is stale or missing, show neutral guidance and identify the uncertainty.
- A repeat import of the same shared journey may attach its journey identity to previously saved matching legs without overwriting saved seats, tickets, or edits. Older legs with no established shared-journey identity must not be paired by guesswork.

## Data and delivery requirements

- Static GTFS supplies schedule, headsign, station identity, service date, and possible transfer minimum. Shared SBB data supplies the imported itinerary's original absolute terminal times. The `trip_id` used for a live-service lookup is `Trip.gtfsTripId`, never the visible train number.
- The `sbb-rt` service supports only the trips listed in its `trips.json`; other trips retain schedule-based guidance. Fresh `/trips/{gtfsTripId}` data can update delay, platform, and predicted arrival when those fields are present. A feed refreshed every minute is not a guarantee that every field changed or is current.
- The current checked-in `sbb-rt` APNs path sends ordinary alert pushes. Remote Live Activity content updates need ActivityKit push-token registration, a Live Activity APNs topic/payload, token lifecycle handling, and server-side state/phase calculation. The app may also reconcile locally while open; background refresh is best-effort.
- Send remote updates for meaningful changes and attention events, not every countdown minute. Phase boundaries that must happen while the app is suspended need a server push or a time-based presentation that ActivityKit can render from already delivered timestamps. Push-to-start is a separate requirement for a guaranteed start at `T−30 min` after force-quit.
- If the live source becomes stale, retain the last confirmed value, reveal its age, and reduce certainty in the wording. Never silently revert a changed platform to the static schedule.

## Acceptance scenarios

1. A supported train starts its activity 30 minutes before adjusted departure and shows operator, number, headsign, departure time, and known platform.
2. At 10 minutes before departure, the action changes to finding the platform and includes the departure time. At 5 minutes, arrival/remaining-time information appears while an unconfirmed rider still gets a boarding cue.
3. A platform change after the rider sees the old one produces a clear old → new instruction and a timely alert when notifications are enabled.
4. An early or delayed departure shifts the phase boundaries and displayed times without jumping to another service date, including an overnight train.
5. Approaching a transfer in one SBB shared journey shows the next train and platform; at the station it shows the path between known platforms and a qualified connection outlook.
6. Two independently saved trips, or old imported legs without a common journey identity, never show a connection together.
7. Missing headsign, coach/seat, platform, transfer minimum, live feed, or boarding confirmation each has useful neutral copy and never produces invented certainty.
8. The compact Island remains legible with long station names, an absent operator logo, and an urgent attention message.
