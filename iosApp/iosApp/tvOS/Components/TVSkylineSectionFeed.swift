#if os(tvOS)
import SwiftUI

/// Shared Skyline landing layout (§6.1): an ambient backdrop, a focus
/// marquee that passively previews the focused card, and programmatically
/// paged section rows. Used by **both** Home and the library Browse tabs
/// so the two stay pixel-identical — the only difference is the sections each
/// feeds in.
///
/// Row-to-row movement is coordinated as one adjacent-row transaction. Only
/// the current row and its named destination participate in focus while the
/// outer strip and the destination card move from the same request.
struct TVSkylineSectionFeed: View {
    /// Section rows to page through, in order (already filtered to
    /// non-empty, non-featured by the caller).
    let sections: [ResolvedSection]
    /// Marquee scale. Every Skyline landing currently uses `.home` so the
    /// pages render identically; kept as a parameter for explicit variants.
    var marqueeScale: TVFocusMarquee.Scale = .home
    /// Focus hand-down token from the shell — claims the first card on entry.
    var focusRequest: Int = 0
    /// Return token from a card-pushed detail page. Every row receives it, but
    /// only the row that owned focus before the push may reclaim its last card.
    var detailReturnFocusRequest: Int = 0
    /// Whether the top menu currently holds focus. A late content load must
    /// not steal focus while the user is up in the menu.
    var isTopMenuFocused: Bool = false
    /// Up at the first page hands focus to the top bar.
    let onTopMenuFocusRequest: (() -> Void)?
    /// Open a content item (detail).
    let onItemTap: (_ destinationContentId: String, _ item: SectionItem) -> Void
    /// Optional Home-only action. Library feeds leave this nil.
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil
    /// Optional Home-only watched-state mutation. Library feeds leave this nil.
    var onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil

    /// Immediate foreground content with a separately delayed backdrop.
    @State private var marqueeModel = TVFocusMarqueeModel()
    /// Owns every explicit row-to-row focus handoff and remembers each row's
    /// last card without making horizontal focus changes rebuild the feed.
    @State private var rowNavigation = TVSkylineRowNavigationModel()
    /// Entry tokens that arrived before any row mounted — sections load
    /// async, so the initial hand-down would land on nothing.
    @State private var pendingFocusRequest: Int?
    @State private var lastAppliedRequest = 0
    /// The row that owns card focus or its context-menu dismissal flow. Unlike
    /// the marquee preview, this is cleared when focus moves into chrome.
    @State private var focusRestorationOwnerSectionId: String?
    /// Last row that reported real card focus. Horizontal movement stays an
    /// immediate marquee update; vertical movement selects which measured row
    /// the live marquee follows without taking ownership from native focus.
    @State private var focusedSectionId: String?
    /// The prior row's immutable foreground while a vertical scroll is in
    /// flight. It remains attached to that row's measured position, so rapid
    /// presses replace one snapshot rather than queueing animation layers.
    @State private var outgoingMarquee: TVSkylineOutgoingMarquee?
    /// Debounced warm-up for the cards an adjacent Up/Down move can target.
    /// It lets their logo art exist on the first transition frame instead of
    /// swapping from text while posters are crossing it.
    @State private var adjacentLogoWarmupTask: Task<Void, Never>?
    /// Geometry updates are isolated from the feed so following a row at the
    /// display refresh rate does not rebuild its card and focus subgraphs.
    @State private var rowMotion = TVSkylineRowMotionModel()
    /// Integer page boundary expressed as a CGFloat so the poster strip and
    /// both marquee layers can share the exact same animated top-overflow
    /// transform. Rows before this boundary live above the physical screen.
    @State private var rowPresentationBoundary: CGFloat = 0
    /// Repeated remote presses received during a real vertical handoff. They
    /// are replayed one adjacent page at a time after each anchor settles.
    @State private var queuedVerticalMoves: [Int] = []

    private static let maximumQueuedVerticalMoves = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            TVSkylineBackdrop(model: marqueeModel)

            // Each foreground is positioned from its own row's live geometry.
            // It sits below the poster plane so an entering title can never
            // paint through a row that is naturally crossing in front of it.
            TVSkylineTrackedMarquees(
                model: marqueeModel,
                motion: rowMotion,
                scale: marqueeScale,
                sectionIds: sections.map(\.id),
                focusedSectionId: focusedSectionId,
                outgoing: outgoingMarquee,
                isTransitioning: rowNavigation.isInFlight,
                presentationBoundary: rowPresentationBoundary
            )

