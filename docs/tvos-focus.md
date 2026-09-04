# tvOS Focus Guidance

This note documents the focus rules we want future tvOS navigation work to
follow in the Silo Apple client. The short version: every interactive zone
needs exactly one focus owner. Let the tvOS focus engine own movement through a
stable graph of focusable controls, or build one custom focusable composite
control. Do not mix the two models.

## Focus Models

Use one of these patterns for a given control.

### Native Focus Graph

Use this for ordinary rows, grids, button groups, sheets, and menus where each
actionable item can be a real focus target.

- Render stable `Button`, `NavigationLink`, or `.focusable(true)` items.
  Every actionable element must be reachable by directional movement alone;
  tvOS has no Tab-key or pointer fallback.
- Use `.focusSection()` on a container so directional movement can enter it
  and land on its nearest focusable child, for example a sidebar column that
  does not line up with the grid beside it.
- Use `.focusScope(namespace)` together with `prefersDefaultFocus(in:)` and
  `resetFocus(in:)` to define where default focus lands inside that scope.
  `focusScope` does not affect directional movement; `focusSection` does.
- Use `@FocusState`, `prefersDefaultFocus`, `defaultFocus`, or `resetFocus` to
  seed or restore focus, not to fight the focus engine on every move.
  `defaultFocus` is evaluated when the view first appears and on automatic
  focus-state updates, not on user-driven moves, unless you pass
  `priority: .userInitiated`.
- Do not move focus programmatically in response to app state unless the
  focused item disappeared. Apple's Human Interface Guidelines say to avoid
  changing focus without the user's interaction; the one exception is moving
  focus to a neighbour when the focused item is removed.
- Rely on the system focus effect. Use `.focusEffectDisabled()` only when the
  control draws its own focus appearance, and keep that appearance visually
  consistent with the platform (scale, lift, highlight).
- Keep the focused subtree mounted and structurally stable while moving focus.
- Attach `onMoveCommand` only at intentional boundaries, such as "Up from the
  first card returns to the top menu." Do not intercept normal in-zone movement.
- Move focus geometry with layout (`padding`, `frame`, alignment), not
  `.offset`, because tvOS resolves focus from layout frames.

Good local examples:

- `TVCatalogGrid`
- `TVLibraryCollectionsView`
- `TVForYouDropdown`
- `TVProfileDropdown`

### Composite Focus Control

Use this when the visual control is one logical selector even though it renders
multiple highlighted rows or columns. A cascading selector is the main example.

- Make one container the real focus target with `.focusable(true)` and a single
  `@FocusState`. On tvOS the default `interactions` set already includes
  `.activate`, so `.focusable(true)` and
  `.focusable(true, interactions: .activate)` behave the same; use the
  explicit form only if the view is shared with macOS or iOS.
- Render rows as passive labels; do not make them `Button`s and do not attach
  per-row `.focused(...)` bindings.
- Store the highlighted row/column in ordinary `@State`.
- Handle all D-pad movement for the composite with one `onMoveCommand`.
- Commit the highlighted selection on Select, usually with `onTapGesture` on
  the focused container. Use `onExitCommand` for Menu/Back and
  `onPlayPauseCommand` for Play/Pause. Do not use `onKeyPress` for the Siri
  Remote; Apple documents it as hardware-keyboard input only.
- Add useful accessibility labels and button/selected traits to the composite
  or its rendered labels so VoiceOver still describes the action.

Good local example:

- `TVCascadeSelector`

## Skyline Paged Rows

`TVSkylineSectionFeed` is a sanctioned exception to ordinary native vertical
focus movement. Cards remain native focus targets and Left/Right remains owned
by each horizontal rail, but the feed owns Up/Down so one command moves exactly
one adjacent row page. The Series episode pager follows the same ownership
rule. Do not add a second vertical movement owner around either pager.

Keep the Up/Down hook on the focused card through `TVRowMoveHandler`, and carry
the pager's eligibility state through `SectionRow`, `MediaRow`, `MediaCard`, and
`EpisodeThumbCard`. Do not add a competing feed- or window-level move handler.

