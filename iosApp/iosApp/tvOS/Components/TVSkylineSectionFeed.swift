#if os(tvOS)
import SwiftUI

/// Shared Skyline landing layout (§6.1): an ambient backdrop, a focus
/// marquee that passively previews the focused card, and native vertically
/// scrolling section rows. Used by **both** Home and the library Browse tabs
/// so the two stay pixel-identical — the only difference is the sections each
/// feeds in.
///
/// Row-to-row movement is resolved as one explicit adjacent-row transaction.
/// The visual overflow used by the Plex-style strip intentionally differs
/// from the focus engine's layout geometry, so allowing native Up/Down
/// resolution would occasionally select a row below the one on screen.
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
    /// Geometry updates are isolated from the feed so following a row at the
    /// display refresh rate does not rebuild its card and focus subgraphs.
    @State private var rowMotion = TVSkylineRowMotionModel()

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
                focusedSectionId: focusedSectionId,
                outgoing: outgoingMarquee,
                isTransitioning: rowNavigation.isInFlight
            )

            // Native scrolling and focus stay in the bottom band. Rendering
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
            marqueeModel.suspend()
            rowNavigation.cancel()
        }
        .onChange(of: rowNavigation.isInFlight) { _, isInFlight in
            if !isInFlight {
                outgoingMarquee = nil
                if !isTopMenuFocused {
                    // A watchdog completion means the destination never
                    // reported real focus. Restore ownership to the last
                    // accepted row so a failed claim cannot poison the next
                    // Up/Down command or a later detail-return repair.
                    restoreConfirmedPresentation()
                }
            }
        }
        .onChange(of: focusRequest) { _, request in requestEntryFocus(request) }
        .onChange(of: isTopMenuFocused) { _, isFocused in
            if isFocused {
                rowNavigation.cancel()
                focusRestorationOwnerSectionId = nil
            }
        }
        // Rows mount only after the async section load; a deferred entry
        // token re-fires once they exist.
        .onChange(of: sections.map(\.id)) { _, _ in
            seedMarqueeFromFirstItem()
            if let pending = pendingFocusRequest { requestEntryFocus(pending) }
        }
    }

    // MARK: - Rows

    /// Native vertical row scrolling whose layout remains in the lower band.
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
                            featuredRow(section, index: index)
                                .fixedSize(horizontal: false, vertical: true)
                                // The native stride brings the adjacent row to
                                // its anchor. A top-only render extension lets
                                // the departing complete row continue beyond
                                // the physical screen instead of fading out.
                                .modifier(
                                    TVSkylineRowScrollPresentation(
                                        topOverflowTravel: reduceMotion ? 0 : bandTop
                                    )
                                )
                                // Report the final presented position after
                                // that extension; the matching marquee follows
                                // this value instead of running its own clock.
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
                // Visual overflow is the key Plex behavior: native focus and
                // layout stay in the lower band while complete rows cross the
                // hero area and leave through the physical screen boundary.
                .scrollClipDisabled()
                // Hold the independent backdrop swap until the physical strip
                // settles, then retire the one outgoing foreground snapshot.
                .onScrollPhaseChange { _, phase in
                    marqueeModel.setBackdropDeferred(phase != .idle)
                    rowNavigation.setScrollMoving(phase != .idle)
                    if phase == .idle {
                        outgoingMarquee = nil
                    }
                }
                // Every vertical command names one exact row target. Drive
                // the scroll and the destination card's focus request from
                // the same generation so tvOS cannot settle on the row below.
                .onChange(of: rowNavigation.request?.generation) { _, _ in
                    if let request = rowNavigation.request {
                        withAnimation(reduceMotion ? nil : TVSkylineRowNavigationModel.animation) {
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
            // The visual strip deliberately travels beyond its logical focus
            // frames, so native geometric resolution is no longer a reliable
            // row selector. Resolve one adjacent row explicitly in either
            // direction; first-row Up still crosses into the top menu.
            onMoveUp: { requestVerticalMove(delta: -1) },
            onItemFocus: { item in
                acceptFocusedItem(item, in: section)
            },
            cardWidth: ContinuumTheme.Skyline.densePosterCardWidth,
            cardVerticalPadding: ContinuumTheme.Skyline.rowBandCardVerticalPadding,
            onMoveDown: { requestVerticalMove(delta: 1) },
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
        // Publish one request on the next turn. The vertical ScrollView and
        // destination MediaRow observe the same generation: one aligns the
        // row while the other's bounded focus claim lands on its first card.
        DispatchQueue.main.async {
            guard !isTopMenuFocused,
                  sections.first?.id == firstSectionId else { return }
            rowNavigation.requestFocus(
                sectionId: firstSectionId,
                itemId: firstItem.contentId,
                expectsScroll: focusedSectionId != firstSectionId
            )
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
    }

    /// Resolve one deterministic adjacent row. Returning to a row restores its
    /// last card; first entry uses the closest card index from the source row.
    /// This replaces native geometric selection only for vertical boundaries—
    /// horizontal movement remains entirely owned by each MediaRow.
    private func requestVerticalMove(delta: Int) {
        guard !rowNavigation.isInFlight,
              let sourceSectionId = rowNavigation.confirmedSectionId ?? focusedSectionId,
              let sourceIndex = sections.firstIndex(where: { $0.id == sourceSectionId }) else {
            return
        }

        let destinationIndex = sourceIndex + delta
        guard sections.indices.contains(destinationIndex) else {
            if destinationIndex < sections.startIndex {
                focusRestorationOwnerSectionId = nil
                onTopMenuFocusRequest?()
            }
            return
        }

        let source = sections[sourceIndex]
        let destination = sections[destinationIndex]
        guard !destination.items.isEmpty else { return }

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
            return
        }

        // Prime the incoming foreground before scrolling. It is immediately
        // attached to the destination row's measured geometry, so its logo
        // and metadata enter with that row even if tvOS takes another frame
        // to complete the real focus claim.
        previewFocusedItem(targetItem, in: destination)
        focusRestorationOwnerSectionId = destination.id
        rowNavigation.requestFocus(
            sectionId: destination.id,
            itemId: targetItemId
        )
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
        marqueeModel.preview(
            candidate,
            neighborBackdropURLs: neighborBackdropURLs(around: item, in: section)
        )
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
                rowTitle: section.title,
                isContinueWatching: section.isContinueWatchingSection
            )
        )
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
    let focusedSectionId: String?
    let outgoing: TVSkylineOutgoingMarquee?
    let isTransitioning: Bool

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
                }

                if let focusedSectionId {
                    TVFocusMarquee(
                        content: model.content,
                        enrichment: model.enrichment,
                        scale: scale
                    )
                    .offset(
                        y: marqueeOffset(
                            // Geometry drives the hero only while a row
                            // transaction is live. At rest, pin it to the
                            // canonical anchor so an unmounted row's last
                            // reported coordinate can never strand metadata
                            // above the navigation bar.
                            rowMinY: isTransitioning
                                ? (motion.rowMinYBySectionId[focusedSectionId] ?? bandTop)
                                : bandTop,
                            bandTop: bandTop
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

/// One generation drives both halves of a vertical handoff: the containing
/// ScrollView aligns `sectionId`, and that row's MediaRow claims `itemId`.
/// Keeping the destination immutable prevents focus repair from retargeting a
/// transition midway through its animation.
private struct TVSkylineRowFocusRequest: Equatable {
    let generation: Int
    let sectionId: String
    let itemId: String
    let expectsScroll: Bool
}

/// Serializes vertical navigation without observing ordinary horizontal
/// focus changes in the feed's body. The lock ends only after the requested
/// card has reported focus and any animated vertical scroll has become idle.
/// A watchdog releases it if tvOS omits a scroll-phase callback, avoiding a
/// permanently dead Up/Down path after an interrupted gesture.
@Observable
@MainActor
private final class TVSkylineRowNavigationModel {
    static let animation = Animation.timingCurve(
        0.16,
        1.0,
        0.30,
        1.0,
        duration: 0.38
    )

    private(set) var request: TVSkylineRowFocusRequest?
    private(set) var isInFlight = false

    @ObservationIgnored private var nextGeneration = 0
    @ObservationIgnored private var lastFocusedItemIdBySectionId: [String: String] = [:]
    @ObservationIgnored private(set) var confirmedSectionId: String?
    @ObservationIgnored private var targetFocusObserved = false
    @ObservationIgnored private var sawScrollMovement = false
    @ObservationIgnored private var isScrollMoving = false
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    func lastFocusedItemId(in sectionId: String) -> String? {
        lastFocusedItemIdBySectionId[sectionId]
    }

    func seedConfirmedSection(_ sectionId: String) {
        if confirmedSectionId == nil {
            confirmedSectionId = sectionId
        }
    }

    func requestFocus(
        sectionId: String,
        itemId: String,
        expectsScroll: Bool = true
    ) {
        watchdog?.cancel()
        nextGeneration &+= 1
        targetFocusObserved = false
        // Native focus may have already begun panning the ScrollView before
        // its move command reaches the row handler. Preserve that phase so
        // the following idle callback can finish this same transaction.
        sawScrollMovement = isScrollMoving
        isInFlight = true
        request = TVSkylineRowFocusRequest(
            generation: nextGeneration,
            sectionId: sectionId,
            itemId: itemId,
            expectsScroll: expectsScroll
        )
        armWatchdog(for: nextGeneration)
    }

    /// Returns false for transient reports from the departing row while the
    /// engine repairs focus during a scroll. Any real card in the requested
    /// destination row confirms the handoff: `itemId` is the preferred claim,
    /// not a reason to strand the hero if tvOS selects a nearby valid card.
    func acceptFocus(sectionId: String, itemId: String) -> Bool {
        lastFocusedItemIdBySectionId[sectionId] = itemId
        guard isInFlight, let request else {
            // All cross-row movement is explicit. Once a row is confirmed,
            // a late focus repair from the departing row is stale rather than
            // a new navigation event; horizontal reports in the live row are
            // still accepted normally.
            guard confirmedSectionId == nil || confirmedSectionId == sectionId else {
                return false
            }
            confirmedSectionId = sectionId
            return true
        }
        guard request.sectionId == sectionId else { return false }

        confirmedSectionId = sectionId
        targetFocusObserved = true
        if !request.expectsScroll || (sawScrollMovement && !isScrollMoving) {
            finish(generation: request.generation)
        }
        return true
    }

    func setScrollMoving(_ moving: Bool) {
        isScrollMoving = moving
        guard isInFlight else { return }
        if moving {
            sawScrollMovement = true
        } else if sawScrollMovement,
                  targetFocusObserved,
                  let generation = request?.generation {
            finish(generation: generation)
        }
    }

    func cancel() {
        watchdog?.cancel()
        watchdog = nil
        request = nil
        isInFlight = false
        targetFocusObserved = false
        sawScrollMovement = false
        isScrollMoving = false
    }

    private func finish(generation: Int) {
        guard request?.generation == generation else { return }
        watchdog?.cancel()
        watchdog = nil
        request = nil
        isInFlight = false
        targetFocusObserved = false
        sawScrollMovement = false
    }

    private func armWatchdog(for generation: Int) {
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
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
    private(set) var rowMinYBySectionId: [String: CGFloat] = [:]

    func update(sectionId: String, minY: CGFloat) {
        guard minY.isFinite else { return }
        if let previous = rowMinYBySectionId[sectionId],
           abs(previous - minY) < 0.25 {
            return
        }
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

/// The adjacent row still travels by the native layout stride into its anchor.
/// Once a row crosses the top side, extend that same interactive phase by the
/// hero-band height: its header, posters, captions, and attached foreground
/// then continue together until the entire page clears the physical screen.
/// There is deliberately no opacity curve—the screen edge alone removes it.
private struct TVSkylineRowScrollPresentation: ViewModifier {
    let topOverflowTravel: CGFloat

    func body(content: Content) -> some View {
        content.scrollTransition(.interactive, axis: .vertical) { row, phase in
            row.offset(
                y: phase.value < 0
                    ? CGFloat(phase.value) * topOverflowTravel
                    : 0
            )
        }
    }
}

#endif