            // Programmatic scrolling and native horizontal focus stay in the
            // bottom band. Rendering
            // overflows through the full screen above the tracked marquees.
            scrollingRows
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: TVSkylineRowMotionCoordinateSpace.name)
        .onAppear {
            marqueeModel.resume()
            seedMarqueeFromFirstItem()
            requestEntryFocus(focusRequest)
        }
        .onDisappear {
            adjacentLogoWarmupTask?.cancel()
            adjacentLogoWarmupTask = nil
            queuedVerticalMoves.removeAll(keepingCapacity: true)
            marqueeModel.suspend()
            rowNavigation.cancel()
        }
        .onChange(of: rowNavigation.isInFlight) { _, isInFlight in
            if !isInFlight {
                outgoingMarquee = nil
                rowMotion.stopTracking(restingSectionId: focusedSectionId)
                if !isTopMenuFocused {
                    // A watchdog completion means the destination never
                    // reported real focus. Restore ownership to the last
                    // accepted row so a failed claim cannot poison the next
                    // Up/Down command or a later detail-return repair.
                    restoreConfirmedPresentation()
                }
                beginNextQueuedVerticalMove()
            }
        }
        .onChange(of: focusRequest) { _, request in requestEntryFocus(request) }
        .onChange(of: isTopMenuFocused) { _, isFocused in
            if isFocused {
                queuedVerticalMoves.removeAll(keepingCapacity: true)
                rowNavigation.cancel()
                focusRestorationOwnerSectionId = nil
            }
        }
        // Rows mount only after the async section load; a deferred entry
        // token re-fires once they exist.
        .onChange(of: sections.map(\.id)) { _, _ in
            seedMarqueeFromFirstItem()
            synchronizePresentationBoundary()
            if let pending = pendingFocusRequest { requestEntryFocus(pending) }
        }
    }

    // MARK: - Rows

    /// Programmatically paged row scrolling whose layout remains in the lower band.
    /// Rendering may overflow upward during a scroll so the departing row can
    /// cross the hero area instead of vanishing at a horizontal clip line.
    @ViewBuilder
    private var scrollingRows: some View {
        GeometryReader { proxy in
            let bandHeight = proxy.size.height * ContinuumTheme.Skyline.rowBandHeightFraction
            // Position the focusable viewport with layout, not a render
            // offset. Its bottom must match the screen's bottom: otherwise
            // tvOS can resolve directional clicks against offscreen space
            // while a swipe still pans far enough to reveal the next target.
            let bandTop = min(
                proxy.size.height,
                max(0, proxy.size.height - bandHeight + ContinuumTheme.Skyline.landingContentVerticalOffset)
            )
            let visibleBandHeight = max(0, proxy.size.height - bandTop)
            let trailingPreviewPadding = max(
                0,
                visibleBandHeight - ContinuumTheme.Skyline.rowBandBottomInset
            )

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // Bound the live view graph to nearby rows. Keeping the
                    // entire feed mounted makes focus and scroll transactions
                    // traverse offscreen card, image, and button subgraphs.
                    // The native scroll container loads directional targets;
                    // its viewport uses the corrected layout frames above.
                    LazyVStack(alignment: .leading, spacing: ContinuumTheme.Skyline.rowBandPreviewSpacing) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            // Keep the scroll-layout probe outside the visual
                            // overflow transform. Lazy layout may stop reporting
                            // a departing row once it leaves the lower viewport;
                            // the separately animated overflow still carries both
                            // its posters and its marquee through the screen edge.
                            ZStack(alignment: .topLeading) {
                                featuredRow(section, index: index)
                                    .modifier(
                                        TVSkylineRowOverflowPresentation(
                                            topOverflowTravel: reduceMotion ? 0 : bandTop,
                                            rowIndex: CGFloat(index),
                                            presentationBoundary: rowPresentationBoundary
                                        )
                                    )
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .modifier(
                                TVSkylineRowPositionReporter(
                                    sectionId: section.id,
                                    motion: rowMotion
                                )
                            )
                                .id(section.id)
                        }
                    }
                    .scrollTargetLayout()
                    // Allows the final row to top-align like every prior row,
                    // with a blank preview area underneath instead of clamping.
                    .padding(.bottom, trailingPreviewPadding)
                }
                .scrollTargetBehavior(.viewAligned)
                // Match the detail episode pager: vertical movement is one
                // named programmatic page at a time. The nested horizontal
                // rails opt back into native scrolling below.
                .scrollDisabled(true)
                // Visual overflow is the key Plex behavior: native focus and
                // layout stay in the lower band while complete rows cross the
                // hero area and leave through the physical screen boundary.
                .scrollClipDisabled()
                // Hold the independent backdrop swap until the physical strip
                // settles, then retire the one outgoing foreground snapshot.
                .onScrollPhaseChange { _, phase in
                    marqueeModel.setBackdropDeferred(phase != .idle)
                    rowNavigation.setScrollMoving(phase != .idle)
                }
                // Drive the vertical page and destination card from one exact
                // request so tvOS cannot settle on a different logical row.
                .onChange(of: rowNavigation.request?.generation) { _, _ in
                    if let request = rowNavigation.request {
                        let destinationIndex = sections.firstIndex {
                            $0.id == request.sectionId
                        }
                        withAnimation(reduceMotion ? nil : TVSkylineRowNavigationModel.animation) {
                            if let destinationIndex {
                                rowPresentationBoundary = CGFloat(destinationIndex)
                            }
                            scrollProxy.scrollTo(request.sectionId, anchor: .top)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: visibleBandHeight, alignment: .topLeading)
            .padding(.top, bandTop)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func featuredRow(_ section: ResolvedSection, index: Int) -> some View {
        let request = rowNavigation.request
        let ownsRequest = request?.sectionId == section.id

        SectionRow(
            section: section,
            onItemTap: onItemTap,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching,
            onSetWatched: onSetWatched,
            // Cold entry: let the engine's *initial* focus resolution land on
            // the first card so it renders already focused instead of growing
            // a few frames after the page paints. `.automatic` keeps d-pad
            // movement between rows geometric — only system-initiated
            // resolutions use the preference. The imperative entry token
            // below is unchanged and covers every other entry path.
            prefersDefaultFocusOnFirstItem: index == 0,
            defaultFocusPriority: .automatic,
            focusRequest: ownsRequest ? (request?.generation ?? 0) : 0,
            focusRequestItemId: ownsRequest ? request?.itemId : nil,
            detailReturnFocusRequest: detailReturnFocusRequest,
            isFocusEnabled: rowNavigation.isFocusEnabled(
                sectionId: section.id,
                isInitialSection: index == 0
            ),
            // Each focused card owns its vertical command. The coordinator
            // names exactly one adjacent row; first-row Up still crosses into
            // the top menu while Left/Right remain native in this rail.
            onMoveUp: { requestVerticalMove(from: section.id, delta: -1) },
            onItemFocus: { item in
                acceptFocusedItem(item, in: section)
            },
            cardWidth: ContinuumTheme.Skyline.densePosterCardWidth,
            cardVerticalPadding: ContinuumTheme.Skyline.rowBandCardVerticalPadding,
            onMoveDown: { requestVerticalMove(from: section.id, delta: 1) },
            focusRestorationOwner: Binding(
                get: { focusRestorationOwnerSectionId == section.id },
                set: { ownsRestoration in
                    // A row may reassert ownership while its context menu is
                    // dismissing. Ignore false writes—the next real card focus,
                    // top-menu focus, or row change remains authoritative.
                    if ownsRestoration {
                        focusRestorationOwnerSectionId = section.id
                    }
                }
            )
        )
        // `scrollDisabled(true)` is inherited. Re-enable only the row's inner
        // horizontal ScrollView, as the anchored episode rail does.
        .environment(\.isScrollEnabled, true)
        .modifier(TVSkylineArtworkVisibility())
    }

    // MARK: - Focus

    /// Entry focus → the first row's first card. Tokens that arrive before
    /// the rows mount wait as a pending claim. A claim is dropped while the
    /// menu holds focus, so neither a late fetch (library loads async, so its
    /// feed mounts after entry) nor a stale token ever yanks focus away from
    /// the user once they've moved up into the bar. On a normal tab entry the
    /// shell has already relinquished the menu, so the claim proceeds. The
    /// request token is monotonic, so re-entry always lands fresh while
    /// onAppear/onChange can't double-claim the same value.
    private func requestEntryFocus(_ request: Int) {
        guard request > 0 else { return }
        guard !sections.isEmpty else {
            pendingFocusRequest = request
            return
        }
        pendingFocusRequest = nil
        if isTopMenuFocused { return }
        guard request != lastAppliedRequest else { return }
        lastAppliedRequest = request
        guard let firstSection = sections.first,
              let firstItem = firstSection.items.first else { return }
        let firstSectionId = firstSection.id
        focusRestorationOwnerSectionId = firstSectionId
        // Lock this entry transaction before deferring the focus publication.
        // A Down command can enter the first row and reach that row's move
        // handler in the same event; the lock makes that one command end here
        // instead of immediately paging on to the second row.
        let entryGeneration = rowNavigation.prepareFocus(
            sectionId: firstSectionId,
            itemId: firstItem.contentId,
            expectsScroll: focusedSectionId != firstSectionId
        )
        // Publish one request on the next turn. The vertical ScrollView and
        // destination MediaRow observe the same generation: one aligns the
        // row while the other's bounded focus claim lands on its first card.
        DispatchQueue.main.async {
            guard !isTopMenuFocused,
                  sections.first?.id == firstSectionId else { return }
            rowNavigation.publishPreparedFocus(generation: entryGeneration)
        }
    }

    /// A focus report from the requested destination completes the handoff.
    /// Reports from another row during tvOS's mid-scroll repair are ignored so
    /// they cannot retarget the hero or steal restoration ownership.
    private func acceptFocusedItem(_ item: SectionItem, in section: ResolvedSection) {
        guard rowNavigation.acceptFocus(
            sectionId: section.id,
            itemId: item.contentId
        ) else { return }

        focusRestorationOwnerSectionId = section.id
        previewFocusedItem(item, in: section)
        scheduleAdjacentLogoWarmup(around: item, in: section)
    }

    /// Resolve one deterministic adjacent row. Returning to a row restores its
    /// last card; first entry uses the closest card index from the source row.
    /// Vertical selection is an exact programmatic page; horizontal movement
    /// remains entirely owned by each MediaRow.
    private func requestVerticalMove(from sourceSectionId: String, delta: Int) {
        guard delta == -1 || delta == 1 else { return }
        if rowNavigation.isInFlight {
            // Entry from the top menu deliberately consumes its originating
            // Down event. Only an already-running row handoff may queue a
            // genuinely repeated press.
            if rowNavigation.acceptsQueuedVerticalMoves {
                enqueueVerticalMove(delta)
            }
            return
        }

        beginVerticalMove(from: sourceSectionId, delta: delta)
    }

    @discardableResult
    private func beginVerticalMove(from sourceSectionId: String, delta: Int) -> Bool {
        guard rowNavigation.confirmedSectionId == nil
                || rowNavigation.confirmedSectionId == sourceSectionId,
              let sourceIndex = sections.firstIndex(where: { $0.id == sourceSectionId }) else {
            return false
        }

        let destinationIndex = sourceIndex + delta
        guard sections.indices.contains(destinationIndex) else {
            if destinationIndex < sections.startIndex {
                queuedVerticalMoves.removeAll(keepingCapacity: true)
                focusRestorationOwnerSectionId = nil
                onTopMenuFocusRequest?()
            }
            return false
        }

        let source = sections[sourceIndex]
        let destination = sections[destinationIndex]
        guard !destination.items.isEmpty else { return false }

        let sourceItemId = rowNavigation.lastFocusedItemId(in: source.id)
            ?? (focusedSectionId == source.id ? marqueeModel.content?.contentId : nil)
        let sourceItemIndex = sourceItemId
            .flatMap { id in source.items.firstIndex(where: { $0.contentId == id }) }
            ?? 0
        let rememberedDestinationId = rowNavigation.lastFocusedItemId(in: destination.id)
            .flatMap { rememberedId in
                destination.items.contains(where: { $0.contentId == rememberedId })
                    ? rememberedId
                    : nil
            }
        let targetItemId = rememberedDestinationId
            ?? destination.items[min(sourceItemIndex, destination.items.count - 1)].contentId
        guard let targetItem = destination.items.first(where: { $0.contentId == targetItemId }) else {
            return false
        }

        // Prime the incoming foreground before scrolling. It is immediately
        // attached to the destination row's measured geometry, so its logo
        // and metadata enter with that row even if tvOS takes another frame
        // to complete the real focus claim.
        // Make the destination the restoration owner before its request is
        // published; the target MediaRow can observe both in the same render.
        focusRestorationOwnerSectionId = destination.id
        rowNavigation.beginVerticalMove(
            sectionId: destination.id,
            itemId: targetItemId
        )
        previewFocusedItem(targetItem, in: destination)
        return true
    }

    /// Preserve one row per physical press while still accepting quick repeat
    /// input. Reversing before a queued move runs cancels the opposite pending
    /// step, which keeps rapid direction changes responsive rather than making
    /// the user wait through a stale round trip.
    private func enqueueVerticalMove(_ delta: Int) {
        if queuedVerticalMoves.last == -delta {
            queuedVerticalMoves.removeLast()
            return
        }
        guard queuedVerticalMoves.count < Self.maximumQueuedVerticalMoves else { return }
        queuedVerticalMoves.append(delta)
    }

    /// Retire the old foreground first, then begin at most one queued adjacent
    /// transaction on the next main turn. That one-frame state boundary keeps
    /// a completed outgoing logo from being reused by the following handoff.
    private func beginNextQueuedVerticalMove() {
        guard !queuedVerticalMoves.isEmpty, !isTopMenuFocused else { return }
        DispatchQueue.main.async {
            guard !rowNavigation.isInFlight, !isTopMenuFocused else { return }
            while !queuedVerticalMoves.isEmpty {
                let delta = queuedVerticalMoves.removeFirst()
                guard let sourceSectionId = rowNavigation.confirmedSectionId
                    ?? focusedSectionId else {
                    queuedVerticalMoves.removeAll(keepingCapacity: true)
                    return
                }
                if beginVerticalMove(from: sourceSectionId, delta: delta) {
                    return
                }
                if isTopMenuFocused { return }
            }
        }
    }

    /// Section data can be replaced asynchronously. Keep the visual boundary
    /// attached to the same logical row without animating a data refresh.
    private func synchronizePresentationBoundary() {
        let sectionId = rowNavigation.request?.sectionId
            ?? rowNavigation.confirmedSectionId
            ?? focusedSectionId
            ?? sections.first?.id
        guard let sectionId,
              let index = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        withTransaction(Transaction(animation: nil)) {
            rowPresentationBoundary = CGFloat(index)
        }
    }

    private func previewFocusedItem(_ item: SectionItem, in section: ResolvedSection) {
        let candidate = TVMarqueeContent(
            item: item,
            rowTitle: section.title,
            isContinueWatching: section.isContinueWatchingSection
        )
        let outgoing = makeOutgoingMarquee(
            to: section.id,
            outgoingContent: marqueeModel.content,
            outgoingEnrichment: marqueeModel.enrichment
        )

        if let outgoing {
            outgoingMarquee = outgoing
        }
        focusedSectionId = section.id
        if rowNavigation.isInFlight {
            rowMotion.track(
                liveSectionId: section.id,
                outgoingSectionId: outgoing?.sectionId ?? outgoingMarquee?.sectionId
            )
        }
        marqueeModel.preview(
            candidate,
            neighborBackdropURLs: neighborBackdropURLs(around: item, in: section)
        )
    }

    /// Warm only the two logo candidates reachable by the next vertical press.
    /// Horizontal scrubbing is debounced, and the target mirrors the pager's
    /// remembered-card / closest-index rule exactly.
    private func scheduleAdjacentLogoWarmup(
        around item: SectionItem,
        in section: ResolvedSection
    ) {
        adjacentLogoWarmupTask?.cancel()
        guard let sourceIndex = sections.firstIndex(where: { $0.id == section.id }),
              let itemIndex = section.items.firstIndex(where: { $0.contentId == item.contentId }) else {
            adjacentLogoWarmupTask = nil
            return
        }

        adjacentLogoWarmupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled,
                  focusedSectionId == section.id,
                  marqueeModel.content?.contentId == item.contentId else { return }

            var seen = Set<URL>()
            let urls = [-1, 1].compactMap { delta -> URL? in
                let neighborIndex = sourceIndex + delta
                guard sections.indices.contains(neighborIndex) else { return nil }
                let neighbor = sections[neighborIndex]
                guard !neighbor.items.isEmpty else { return nil }
                let remembered = rowNavigation.lastFocusedItemId(in: neighbor.id)
                    .flatMap { rememberedId in
                        neighbor.items.first(where: { $0.contentId == rememberedId })
                    }
                let candidate = remembered
                    ?? neighbor.items[min(itemIndex, neighbor.items.count - 1)]
                guard let logoUrl = candidate.logoUrl,
                      !logoUrl.isEmpty,
                      let url = URL(string: logoUrl),
                      seen.insert(url).inserted else { return nil }
                return url
            }
            PosterImageCache.prefetchOriginalArtwork(urls)
        }
    }

    /// If an interrupted focus claim times out, return the foreground and
    /// restoration ownership to the last row that actually reported focus.
    /// This also prevents an unconfirmed destination's metadata from being
    /// stranded at a stale off-screen row coordinate.
    private func restoreConfirmedPresentation() {
        let confirmedSectionId = rowNavigation.confirmedSectionId ?? focusedSectionId
        focusRestorationOwnerSectionId = confirmedSectionId
        guard let confirmedSectionId,
              confirmedSectionId != focusedSectionId,
              let section = sections.first(where: { $0.id == confirmedSectionId }) else {
            return
        }

        let rememberedItemId = rowNavigation.lastFocusedItemId(in: confirmedSectionId)
        let item = rememberedItemId
            .flatMap { itemId in section.items.first(where: { $0.contentId == itemId }) }
            ?? section.items.first
        guard let item else { return }

        focusedSectionId = confirmedSectionId
        marqueeModel.preview(
            TVMarqueeContent(
                item: item,
                rowId: section.id,
                rowTitle: section.title,
                isContinueWatching: section.isContinueWatchingSection
            ),
            neighborBackdropURLs: neighborBackdropURLs(around: item, in: section)
        )
    }

    /// Retains the prior row's foreground only for a genuine row boundary.
    /// Both the snapshot and the live destination foreground are positioned
    /// from row geometry, so there is no independently timed transition to
    /// flash, drift, or finish ahead of the poster strip.
    private func makeOutgoingMarquee(
        to destinationSectionId: String,
        outgoingContent: TVMarqueeContent?,
        outgoingEnrichment: TVMarqueeEnrichment?
    ) -> TVSkylineOutgoingMarquee? {
        guard let sourceSectionId = focusedSectionId,
              sourceSectionId != destinationSectionId,
              let sourceIndex = sections.firstIndex(where: { $0.id == sourceSectionId }),
              let destinationIndex = sections.firstIndex(where: { $0.id == destinationSectionId }),
              abs(sourceIndex - destinationIndex) == 1,
              let outgoingContent else { return nil }

        return TVSkylineOutgoingMarquee(
            sectionId: sourceSectionId,
            snapshot: TVSkylineMarqueeSnapshot(
                content: outgoingContent,
                enrichment: outgoingEnrichment
            )
        )
    }

    /// Section-level backdrops of the cards on either side of `item` in its
    /// row. Only direct backdrops qualify: episodes and items without one
    /// resolve their hero art from detail enrichment, which is a metadata
    /// request the marquee already rate-limits and must not be duplicated
    /// here for cards the user may never rest on.
    private func neighborBackdropURLs(
        around item: SectionItem,
        in section: ResolvedSection
    ) -> [String] {
        guard let index = section.items.firstIndex(where: { $0.id == item.id }) else { return [] }
        let radius = ContinuumTheme.Skyline.marqueeNeighborBackdropPrefetchRadius
        let window = section.items.indices.clamped(to: (index - radius)..<(index + radius + 1))
        return window.compactMap { neighborIndex -> String? in
            guard neighborIndex != index else { return nil }
            let neighbor = section.items[neighborIndex]
            guard neighbor.type.lowercased() != "episode",
                  let url = neighbor.backdropUrl, !url.isEmpty else { return nil }
            return url
        }
    }

    /// Seed the first card as soon as sections exist, so cold entry does not
    /// wait for a focus report or the backdrop rest delay. A later focus
    /// report remains authoritative if the engine lands on another card.
    private func seedMarqueeFromFirstItem() {
        guard marqueeModel.content == nil,
              let section = sections.first,
              let item = section.items.first else { return }
        focusedSectionId = section.id
        rowNavigation.seedConfirmedSection(section.id)
        marqueeModel.seed(
            TVMarqueeContent(
                item: item,
                rowId: section.id,
                rowTitle: section.title,
                isContinueWatching: section.isContinueWatchingSection
            )
        )
        scheduleAdjacentLogoWarmup(around: item, in: section)
    }

}