The Skyline pager must behave as one presentation system:

- Do not put the row pages in an outer vertical `ScrollView`. Do not use
  vertical `scrollTo`, `onScrollPhaseChange`, position reporting, or
  scroll-settle/watchdog timers to drive a page transition.
- Keep only the settled row and its immediate neighbours mounted in a
  non-lazy vertical window during phase one. Keep horizontal card collections
  lazy. A future continuous-hold implementation may widen the mounted window;
  it must not unmount the focus owner or move focus midway through a flight.
- Bundle each page's cards, header, and foreground marquee into the same
  transformed presentation layer. Each mounted page owns presentation state
  that is retained and frozen while it travels; do not create a separate
  outgoing snapshot when a transition starts. Adjacent foregrounds are
  immutable and accessibility-hidden; only the settled foreground is live for
  loading and accessibility. Reuse the marquee's live-presentation and logo
  loading gates for that distinction. Keep one shared backdrop pipeline
  outside the page window.
- Drive the window with one animated presentation value. Every page position
  and the window translation must read from the same frozen anchor table so
  the row and its foreground cannot acquire different offsets.

### Row anchors and rebasing

Skyline contains poster, 16:9 thumbnail, and square rows, so it must not assume
one fixed row stride. Build cumulative top anchors from row heights measured at
mount time. Measure size only, never live screen position, and do not publish
per-frame geometry during a flight.

Cache a measured height against a layout signature containing:

- section and row type,
- poster-size preference,
- caption mode,
- available width, and
- an `itemsVersion` that changes when item identity, order, or
  layout-affecting content changes.

Include section-title, locale, accessibility text sizing, and caption/metadata
presence in the appropriate layout-signature or `itemsVersion` component when
they can change measured height.

Freeze the active height and cumulative-anchor tables when a flight starts.
Measurements received during the flight go into a pending table. At rest,
apply the pending table, destination `baseIndex`, and settled presentation
index together in one transaction with animation disabled. A layout-signature
change while already at rest is also a non-animated rebase; returning from a
Settings preference change must never look like a row flight.

For a frozen cumulative-anchor function `anchor`, interpolate between adjacent
anchors for a fractional presentation index and calculate every page with the
same expression:

```text
renderedY(row) = bandTop + anchor(row) - anchor(presentedRowIndex)
```

Equivalently, a page's local origin and the window translation use the same
difference from `anchor(baseIndex)`. At an integer destination those
differences cancel. Rebasing `baseIndex` and the settled presentation index to
that destination therefore leaves its rendered pixels unchanged by
construction; do not calculate layout position and presentation translation
through independent geometry paths.

### Sticky column and adjacent preparation

Maintain a preferred, sticky horizontal column separately from any particular
row's clamped target:

- Update the sticky column only after genuine Left/Right focus movement.
- When a short destination clamps the requested column to its final item, do
  not overwrite the sticky column. Returning to a longer row must restore the
  original horizontal position.
- After horizontal focus rests for approximately 80 ms, pre-position both
  mounted adjacent rails at the sticky column with
  `Transaction(animation: nil)`. This work happens at horizontal rest, not on
  the first frame of a vertical flight.
- Track readiness by `(sectionId, stickyColumn, itemsVersion)` and associate it
  with the mounted rail's instance generation. A section refresh invalidates
  readiness even when the requested column is unchanged. Unmounting a rail or
  changing its layout signature also invalidates its preparations; a recreated
  rail must restore and acknowledge its target again.
- If Up/Down arrives before the matching preparation is ready, record the
  vertical intent, prepare the already-mounted destination without animation,
  yield at least one render turn, and wait for acknowledgement. The destination
  rail must acknowledge that the requested target is positioned and available
  before the flight begins; never infer readiness from elapsed time or combine
  unresolved horizontal positioning with vertical motion.

The destination's horizontal rail must not visibly move after focus lands.
Mounting the row alone is insufficient because its card collection remains
lazy; the exact destination card must already be positioned and available.
Preparation must not visibly snap a passive adjacent rail either. Keep the
mounted page's visible presentation immutable while its underlying rail is
prepared, or otherwise hide the repositioning until the prepared state can be
presented without a discontinuity.

Treat destination readiness as one composite condition: the row has a measured
height for its current layout signature, and its current rail instance has
acknowledged the sticky-column target. Do not begin a flight or consume a
pending command until that complete condition is true. Commands received while
preflight preparation is pending replace or cancel the pending intent under the
same one-command collapse rules.

### Motion and focus handoff

Phase one supports one adjacent flight, interruptible reversal, and one
replaceable pending adjacent command. Interpret each new command against the
active source and destination endpoints, not against the previous command:

- A command beyond the currently targeted destination becomes the one pending
  command. Repeating that direction replaces, rather than appends to, it.
- A command opposite an existing pending command cancels the pending command
  and leaves the active flight targeted at its current endpoint.
- With no pending command, a command selecting the other mounted endpoint
  retargets the active presentation immediately. This includes returning to
  the source and retargeting the destination again while a reversal is active.
- Consume a pending command only after the current endpoint has reported real
  focus and become the settled source for the next adjacent flight.

Do not keep an array of remote events. This phase does not promise unlimited
multi-row retargeting while only three rows are mounted.

During a flight:

- Keep the source row mounted as the focus owner and keep every unrelated row
  out of the focus graph. Presentation offsets may be render transforms only
  while focus remains locked to this stable layout owner.
- Retarget the same presentation value for a reversal. Use a critically
  damped, zero-bounce curve with an initial duration of approximately 0.40
  seconds as the device-tuning baseline.
- Attach a monotonically increasing generation to each target. Start the
  rebase only from the latest generation's animation completion; stale
  completion handlers must do nothing.
- Use `completionCriteria: .removed`, not `.logicallyComplete`. Rebasing while
  a spring tail is still moving creates a visible final hop.
- After the latest flight is fully removed, perform the non-animated rebase,
  enable the prepared destination, and issue one focus request. Retire source
  ownership only after the destination reports real focus. Do not perform
  mid-flight focus repairs.

The normal path has one post-rebase focus request. Give its matching generation
a bounded confirmation window. If the prepared target remains valid but the
request is rejected, perform a bounded post-flight retry; if confirmation still
fails, invalidate the generation and rebase without animation to the still-
focused source. This is focus-failure recovery, not a motion or scroll-settle
watchdog, and it must never run during a flight.

When a reversal finishes back at its source, invalidate the abandoned
destination generation and rebase to the source without issuing a focus
request; the source already owns focus and assigning the same focus value may
produce no confirmation callback.

Stable section identity, not array index, is authoritative across data
updates. A section insertion, removal, or reorder during a flight invalidates
the active generation and completion. If the confirmed source still exists,
rebase to its new index without animation and discard the flight. If it was
removed, choose the nearest surviving row at its former index (prefer the next
row, then the previous row), prepare its sticky-column target, rebase without
animation, and request focus because the former focused subtree no longer
exists. Apply pending height measurements in the same rebase transaction.

Preserve both vertical ownership boundaries from the existing feed:

- Up from the first settled row hands focus to the top menu instead of
  starting a page flight.
- A Down command that enters the first row from the top menu is consumed by an
  entry lock and must not also page immediately to the second row.

### Backdrop ownership

Backdrop work is not a motion-completion signal. Once the pager has a real
completion callback:

- remove Skyline's `onScrollPhaseChange`, `setBackdropDeferred`, scroll-phase
  hold, hold-cap, and warm-during-scroll coupling rather than leaving them
  dormant;
- preserve the existing render-sized decode and cache path;
- warm only the latest prepared candidates without creating a backdrop model
  per mounted row; and
- promote the destination foreground to live state and begin its backdrop
  crossfade only after both the latest `.removed` completion and real
  destination-focus confirmation, followed by the short rest debounce. A later
  command cancels an obsolete candidate before it can display.