/// Cancel artwork work when a row leaves the viewport without removing its
/// buttons from the native focus graph. Visibility changes only at the edge.
private struct TVSkylineArtworkVisibility: ViewModifier {
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .environment(\.tvArtworkLoadingEnabled, isVisible)
            .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
    }
}

/// Observe preview changes at the leaves. Reading the model's properties in
/// the feed's body makes every artwork, tint, and enrichment update rebuild
/// the scrolling rows and their focusable cards as well.
private struct TVSkylineBackdrop: View {
    let model: TVFocusMarqueeModel

    var body: some View {
        TVRootHeroBackdrop(
            tintColor: model.tintColor,
            artworkURL: model.backdropURL,
            artworkThumbhash: model.backdropThumbhash,
            isVisible: model.backdropURL != nil,
            crossfadeDuration: ContinuumTheme.Skyline.marqueeCrossfadeDuration
        )
    }
}

/// Foregrounds do not animate themselves. Each one follows the final rendered
/// Y position of the poster row it belongs to, producing the same continuous
/// hero → row → hero → row strip seen in the reference video. Keeping this in
/// a sibling below `scrollingRows` also guarantees posters occlude text when
/// the two pages cross instead of the text cutting through artwork.
private struct TVSkylineTrackedMarquees: View {
    let model: TVFocusMarqueeModel
    let motion: TVSkylineRowMotionModel
    let scale: TVFocusMarquee.Scale
    let sectionIds: [String]
    let focusedSectionId: String?
    let outgoing: TVSkylineOutgoingMarquee?
    let isTransitioning: Bool
    let presentationBoundary: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let bandHeight = proxy.size.height * ContinuumTheme.Skyline.rowBandHeightFraction
            let bandTop = min(
                proxy.size.height,
                max(
                    0,
                    proxy.size.height - bandHeight
                        + ContinuumTheme.Skyline.landingContentVerticalOffset
                )
            )