With Reduce Motion enabled, do not run a flight. Prepare as necessary, rebase
directly to the adjacent destination without animation, request focus, and
release its live foreground and backdrop state on the same turn that real
destination focus is confirmed, with no crossfade or hold. Artwork that is not
decoded yet appears when ready; its thumbhash placeholder must keep the hero
from becoming blank.

### Verification contract

The coordinator should be independently testable. Cover adjacent moves,
reversal, collapsed repeated input, stale animation completions, first/last
boundaries, top-menu entry, sticky-column clamping, item replacement and
reordering, row removal during a flight, pending height measurements, layout
signature changes, and Reduce Motion.

Use the fixed 24-command navigation sequence below for every physical-device
performance comparison. The test dataset must keep the first three Skyline
rows stable, give each at least seven items, and include representative poster,
16:9 thumbnail, and square heights across those rows. If the active Home data
cannot provide that mix, run an additional mixed-height fixture before calling
the anchor implementation verified. Start on the first row's first card with
the top menu closed, Reduce Motion off, all row measurements settled, and
adjacent preparation ready. Use directional clicks rather than swipes.

1. Click Right six times, 150 ms apart, then rest for 250 ms so column 6 and
   both adjacent preparations settle. These are commands 1–6.
2. Click Down, wait for destination-focus confirmation plus 250 ms, then click
   Up and wait again. Repeat that Down/Up pair once. These are commands 7–10.
3. Click Down and click Up 100 ms later, then wait for the reversal to settle
   back on the source. These are commands 11–12.
4. Click Up to enter the top menu, wait for confirmation, then click Down once
   to re-enter the first row. Wait for confirmation that the entry lock
   consumed the command without paging. These are commands 13–14.
5. Click Down twice with 100 ms between clicks and wait until the second
   destination has focus. Click Up twice with 100 ms between clicks and wait
   until the first row has focus again. These are commands 15–18.
6. Click Down, Down, Up at 100 ms intervals and wait for the collapsed command
   to settle on row 1: the final Up cancels the pending second Down without
   reversing the active row-0-to-row-1 flight. Wait for preparation
   acknowledgement from row 2's current mounted rail. Then click Down, Up,
   Down at 100 ms intervals and wait for row 2 to settle: the active
   presentation retargets row 2, row 1, and row 2 without an intermediate focus
   handoff. These are commands 19–24.

Record the commit, build, device and tvOS version, section/item dataset
version, cache mode, Reduce Motion state, active refresh rate, and command
timestamps with every capture. In a Release build, run the sequence three
times with warmed artwork. The acceptance criteria are:

- zero missed display deadlines at the active refresh rate, corroborated by
  zero commit hitches in Instruments' Animation Hitches template;
- no captured frame in which a marquee and its row have different vertical
  offsets;
- no backdrop crossfade beginning before the latest `.removed` completion;
- no visible horizontal rail movement during adjacent preparation or after
  destination focus lands; and
- no flight completing with focus stranded on a visually displaced row.

Run additional physical-device visual checks outside the performance sequence:

- From a long row, establish a sticky column beyond the end of a short
  adjacent row, move into the short row, then return. The short-row clamp must
  not overwrite the preferred column.
- Swipe far to the right and immediately press Up or Down before the 80 ms rest
  preparation can complete. The pager must wait for acknowledged preparation;
  no row may flip, wobble, or reposition horizontally during the flight.
- Enable Reduce Motion and repeat vertical moves in both directions. Rows must
  rebase without travel, the destination must receive focus, and the backdrop
  must update without a crossfade or hold.

The opt-in hitch logger must derive each frame's budget from
`CADisplayLink.targetTimestamp - timestamp`, not from a fixed 16 ms value, and
record the active rate in the capture header. Television output can be 50,
59.94, or 60 Hz depending on Match Frame Rate state.

Define a repeatable cold-cache run separately. A normal relaunch is still warm
because Nuke's disk cache survives it; use a debug-only launch argument that
clears both the image data and memory caches at startup. Cold-run hitch counts
are informational because they include network and first-decode work, but all
visual criteria remain mandatory. Do not delete the app merely to clear image
caches because that also resets unrelated application state and disrupts the
signed-in device setup.

Review the device recording frame by frame, preferably from an HDMI capture.
Samples 50 ms apart skip multiple frames and cannot rule out a one-frame
rebase hop. The hitch logger detects main-thread deadline misses; only
Instruments distinguishes commit hitches from render work, and neither replaces
the visual frame review.

## Do Not Mix Models

The broken pattern is a hybrid control:

- row `Button`s participate in native focus,
- the same rows also use `@FocusState`,
- a parent or window-level handler manually changes that focus in response to
  directional presses.

That gives the same physical remote press to multiple owners. The symptom is a
single D-pad press producing multiple focus writes, such as:

```text
cascade.move/right library(1)
cascade.focus -> section(1, recommended)
cascade.focus -> section(1, browse)
cascade.focus -> nil
bar.focusedItem -> Calendar
```

When this happens, stop adding press interceptors. Decide which focus model the
control should use, then remove the other one.

## Top Menu Ownership

The top menu has three conceptual states:

- `closed`: no panel is visible; focus belongs to content or the bar.
- `preview`: a dwell-open panel is visible, but the bar still owns focus and
  the panel is passive.
- `entered`: the user pressed Down or otherwise entered the panel; the panel
  owns focus and the bar is inert until the panel closes.

Implementation details may use booleans, but the state machine above is the
contract. In entered mode, it should be impossible for the bar to accept focus
on another tab behind the panel. Treat `panelHasFocus` as telemetry from the
child panel, not as the source of truth for ownership. The durable ownership
signal is the host's "entered panel" state.

When closing a panel, choose the next owner explicitly:

- Menu/Back closes and returns focus to the panel's bar anchor.
- Down past the last row closes and hands focus to page content.
- Selecting a panel row closes, updates route/scope state, and then hands focus
  to the destination content.

## Debugging Checklist

When tvOS focus feels random, capture logs for the ownership boundary first:

- current focused top-bar item
- open panel
- whether the panel is in preview or entered mode
- whether the panel reports focus
- the panel's internal highlighted item
- every `onMoveCommand` direction handled by the active owner

Expected cascade movement after entering a Movies panel looks like this:

```text
host.enterOpenPanel openPanel=Movies
cascade.panelFocused -> true selection=library(1)
cascade.move direction=right focus=library(1)
cascade.focus -> section(1, recommended)
cascade.move direction=down focus=section(1, recommended)
cascade.focus -> section(1, collections)
```

Unexpected signs:

- the bar logs a different focused tab while a panel is entered,
- a single D-pad press produces multiple panel focus writes,
- panel focus becomes `nil` without an explicit close or content handoff,
- `onMoveCommand` is attached broadly and also expected to pass native movement
  through the same zone.

## References

- Human Interface Guidelines, Focus and selection (system focus effects, do
  not move focus without user interaction, every tvOS element must be
  reachable):
  https://developer.apple.com/design/human-interface-guidelines/focus-and-selection
- UIKit, About focus interactions for Apple TV (focus engine rules; only the
  engine moves focus directionally):
  https://developer.apple.com/documentation/uikit/about-focus-interactions-for-apple-tv
- SwiftUI Focus overview (focusable, FocusState, focusScope, focusSection,
  default focus, resetFocus, focus effects):
  https://developer.apple.com/documentation/swiftui/focus
- SwiftUI `focusSection()`:
  https://developer.apple.com/documentation/swiftui/view/focussection()
- SwiftUI `focusable(_:interactions:)`:
  https://developer.apple.com/documentation/swiftui/view/focusable(_:interactions:)
- SwiftUI `defaultFocus(_:_:priority:)`:
  https://developer.apple.com/documentation/swiftui/view/defaultfocus(_:_:priority:)
- SwiftUI `onMoveCommand(perform:)`, `onExitCommand(perform:)`,
  `onPlayPauseCommand(perform:)`:
  https://developer.apple.com/documentation/swiftui/view/onmovecommand(perform:)
- Focus Cookbook sample (WWDC23, "The SwiftUI cookbook for focus"):
  https://developer.apple.com/documentation/swiftui/focus-cookbook-sample