            ZStack {
                if isTransitioning,
                   let outgoing,
                   outgoing.sectionId != focusedSectionId,
                   let rowMinY = motion.rowMinYBySectionId[outgoing.sectionId] {
                    TVFocusMarquee(
                        content: outgoing.snapshot.content,
                        enrichment: outgoing.snapshot.enrichment,
                        scale: scale,
                        isLivePresentation: false
                    )
                    .offset(y: marqueeOffset(rowMinY: rowMinY, bandTop: bandTop))
                    .offset(
                        y: topOverflowOffset(
                            sectionId: outgoing.sectionId,
                            topOverflowTravel: bandTop
                        )
                    )
                }

                if let focusedSectionId {
                    TVFocusMarquee(
                        content: model.content,
                        enrichment: model.enrichment,
                        scale: scale,
                        // Never let an uncached logo replace its text fallback
                        // halfway through row travel. Adjacent targets are
                        // warmed ahead of time; a miss loads once motion ends.
                        allowsLogoLoading: !isTransitioning
                    )
                    .offset(
                        y: marqueeOffset(
                            // Preserve the destination row's final measured
                            // coordinate at rest. Replacing it with `bandTop`
                            // one frame after idle caused the logo/metadata to
                            // make a visible final hop of a few points.
                            rowMinY: motion.rowMinYBySectionId[focusedSectionId] ?? bandTop,
                            bandTop: bandTop
                        )
                    )
                    // Keep this as a separate transform from live row geometry.
                    // Geometry publications can stop when LazyVStack retires a
                    // departing row, while this shared animation must continue
                    // carrying its logo through the physical screen edge.
                    .offset(
                        y: topOverflowOffset(
                            sectionId: focusedSectionId,
                            topOverflowTravel: bandTop
                        )
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }

    /// `TVFocusMarquee` rests 56 points below its original 50/50 anchor. Add
    /// the row's displacement from that same anchor and its content block's
    /// bottom stays welded to the row header on every presented frame.
    private func marqueeOffset(rowMinY: CGFloat, bandTop: CGFloat) -> CGFloat {
        ContinuumTheme.Skyline.landingContentVerticalOffset + rowMinY - bandTop
    }

    private func topOverflowOffset(
        sectionId: String,
        topOverflowTravel: CGFloat
    ) -> CGFloat {
        guard let index = sectionIds.firstIndex(of: sectionId) else { return 0 }
        return TVSkylineRowPresentation.topOverflowOffset(
            topOverflowTravel: topOverflowTravel,
            rowIndex: CGFloat(index),
            presentationBoundary: presentationBoundary
        )
    }
}

/// Immutable foreground frame retained only for the outgoing half of a row
/// transition. Backdrop state deliberately stays in `TVFocusMarqueeModel` and
/// never enters this presentation stack.
private struct TVSkylineMarqueeSnapshot: Equatable {
    let content: TVMarqueeContent
    let enrichment: TVMarqueeEnrichment?
}

private struct TVSkylineOutgoingMarquee: Equatable {
    let sectionId: String
    let snapshot: TVSkylineMarqueeSnapshot
}

/// One generation drives both halves: the containing ScrollView aligns
/// `sectionId`, and that row's MediaRow claims
/// `itemId`. The destination cannot change midway through the animation.
private struct TVSkylineRowFocusRequest: Equatable {
    let generation: Int
    let sectionId: String
    let itemId: String
    let expectsScroll: Bool
}

/// Serializes vertical navigation without observing ordinary horizontal focus
/// changes in the feed's body. A move locks the current row and one adjacent
/// destination, then publishes one exact scroll/focus request. Every other row
/// stays outside the focus graph until the destination reports real focus.
@Observable
@MainActor
private final class TVSkylineRowNavigationModel {
    static let animationDuration = 0.60
    static let animation = Animation.timingCurve(
        0.16,
        1.0,
        0.30,
        1.0,
        duration: animationDuration
    )

    private(set) var request: TVSkylineRowFocusRequest?
    private(set) var isInFlight = false
    private(set) var focusableSectionIds: Set<String> = []

    @ObservationIgnored private var nextGeneration = 0
    @ObservationIgnored private var lastFocusedItemIdBySectionId: [String: String] = [:]
    @ObservationIgnored private(set) var confirmedSectionId: String?
    @ObservationIgnored private var destinationSectionId: String?
    @ObservationIgnored private var destinationItemId: String?
    @ObservationIgnored private var operationExpectsScroll = true
    @ObservationIgnored private var targetFocusObserved = false
    @ObservationIgnored private var sawScrollMovement = false
    @ObservationIgnored private var isScrollMoving = false
    @ObservationIgnored private var acceptsQueuedMoveCommands = false
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    func lastFocusedItemId(in sectionId: String) -> String? {
        lastFocusedItemIdBySectionId[sectionId]
    }

    func seedConfirmedSection(_ sectionId: String) {
        if confirmedSectionId == nil {
            confirmedSectionId = sectionId
            focusableSectionIds = [sectionId]
        }
    }

    func isFocusEnabled(sectionId: String, isInitialSection: Bool) -> Bool {
        if focusableSectionIds.isEmpty {
            return isInitialSection
        }
        return focusableSectionIds.contains(sectionId)
    }

    /// Entry and native focus-repair locks consume their originating remote
    /// event. Only a deliberate row-to-row transaction accepts subsequent
    /// presses into the adjacent-page queue.
    var acceptsQueuedVerticalMoves: Bool {
        isInFlight && acceptsQueuedMoveCommands
    }

    /// Claim entry from chrome synchronously, before its focus request is
    /// published on the next render turn. tvOS can otherwise deliver the same
    /// Down command to the first row and immediately page it a second time.
    func prepareFocus(
        sectionId: String,
        itemId: String,
        expectsScroll: Bool = true
    ) -> Int {
        startOperation(
            sectionId: sectionId,
            itemId: itemId,
            expectsScroll: expectsScroll,
            acceptsQueuedMoveCommands: false
        )
    }

    func publishPreparedFocus(generation: Int) {
        publishFallback(generation: generation)
    }

    /// Lock the current row and its one adjacent destination, then publish the
    /// exact focus/scroll target immediately. Rows beyond that pair are not in
    /// the focus graph, so the upward geometry can never skip over a row.
    func beginVerticalMove(sectionId: String, itemId: String) {
        let generation = startOperation(
            sectionId: sectionId,
            itemId: itemId,
            expectsScroll: true,
            acceptsQueuedMoveCommands: true
        )
        publishFallback(generation: generation)
    }

    /// The actual focused row is authoritative. A native cross-row report that
    /// precedes `onMoveCommand` starts the transition lock itself, ensuring the
    /// later callback is consumed rather than interpreted as another press.
    /// During an explicit recovery, reports outside its named destination are
    /// still ignored so a departing row cannot retarget the transaction.
    func acceptFocus(sectionId: String, itemId: String) -> Bool {
        let previousSectionId = confirmedSectionId
        lastFocusedItemIdBySectionId[sectionId] = itemId
        guard isInFlight, let destinationSectionId else {
            if let previousSectionId, previousSectionId != sectionId {
                let generation = startOperation(
                    sectionId: sectionId,
                    itemId: itemId,
                    expectsScroll: true,
                    acceptsQueuedMoveCommands: false
                )
                confirmedSectionId = sectionId
                targetFocusObserved = true
                if !isScrollMoving {
                    // Hold through the remainder of this remote event. If a
                    // native scroll begins, its phase callback cancels this
                    // timer and idle becomes the completion boundary instead.
                    scheduleSettledFinish(
                        generation: generation,
                        delay: .milliseconds(180)
                    )
                }
            } else {
                confirmedSectionId = sectionId
                focusableSectionIds = [sectionId]
            }
            return true
        }
        guard destinationSectionId == sectionId else {
            let lostDestination = targetFocusObserved
            targetFocusObserved = false
            settleTask?.cancel()
            settleTask = nil
            if lostDestination {
                publishFallback(generation: nextGeneration)
            }
            return false
        }

        confirmedSectionId = sectionId
        destinationItemId = itemId
        targetFocusObserved = true
        if !operationExpectsScroll {
            // Keep the entry lock alive long enough to consume the Down event
            // that handed focus from the top menu into this first row.
            scheduleSettledFinish(
                generation: nextGeneration,
                delay: .milliseconds(180)
            )
        } else if sawScrollMovement && !isScrollMoving {
            scheduleSettledFinish(
                generation: nextGeneration,
                delay: .milliseconds(1)
            )
        } else if !isScrollMoving {
            // A disabled outer ScrollView may omit a phase callback for its
            // programmatic animation. Keep the transaction alive beyond the
            // 600 ms curve so the marquee retains live row geometry throughout.
            scheduleSettledFinish(
                generation: nextGeneration,
                delay: .milliseconds(670)
            )
        }
        return true
    }

    func setScrollMoving(_ moving: Bool) {
        isScrollMoving = moving
        guard isInFlight else { return }
        if moving {
            settleTask?.cancel()
            settleTask = nil
            sawScrollMovement = true
        } else if targetFocusObserved {
            if sawScrollMovement {
                scheduleSettledFinish(
                    generation: nextGeneration,
                    delay: .milliseconds(1)
                )
            }
        } else {
            // A native scroll that did not land on the requested adjacent row
            // is allowed to settle before recovery starts, avoiding two
            // vertical animators fighting over the same ScrollView.
            publishFallback(generation: nextGeneration)
        }
    }

    func cancel() {
        settleTask?.cancel()
        watchdog?.cancel()
        settleTask = nil
        watchdog = nil
        request = nil
        destinationSectionId = nil
        destinationItemId = nil
        isInFlight = false
        targetFocusObserved = false
        sawScrollMovement = false
        isScrollMoving = false
        acceptsQueuedMoveCommands = false
        focusableSectionIds = Set([confirmedSectionId].compactMap { $0 })
    }

    private func startOperation(
        sectionId: String,
        itemId: String,
        expectsScroll: Bool,
        acceptsQueuedMoveCommands: Bool
    ) -> Int {
        settleTask?.cancel()
        watchdog?.cancel()
        settleTask = nil
        watchdog = nil

        nextGeneration &+= 1
        request = nil
        destinationSectionId = sectionId
        destinationItemId = itemId
        operationExpectsScroll = expectsScroll
        self.acceptsQueuedMoveCommands = acceptsQueuedMoveCommands
        targetFocusObserved = false
        focusableSectionIds = Set([confirmedSectionId, sectionId].compactMap { $0 })
        // Native focus may have started panning before its move command
        // reached the row handler. Preserve that phase for the idle handshake.
        sawScrollMovement = isScrollMoving
        isInFlight = true
        armWatchdog(for: nextGeneration)
        return nextGeneration
    }

    private func publishFallback(generation: Int) {
        guard isInFlight,
              nextGeneration == generation,
              request == nil,
              let destinationSectionId,
              let destinationItemId else { return }
        request = TVSkylineRowFocusRequest(
            generation: generation,
            sectionId: destinationSectionId,
            itemId: destinationItemId,
            expectsScroll: operationExpectsScroll
        )
    }

    /// Keep completion on a cancellable task. The one-millisecond idle yield
    /// lets the final geometry report land without visibly holding an outgoing
    /// logo at the top edge after the posters have stopped.
    private func scheduleSettledFinish(
        generation: Int,
        delay: Duration
    ) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self,
                  self.isInFlight,
                  self.nextGeneration == generation,
                  self.targetFocusObserved,
                  !self.isScrollMoving else { return }
            self.finish(generation: generation)
        }
    }

    private func finish(generation: Int) {
        guard isInFlight, nextGeneration == generation else { return }
        settleTask?.cancel()
        watchdog?.cancel()
        settleTask = nil
        watchdog = nil
        request = nil
        destinationSectionId = nil
        destinationItemId = nil
        isInFlight = false
        targetFocusObserved = false
        sawScrollMovement = false
        acceptsQueuedMoveCommands = false
        focusableSectionIds = Set([confirmedSectionId].compactMap { $0 })
    }

    private func armWatchdog(for generation: Int) {
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self?.finish(generation: generation)
        }
    }
}

private enum TVSkylineRowMotionCoordinateSpace {
    static let name = "TVSkylineRowMotion"
}

/// Only the lightweight foreground observer reads this state. Card rows write
/// their presented Y positions without becoming observation dependants, so a
/// 60 fps scroll does not re-evaluate artwork or focusable button hierarchies.
@Observable
@MainActor
private final class TVSkylineRowMotionModel {
    @ObservationIgnored private var cachedRowMinYBySectionId: [String: CGFloat] = [:]
    @ObservationIgnored private var trackedSectionIds: Set<String> = []
    private(set) var rowMinYBySectionId: [String: CGFloat] = [:]

    /// Publish only the two coordinates that can move visible foregrounds.
    /// Other mounted rows continue filling the non-observed cache for a later
    /// transition without invalidating the hero several times per frame.
    func track(liveSectionId: String?, outgoingSectionId: String?) {
        trackedSectionIds = Set([liveSectionId, outgoingSectionId].compactMap { $0 })
        let trackedPositions = trackedSectionIds.reduce(into: [String: CGFloat]()) { result, id in
            result[id] = cachedRowMinYBySectionId[id]
        }
        if trackedPositions != rowMinYBySectionId {
            rowMinYBySectionId = trackedPositions
        }
    }

    func stopTracking(restingSectionId: String?) {
        trackedSectionIds.removeAll(keepingCapacity: true)
        if let restingSectionId,
           let restingMinY = cachedRowMinYBySectionId[restingSectionId] {
            let restingPosition = [restingSectionId: restingMinY]
            if restingPosition != rowMinYBySectionId {
                rowMinYBySectionId = restingPosition
            }
        } else if !rowMinYBySectionId.isEmpty {
            rowMinYBySectionId = [:]
        }
    }

    func update(sectionId: String, minY: CGFloat) {
        guard minY.isFinite else { return }
        if let previous = cachedRowMinYBySectionId[sectionId],
           abs(previous - minY) < 0.25 {
            return
        }
        cachedRowMinYBySectionId[sectionId] = minY
        guard trackedSectionIds.contains(sectionId) else { return }
        rowMinYBySectionId[sectionId] = minY
    }
}

private struct TVSkylineRowPositionReporter: ViewModifier {
    let sectionId: String
    let motion: TVSkylineRowMotionModel

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(TVSkylineRowMotionCoordinateSpace.name)).minY
        } action: { minY in
            motion.update(sectionId: sectionId, minY: minY)
        }
    }
}

/// One pure transform is used by both the poster row and its separate marquee
/// layer. The native scroll supplies the adjacent-row stride; crossing the
/// integer boundary supplies the remaining hero-band travel through the top
/// of the physical screen. There is no opacity curve or clipping shortcut.
private enum TVSkylineRowPresentation {
    static func topOverflowOffset(
        topOverflowTravel: CGFloat,
        rowIndex: CGFloat,
        presentationBoundary: CGFloat
    ) -> CGFloat {
        let progress = min(max(presentationBoundary - rowIndex, 0), 1)
        return -topOverflowTravel * progress
    }
}

private struct TVSkylineRowOverflowPresentation: ViewModifier {
    let topOverflowTravel: CGFloat
    let rowIndex: CGFloat
    let presentationBoundary: CGFloat

    func body(content: Content) -> some View {
        content.offset(
            y: TVSkylineRowPresentation.topOverflowOffset(
                topOverflowTravel: topOverflowTravel,
                rowIndex: rowIndex,
                presentationBoundary: presentationBoundary
            )
        )
    }
}

#endif
