#if os(tvOS)
import SwiftUI

/// Shared Skyline landing feed used by Home and library Recommended pages.
/// Vertical navigation is a bounded page presentation, not a scroll: the
/// settled row and its two neighbours stay mounted, and one CGFloat moves a
/// page's rail and marquee together while focus remains on the source card.
struct TVSkylineSectionFeed: View {
    let sections: [ResolvedSection]
    var marqueeScale: TVFocusMarquee.Scale = .home
    var focusRequest: Int = 0
    var detailReturnFocusRequest: Int = 0
    var isTopMenuFocused: Bool = false
    let onTopMenuFocusRequest: (() -> Void)?
    let onItemTap: (_ destinationContentId: String, _ item: SectionItem) -> Void
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil
    var onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil

    @State private var marqueeModel = TVFocusMarqueeModel()
    @State private var uiCustomization = UICustomizationPreferences.shared

    /// The only animated vertical value. Integer values are settled pages;
    /// SwiftUI interpolates it against the flight's frozen anchor table.
    @State private var presentedRowIndex: CGFloat = 0
    @State private var confirmedSectionId: String?
    @State private var flight: TVSkylineFlight?
    @State private var pendingVerticalCommands: [TVSkylineVerticalCommand] = []
    @State private var preparingDestinationId: String?
    @State private var preparingCommand: TVSkylineVerticalCommand?
    @State private var animationGeneration = 0

    @State private var focusRequestSectionId: String?
    @State private var focusRequestItemId: String?
    @State private var rowFocusRequestToken = 0
    @State private var focusConfirmationTask: Task<Void, Never>?
    @State private var focusRestorationOwnerSectionId: String?
    @State private var entryLockActive = false
    @State private var pendingEntryFocusRequest: Int?
    @State private var lastAppliedEntryFocusRequest = 0

    @State private var rowContent: [String: TVMarqueeContent] = [:]
    @State private var measuredRows: [String: TVSkylineMeasuredRow] = [:]
    @State private var pendingMeasuredRows: [String: TVSkylineMeasuredRow] = [:]

    @State private var railMountIds: [String: UUID] = [:]
    @State private var railPreparations: [String: TVMediaRailPreparation] = [:]
    @State private var railPreparationKeys: [String: TVSkylineRailPreparationKey] = [:]
    @State private var preparedRails: [String: TVSkylinePreparedRail] = [:]
    @State private var railPreparationGeneration = 0
    @State private var horizontalRestTask: Task<Void, Never>?
    @State private var stickyColumn = 0

    @State private var lastSectionIds: [String] = []
    @State private var viewportSize: CGSize = .zero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bandTop = rowBandTop(for: size)
            let baseIndex = flight?.sourceIndex ?? confirmedIndex
            let extents = flight?.pageExtents ?? livePageExtents(size: size, bandTop: bandTop)

            ZStack(alignment: .topLeading) {
                TVSkylineBackdrop(model: marqueeModel, reduceMotion: reduceMotion)

                ForEach(mountedSections) { section in
                    if let index = sections.firstIndex(where: { $0.id == section.id }) {
                        TVSkylineRowPage(
                            section: section,
                            index: index,
                            bandTop: bandTop,
                            scale: marqueeScale,
                            fallbackMarqueeContent: contentForPage(section),
                            marqueeModel: marqueeModel,
                            isLivePresentation: isLivePresentation(section.id),
                            allowsLogoLoading: shouldLoadLogo(section.id),
                            isFocusEnabled: isFocusEnabled(section.id),
                            restrictsFocusToRequestedItem: restrictsFocusToRequestedItem(section.id),
                            prefersDefaultFocus: isSettled && index == 0,
                            focusRequest: focusRequestSectionId == section.id ? rowFocusRequestToken : 0,
                            focusRequestItemId: stagedFocusItemId(for: section.id),
                            detailReturnFocusRequest: detailReturnFocusRequest,
                            railPreparation: railPreparations[section.id],
                            focusRestorationOwner: restorationBinding(for: section.id),
                            onMoveUp: { handleVerticalCommand(-1) },
                            onMoveDown: { handleVerticalCommand(1) },
                            onItemTap: onItemTap,
                            onRemoveFromContinueWatching: onRemoveFromContinueWatching,
                            onSetWatched: onSetWatched,
                            onItemFocus: { item in itemDidReceiveFocus(item, in: section) },
                            onMeasured: { height in
                                rowWasMeasured(
                                    sectionId: section.id,
                                    signature: layoutSignature(for: section, width: size.width),
                                    height: height
                                )
                            },
                            onRailMounted: { mountId in railDidMount(section.id, mountId: mountId) },
                            onRailUnmounted: { mountId in railDidUnmount(section.id, mountId: mountId) },
                            onRailPreparationReady: { generation, mountId in
                                railDidPrepare(section.id, generation: generation, mountId: mountId)
                            }
                        )
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .offset(
                            y: pageOffset(
                                rowIndex: index,
                                presentation: presentedRowIndex,
                                baseIndex: baseIndex,
                                pageExtents: extents,
                                fallbackExtent: max(size.height, 1)
                            )
                        )
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // Clip only at the physical viewport. There is deliberately no
            // lower-band clip: rows and their marquees leave together.
            .clipped()
            .onAppear { viewportDidChange(size) }
            .onChange(of: size) { _, newSize in viewportDidChange(newSize) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            marqueeModel.resume()
            synchronizeSections()
            requestEntryFocus(focusRequest)
        }
        .onDisappear {
            // A detail push can remove the feed while the spring's invisible
            // physical tail is still retained. Its completion is not reliable
            // offscreen, so synchronously rebase to the row that actually owns
            // focus before discarding the generation.
            cancelActiveNavigation(restoreSource: true)
            marqueeModel.suspend()
        }
        .onChange(of: focusRequest) { _, request in requestEntryFocus(request) }
        .onChange(of: isTopMenuFocused) { _, isFocused in
            if isFocused {
                cancelActiveNavigation(restoreSource: true)
                focusRestorationOwnerSectionId = nil
                entryLockActive = false
            }
        }
        .onChange(of: sectionFingerprint) { _, _ in synchronizeSections() }
        .onChange(of: presentationFingerprint) { _, _ in layoutPreferencesDidChange() }
    }

    // MARK: - Page window and anchors

    private var confirmedIndex: Int {
        guard let confirmedSectionId,
              let index = sections.firstIndex(where: { $0.id == confirmedSectionId }) else { return 0 }
        return index
    }

    private var mountedSections: [ResolvedSection] {
        guard !sections.isEmpty else { return [] }
        let center = min(max(flight?.sourceIndex ?? confirmedIndex, 0), sections.count - 1)
        var lower = max(0, center - 1)
        var upper = min(sections.count - 1, center + 1)
        if let focusOwnerSectionId = focusRestorationOwnerSectionId,
           let focusOwnerIndex = sections.firstIndex(where: { $0.id == focusOwnerSectionId }) {
            lower = min(lower, focusOwnerIndex)
            upper = max(upper, focusOwnerIndex)
        }

        // Rapid input widens the otherwise ±1 window only as far as the
        // bounded queue can reach. Future destinations mount and prepare
        // while the current page is still flying, so chaining does not add a
        // press-time layout pause. The actual focus-owning source remains in
        // this contiguous range until its handoff completes.
        var projected = flight?.visualTargetIndex
            ?? preparingCommand.map { confirmedIndex + $0.direction }
            ?? center
        if sections.indices.contains(projected) {
            lower = min(lower, projected)
            upper = max(upper, projected)
        }
        for command in pendingVerticalCommands {
            projected += command.direction
            guard sections.indices.contains(projected) else { break }
            lower = min(lower, projected)
            upper = max(upper, projected)
        }
        return Array(sections[lower...upper])
    }

    private var isSettled: Bool {
        flight == nil && preparingDestinationId == nil
    }

    private func rowBandTop(for size: CGSize) -> CGFloat {
        let bandHeight = size.height * ContinuumTheme.Skyline.rowBandHeightFraction
        return min(
            size.height,
            max(0, size.height - bandHeight + ContinuumTheme.Skyline.landingContentVerticalOffset)
        )
    }

    /// A full page extent keeps the prior row above the physical screen after
    /// landing. The measured row still participates so larger accessibility or
    /// card settings cannot overlap the neighbouring page.
    private func livePageExtents(size: CGSize, bandTop: CGFloat) -> [String: CGFloat] {
        var values: [String: CGFloat] = [:]
        for section in mountedSections {
            let signature = layoutSignature(for: section, width: size.width)
            let measured = measuredRows[section.id]
            let height = measured?.signature == signature ? measured?.height ?? 0 : 0
            values[section.id] = max(
                max(size.height, 1),
                bandTop + height + ContinuumTheme.Skyline.rowBandPreviewSpacing
            )
        }
        return values
    }

    private func pageOffset(
        rowIndex: Int,
        presentation: CGFloat,
        baseIndex: Int,
        pageExtents: [String: CGFloat],
        fallbackExtent: CGFloat
    ) -> CGFloat {
        anchor(
            at: CGFloat(rowIndex),
            relativeTo: baseIndex,
            pageExtents: pageExtents,
            fallbackExtent: fallbackExtent
        ) - anchor(
            at: presentation,
            relativeTo: baseIndex,
            pageExtents: pageExtents,
            fallbackExtent: fallbackExtent
        )
    }

    private func anchor(
        at value: CGFloat,
        relativeTo baseIndex: Int,
        pageExtents: [String: CGFloat],
        fallbackExtent: CGFloat
    ) -> CGFloat {
        guard !sections.isEmpty else { return 0 }
        let clamped = min(max(value, 0), CGFloat(sections.count - 1))
        let lower = Int(floor(clamped))
        let fraction = clamped - CGFloat(lower)
        var result: CGFloat = 0

        if lower > baseIndex {
            for index in baseIndex..<lower {
                result += extent(below: index, pageExtents: pageExtents, fallbackExtent: fallbackExtent)
            }
        } else if lower < baseIndex {
            for index in lower..<baseIndex {
                result -= extent(below: index, pageExtents: pageExtents, fallbackExtent: fallbackExtent)
            }
        }

        if fraction > 0, lower < sections.count - 1 {
            result += fraction * extent(
                below: lower,
                pageExtents: pageExtents,
                fallbackExtent: fallbackExtent
            )
        }
        return result
    }

    private func extent(
        below index: Int,
        pageExtents: [String: CGFloat],
        fallbackExtent: CGFloat
    ) -> CGFloat {
        guard sections.indices.contains(index) else { return fallbackExtent }
        return pageExtents[sections[index].id] ?? fallbackExtent
    }

    // MARK: - Vertical state machine

    private func handleVerticalCommand(_ direction: Int) {
        let command = TVSkylineVerticalCommand(
            direction: direction,
            latencyToken: TVFrameHitchMonitor.shared.recordSkylineVerticalInput(direction: direction)
        )
        handleVerticalCommand(command)
    }

    private func handleVerticalCommand(_ command: TVSkylineVerticalCommand) {
        let direction = command.direction
        guard direction == -1 || direction == 1, !sections.isEmpty else { return }

        if entryLockActive, direction == 1 {
            entryLockActive = false
            cancelLatencyToken(command)
            return
        }

        if flight != nil {
            handleCommandDuringFlight(command)
            return
        }

        if let preparingCommand {
            if !pendingVerticalCommands.isEmpty {
                enqueueOrCancel(command, after: confirmedIndex + preparingCommand.direction)
            } else if direction == -preparingCommand.direction {
                cancelLatencyToken(preparingCommand)
                cancelLatencyToken(command)
                preparingDestinationId = nil
                self.preparingCommand = nil
            } else {
                enqueueOrCancel(command, after: confirmedIndex + preparingCommand.direction)
            }
            return
        }

        let source = confirmedIndex
        let destination = source + direction
        if destination < 0 {
            cancelLatencyToken(command)
            onTopMenuFocusRequest?()
            return
        }
        guard sections.indices.contains(destination) else {
            cancelLatencyToken(command)
            return
        }
        beginPreparingFlight(to: destination, command: command)
    }

    private func beginPreparingFlight(to destinationIndex: Int, command: TVSkylineVerticalCommand) {
        let section = sections[destinationIndex]
        preparingDestinationId = section.id
        preparingCommand = command
        prepareRail(for: section)
        tryStartPreparedFlight()
    }

    private func tryStartPreparedFlight() {
        guard flight == nil,
              let destinationId = preparingDestinationId,
              let command = preparingCommand,
              let destinationIndex = sections.firstIndex(where: { $0.id == destinationId }),
              abs(destinationIndex - confirmedIndex) == 1,
              destinationIsReady(destinationIndex),
              sourceHasCurrentMeasurement else { return }

        preparingDestinationId = nil
        preparingCommand = nil
        startFlight(to: destinationIndex, command: command)
    }

    private var sourceHasCurrentMeasurement: Bool {
        guard sections.indices.contains(confirmedIndex) else { return false }
        return measurementIsCurrent(for: sections[confirmedIndex])
    }

    private func destinationIsReady(_ index: Int) -> Bool {
        guard sections.indices.contains(index) else { return false }
        let section = sections[index]
        return measurementIsCurrent(for: section) && railIsPrepared(for: section)
    }

    private func startFlight(to destinationIndex: Int, command: TVSkylineVerticalCommand) {
        let direction = command.direction
        let sourceIndex = confirmedIndex
        guard sections.indices.contains(sourceIndex), sections.indices.contains(destinationIndex) else { return }
        let source = sections[sourceIndex]
        let destination = sections[destinationIndex]
        let bandTop = rowBandTop(for: viewportSize)
        let extents = livePageExtents(size: viewportSize, bandTop: bandTop)
        animationGeneration += 1
        let generation = animationGeneration

        rowContent[destination.id] = targetContent(for: destination)
        flight = TVSkylineFlight(
            sourceId: source.id,
            sourceIndex: sourceIndex,
            destinationId: destination.id,
            destinationIndex: destinationIndex,
            visualTargetIndex: destinationIndex,
            direction: direction,
            generation: generation,
            pageExtents: extents,
            isAwaitingFocus: false,
            hasAcceptedFocus: false,
            hasBeenRemoved: reduceMotion,
            focusClaimFailed: false,
            reduceMotion: reduceMotion,
            inputLatencyToken: command.latencyToken,
            focusOwnerId: focusRestorationOwnerSectionId ?? source.id
        )

        if reduceMotion {
            cancelLatencyToken(command)
            beginDestinationFocusHandoff(generation: generation)
        } else {
            animatePresentation(
                to: destinationIndex,
                generation: generation,
                inputLatencyToken: command.latencyToken
            )
        }
    }

    private func handleCommandDuringFlight(_ command: TVSkylineVerticalCommand) {
        guard var currentFlight = flight else { return }
        let direction = command.direction

        if !pendingVerticalCommands.isEmpty {
            enqueueOrCancel(command, after: currentFlight.visualTargetIndex)
            return
        }

        let candidate = currentFlight.visualTargetIndex + direction
        let otherEndpoint = currentFlight.visualTargetIndex == currentFlight.destinationIndex
            ? currentFlight.sourceIndex
            : currentFlight.destinationIndex

        if candidate == otherEndpoint,
           currentFlight.focusOwnerId == currentFlight.sourceId {
            focusConfirmationTask?.cancel()
            focusConfirmationTask = nil
            focusRequestSectionId = nil
            focusRequestItemId = nil
            focusRestorationOwnerSectionId = currentFlight.sourceId
            TVFrameHitchMonitor.shared.finishSkylineVerticalInput(
                currentFlight.inputLatencyToken,
                outcome: "retargeted"
            )
            animationGeneration += 1
            currentFlight.generation = animationGeneration
            currentFlight.visualTargetIndex = otherEndpoint
            currentFlight.isAwaitingFocus = false
            currentFlight.inputLatencyToken = command.latencyToken
            flight = currentFlight
            animatePresentation(
                to: otherEndpoint,
                generation: currentFlight.generation,
                inputLatencyToken: command.latencyToken
            )
            return
        }

        enqueueOrCancel(command, after: currentFlight.visualTargetIndex)
    }

    private func enqueueOrCancel(
        _ command: TVSkylineVerticalCommand,
        after activeTargetIndex: Int
    ) {
        if let last = pendingVerticalCommands.last,
           last.direction == -command.direction {
            pendingVerticalCommands.removeLast()
            cancelLatencyToken(last)
            cancelLatencyToken(command)
            return
        }

        let queuedDelta = pendingVerticalCommands.reduce(0) { $0 + $1.direction }
        let projectedDestination = activeTargetIndex + queuedDelta + command.direction
        guard sections.indices.contains(projectedDestination),
              pendingVerticalCommands.count < TVSkylineVerticalCommand.queueLimit else {
            cancelLatencyToken(command)
            return
        }
        pendingVerticalCommands.append(command)
    }

    private func takeNextQueuedCommand() -> TVSkylineVerticalCommand? {
        guard !pendingVerticalCommands.isEmpty else { return nil }
        return pendingVerticalCommands.removeFirst()
    }

    private func cancelQueuedVerticalCommands() {
        pendingVerticalCommands.forEach(cancelLatencyToken)
        pendingVerticalCommands.removeAll(keepingCapacity: true)
    }

    private func cancelLatencyToken(_ command: TVSkylineVerticalCommand) {
        TVFrameHitchMonitor.shared.cancelSkylineVerticalInput(command.latencyToken)
    }

    private func animatePresentation(
        to index: Int,
        generation: Int,
        inputLatencyToken: Int
    ) {
        TVFrameHitchMonitor.shared.markSkylineAnimationScheduled(
            inputToken: inputLatencyToken,
            targetIndex: index
        )
        var transaction = Transaction(
            animation: .spring(duration: ContinuumTheme.Skyline.rowBandScrollDuration, bounce: 0)
        )
        transaction.addAnimationCompletion(criteria: .logicallyComplete) {
            animationBecameLogicallyComplete(generation: generation, targetIndex: index)
        }
        transaction.addAnimationCompletion(criteria: .removed) {
            animationWasRemoved(generation: generation, targetIndex: index)
        }
        withTransaction(transaction) {
            presentedRowIndex = CGFloat(index)
        }
    }

    /// The named 0.40-second spring is visually at rest here, even though
    /// SwiftUI retains its sub-pixel physical tail for considerably longer.
    /// Focus and a prepared queued retarget may proceed, but geometry must not
    /// rebase until `.removed` confirms that tail is truly gone.
    private func animationBecameLogicallyComplete(generation: Int, targetIndex: Int) {
        guard let currentFlight = flight,
              currentFlight.generation == generation,
              currentFlight.visualTargetIndex == targetIndex else { return }

        TVFrameHitchMonitor.shared.markSkylineAnimationLogicallyComplete(
            inputToken: currentFlight.inputLatencyToken,
            targetIndex: targetIndex
        )

        if advanceToNextPreparedQueuedDestination(
            from: targetIndex,
            generation: generation
        ) {
            return
        }

        guard targetIndex != currentFlight.sourceIndex else { return }
        beginDestinationFocusHandoff(generation: generation)
    }

    /// Retarget the same animated value without rebasing. SwiftUI blends from
    /// the active presentation value, so rapid deliberate clicks chain at the
    /// visible landing rather than waiting for the spring's retained tail.
    private func advanceToNextPreparedQueuedDestination(
        from targetIndex: Int,
        generation: Int
    ) -> Bool {
        guard var currentFlight = flight,
              currentFlight.generation == generation,
              let pending = pendingVerticalCommands.first else { return false }
        let nextIndex = targetIndex + pending.direction
        guard sections.indices.contains(nextIndex),
              destinationIsReady(nextIndex),
              let target = targetItem(for: sections[nextIndex]) else { return false }

        _ = takeNextQueuedCommand()
        TVFrameHitchMonitor.shared.finishSkylineVerticalInput(
            currentFlight.inputLatencyToken,
            outcome: "queued landing"
        )
        animationGeneration += 1
        let nextGeneration = animationGeneration
        let destination = sections[nextIndex]
        currentFlight.destinationId = destination.id
        currentFlight.destinationIndex = nextIndex
        currentFlight.visualTargetIndex = nextIndex
        currentFlight.direction = pending.direction
        currentFlight.generation = nextGeneration
        currentFlight.isAwaitingFocus = false
        currentFlight.hasAcceptedFocus = false
        currentFlight.hasBeenRemoved = false
        currentFlight.focusClaimFailed = false
        currentFlight.inputLatencyToken = pending.latencyToken

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flight = currentFlight
            focusRequestSectionId = nil
            focusRequestItemId = nil
            focusRestorationOwnerSectionId = currentFlight.focusOwnerId
            rowContent[destination.id] = marqueeContent(for: target, in: destination)
        }
        animatePresentation(
            to: nextIndex,
            generation: nextGeneration,
            inputLatencyToken: pending.latencyToken
        )
        return true
    }

    private func animationWasRemoved(generation: Int, targetIndex: Int) {
        guard var currentFlight = flight,
              currentFlight.generation == generation,
              currentFlight.visualTargetIndex == targetIndex else { return }
        currentFlight.hasBeenRemoved = true
        flight = currentFlight
        TVFrameHitchMonitor.shared.markSkylineAnimationRemoved(
            inputToken: currentFlight.inputLatencyToken,
            targetIndex: targetIndex
        )
        if currentFlight.focusClaimFailed {
            rollbackFocusHandoff(generation: generation)
        } else if targetIndex == currentFlight.sourceIndex {
            finishReversalAtSource(generation: generation)
        } else if currentFlight.hasAcceptedFocus {
            finishAcceptedFlightAtDestination(generation: generation)
        } else if !currentFlight.isAwaitingFocus {
            beginDestinationFocusHandoff(generation: generation)
        }
    }

    private func finishReversalAtSource(generation: Int) {
        guard let currentFlight = flight, currentFlight.generation == generation else { return }
        TVFrameHitchMonitor.shared.finishSkylineVerticalInput(
            currentFlight.inputLatencyToken,
            outcome: "source restored"
        )
        let pending = takeNextQueuedCommand()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            applyPendingMeasurements()
            presentedRowIndex = CGFloat(currentFlight.sourceIndex)
            flight = nil
            focusRequestSectionId = nil
            focusRequestItemId = nil
            focusRestorationOwnerSectionId = currentFlight.sourceId
        }
        if let pending {
            handleVerticalCommand(pending)
        } else {
            scheduleAdjacentRailPreparation()
        }
    }

    private func beginDestinationFocusHandoff(generation: Int) {
        guard var currentFlight = flight,
              currentFlight.generation == generation,
              currentFlight.visualTargetIndex == currentFlight.destinationIndex,
              sections.indices.contains(currentFlight.destinationIndex) else { return }

        let destination = sections[currentFlight.destinationIndex]
        guard railIsPrepared(for: destination), let target = targetItem(for: destination) else {
            rollbackFocusHandoff(generation: generation)
            return
        }

        currentFlight.isAwaitingFocus = true
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flight = currentFlight
            focusRestorationOwnerSectionId = destination.id
            focusRequestSectionId = destination.id
            focusRequestItemId = target.contentId
            rowFocusRequestToken += 1
        }
        TVFrameHitchMonitor.shared.markSkylineFocusRequested(
            inputToken: currentFlight.inputLatencyToken,
            rowIndex: currentFlight.destinationIndex,
            itemIndex: destination.items.firstIndex(where: { $0.contentId == target.contentId }) ?? 0,
            itemCount: destination.items.count
        )
        startFocusConfirmationWindow(generation: generation)
    }

    private func finishAcceptedFlightAtDestination(generation: Int) {
        guard let currentFlight = flight,
              currentFlight.generation == generation,
              currentFlight.hasAcceptedFocus,
              currentFlight.hasBeenRemoved,
              sections.indices.contains(currentFlight.destinationIndex) else { return }

        let destination = sections[currentFlight.destinationIndex]
        let focusedItem = rowContent[destination.id].flatMap { content in
            destination.items.first(where: { $0.contentId == content.contentId })
        } ?? targetItem(for: destination)
        TVFrameHitchMonitor.shared.finishSkylineVerticalInput(
            currentFlight.inputLatencyToken,
            outcome: "destination settled"
        )
        let pending = takeNextQueuedCommand()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            applyPendingMeasurements()
            confirmedSectionId = destination.id
            presentedRowIndex = CGFloat(currentFlight.destinationIndex)
            flight = nil
            focusRequestSectionId = nil
            focusRequestItemId = nil
            focusRestorationOwnerSectionId = destination.id
        }
        if pending == nil, let focusedItem {
            let candidate = marqueeContent(for: focusedItem, in: destination)
            rowContent[destination.id] = candidate
            preview(
                candidate,
                item: focusedItem,
                section: destination,
                settlesImmediately: currentFlight.reduceMotion
            )
        }
        if let pending {
            handleVerticalCommand(pending)
        } else {
            scheduleAdjacentRailPreparation()
        }
    }

    private func startFocusConfirmationWindow(generation: Int) {
        focusConfirmationTask?.cancel()
        focusConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled,
                  let currentFlight = flight,
                  currentFlight.generation == generation,
                  currentFlight.isAwaitingFocus else { return }
            rowFocusRequestToken += 1
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled,
                  var retryFlight = flight,
                  retryFlight.generation == generation,
                  retryFlight.isAwaitingFocus else { return }
            if retryFlight.hasBeenRemoved {
                rollbackFocusHandoff(generation: generation)
            } else {
                // Never snap a failed handoff back while the physical spring
                // tail still owns the presentation. The `.removed` callback
                // performs the same rollback once rebasing is pixel-safe.
                retryFlight.focusClaimFailed = true
                flight = retryFlight
            }
        }
    }

    private func rollbackFocusHandoff(generation: Int) {
        guard let currentFlight = flight, currentFlight.generation == generation else { return }
        focusConfirmationTask?.cancel()
        focusConfirmationTask = nil
        animationGeneration += 1
        TVFrameHitchMonitor.shared.cancelSkylineVerticalInput(currentFlight.inputLatencyToken)
        cancelQueuedVerticalCommands()
        let focusOwnerIndex = sections.firstIndex(where: { $0.id == currentFlight.focusOwnerId })
            ?? currentFlight.sourceIndex
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            applyPendingMeasurements()
            confirmedSectionId = currentFlight.focusOwnerId
            presentedRowIndex = CGFloat(focusOwnerIndex)
            flight = nil
            focusRequestSectionId = nil
            focusRequestItemId = nil
            focusRestorationOwnerSectionId = currentFlight.focusOwnerId
        }
        scheduleAdjacentRailPreparation()
    }

    // MARK: - Focus and marquee ownership

    private func itemDidReceiveFocus(_ item: SectionItem, in section: ResolvedSection) {
        let candidate = marqueeContent(for: item, in: section)
        rowContent[section.id] = candidate

        if let currentFlight = flight,
           currentFlight.isAwaitingFocus,
           section.id == currentFlight.destinationId,
           item.contentId == focusRequestItemId {
            confirmDestinationFocus(item, in: section, flight: currentFlight)
            return
        }

        if let currentFlight = flight,
           currentFlight.hasAcceptedFocus,
           section.id == currentFlight.destinationId {
            // The card can move horizontally while the invisible spring tail
            // is retained. This is genuine Left/Right input, so unlike the
            // initial clamped vertical claim it may update the sticky column.
            if let index = section.items.firstIndex(where: { $0.contentId == item.contentId }) {
                stickyColumn = index
            }
            return
        }

        guard flight == nil,
              section.id == confirmedSectionId,
              preparingDestinationId == nil else { return }
        focusRestorationOwnerSectionId = section.id
        if let index = section.items.firstIndex(where: { $0.contentId == item.contentId }) {
            stickyColumn = index
        }
        preview(candidate, item: item, section: section, settlesImmediately: false)
        scheduleAdjacentRailPreparation()
    }

    private func confirmDestinationFocus(
        _ item: SectionItem,
        in section: ResolvedSection,
        flight currentFlight: TVSkylineFlight
    ) {
        focusConfirmationTask?.cancel()
        focusConfirmationTask = nil
        var acceptedFlight = currentFlight
        acceptedFlight.isAwaitingFocus = false
        acceptedFlight.hasAcceptedFocus = true
        acceptedFlight.focusClaimFailed = false
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            confirmedSectionId = section.id
            flight = acceptedFlight
            focusRequestSectionId = nil
            focusRequestItemId = nil
            focusRestorationOwnerSectionId = section.id
        }
        let candidate = marqueeContent(for: item, in: section)
        rowContent[section.id] = candidate
        TVFrameHitchMonitor.shared.markSkylineFocusAccepted(
            inputToken: currentFlight.inputLatencyToken,
            rowIndex: currentFlight.destinationIndex,
            requestedItemIndex: min(stickyColumn, max(section.items.count - 1, 0)),
            acceptedItemIndex: section.items.firstIndex(where: { $0.contentId == item.contentId }) ?? -1
        )
        if acceptedFlight.hasBeenRemoved {
            finishAcceptedFlightAtDestination(generation: acceptedFlight.generation)
        }
    }

    private func preview(
        _ candidate: TVMarqueeContent,
        item: SectionItem,
        section: ResolvedSection,
        settlesImmediately: Bool
    ) {
        marqueeModel.preview(
            candidate,
            neighborBackdropURLs: neighborBackdropURLs(around: item, in: section),
            settlesImmediately: settlesImmediately
        )
    }

    private func isFocusEnabled(_ sectionId: String) -> Bool {
        if let flight {
            if sectionId == flight.focusOwnerId { return true }
            return (flight.isAwaitingFocus || flight.hasAcceptedFocus)
                && sectionId == flight.destinationId
        }
        return sectionId == focusRestorationOwnerSectionId
    }

    private func restrictsFocusToRequestedItem(_ sectionId: String) -> Bool {
        guard let flight else { return false }
        // Keep the exact prepared target structurally staged before the row
        // becomes eligible. That prevents a one-frame window in which tvOS
        // can choose the first visible card. Full eligibility returns in the
        // same state change that accepts the requested focus claim.
        return flight.destinationId == sectionId && !flight.hasAcceptedFocus
    }

    private func stagedFocusItemId(for sectionId: String) -> String? {
        if focusRequestSectionId == sectionId { return focusRequestItemId }
        return railPreparations[sectionId]?.itemId
    }

    private func isLivePresentation(_ sectionId: String) -> Bool {
        isSettled && sectionId == confirmedSectionId
    }

    private func shouldLoadLogo(_ sectionId: String) -> Bool {
        if isLivePresentation(sectionId) { return true }
        if let flight {
            return sectionId == flight.sourceId || sectionId == flight.destinationId
        }
        return preparedRails[sectionId] != nil
    }

    private func restorationBinding(for sectionId: String) -> Binding<Bool> {
        Binding(
            get: { focusRestorationOwnerSectionId == sectionId },
            set: { owns in
                if owns { focusRestorationOwnerSectionId = sectionId }
            }
        )
    }

    // MARK: - Horizontal preparation

    private func scheduleAdjacentRailPreparation() {
        horizontalRestTask?.cancel()
        guard flight == nil, preparingDestinationId == nil else { return }
        let sourceId = confirmedSectionId
        let column = stickyColumn
        horizontalRestTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled,
                  flight == nil,
                  preparingDestinationId == nil,
                  confirmedSectionId == sourceId,
                  stickyColumn == column else { return }
            prepareAdjacentRails()
        }
    }

    private func prepareAdjacentRails() {
        guard !sections.isEmpty else { return }
        for index in [confirmedIndex - 1, confirmedIndex + 1] where sections.indices.contains(index) {
            prepareRail(for: sections[index])
        }
    }

    private func prepareRail(for section: ResolvedSection) {
        guard let mountId = railMountIds[section.id],
              let target = targetItem(for: section) else { return }
        let key = TVSkylineRailPreparationKey(
            sectionId: section.id,
            stickyColumn: stickyColumn,
            itemsVersion: itemsVersion(for: section),
            mountId: mountId,
            itemId: target.contentId
        )
        if preparedRails[section.id]?.key == key || railPreparationKeys[section.id] == key { return }

        railPreparationGeneration += 1
        railPreparationKeys[section.id] = key
        railPreparations[section.id] = TVMediaRailPreparation(
            generation: railPreparationGeneration,
            itemId: target.contentId
        )
        rowContent[section.id] = marqueeContent(for: target, in: section)
    }

    private func railDidMount(_ sectionId: String, mountId: UUID) {
        guard railMountIds[sectionId] != mountId else { return }
        railMountIds[sectionId] = mountId
        preparedRails[sectionId] = nil
        railPreparationKeys[sectionId] = nil
        if let index = sections.firstIndex(where: { $0.id == sectionId }),
           sectionId != confirmedSectionId,
           mountedSections.contains(where: { $0.id == sectionId }) {
            prepareRail(for: sections[index])
        }
        tryStartPreparedFlight()
    }

    private func railDidUnmount(_ sectionId: String, mountId: UUID) {
        guard railMountIds[sectionId] == mountId else { return }
        railMountIds[sectionId] = nil
        preparedRails[sectionId] = nil
        railPreparationKeys[sectionId] = nil
        railPreparations[sectionId] = nil
    }

    private func railDidPrepare(_ sectionId: String, generation: Int, mountId: UUID) {
        guard railMountIds[sectionId] == mountId,
              railPreparations[sectionId]?.generation == generation,
              let key = railPreparationKeys[sectionId],
              key.mountId == mountId else { return }
        preparedRails[sectionId] = TVSkylinePreparedRail(key: key, generation: generation)
        tryStartPreparedFlight()
    }

    private func railIsPrepared(for section: ResolvedSection) -> Bool {
        guard let mountId = railMountIds[section.id],
              let target = targetItem(for: section) else { return false }
        let expected = TVSkylineRailPreparationKey(
            sectionId: section.id,
            stickyColumn: stickyColumn,
            itemsVersion: itemsVersion(for: section),
            mountId: mountId,
            itemId: target.contentId
        )
        return preparedRails[section.id]?.key == expected
    }

    private func targetItem(for section: ResolvedSection) -> SectionItem? {
        guard !section.items.isEmpty else { return nil }
        return section.items[min(stickyColumn, section.items.count - 1)]
    }

    private func targetContent(for section: ResolvedSection) -> TVMarqueeContent? {
        targetItem(for: section).map { marqueeContent(for: $0, in: section) }
    }

    // MARK: - Measurements and data changes

    private func rowWasMeasured(
        sectionId: String,
        signature: TVSkylineLayoutSignature,
        height: CGFloat
    ) {
        guard height > 0, height.isFinite else { return }
        let value = TVSkylineMeasuredRow(signature: signature, height: height)
        if flight != nil {
            if pendingMeasuredRows[sectionId] != value { pendingMeasuredRows[sectionId] = value }
        } else if measuredRows[sectionId] != value {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { measuredRows[sectionId] = value }
            tryStartPreparedFlight()
        }
    }

    private func applyPendingMeasurements() {
        guard !pendingMeasuredRows.isEmpty else { return }
        for (sectionId, measurement) in pendingMeasuredRows {
            measuredRows[sectionId] = measurement
        }
        pendingMeasuredRows.removeAll(keepingCapacity: true)
    }

    private func measurementIsCurrent(for section: ResolvedSection) -> Bool {
        guard let measurement = measuredRows[section.id] else { return false }
        return measurement.signature == layoutSignature(for: section, width: viewportSize.width)
    }

    private func viewportDidChange(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewportSize else { return }
        viewportSize = size
        if flight == nil {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { presentedRowIndex = CGFloat(confirmedIndex) }
        }
    }

    private func layoutPreferencesDidChange() {
        guard flight == nil else { return }
        preparedRails.removeAll(keepingCapacity: true)
        railPreparationKeys.removeAll(keepingCapacity: true)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { presentedRowIndex = CGFloat(confirmedIndex) }
        scheduleAdjacentRailPreparation()
    }

    private func synchronizeSections() {
        guard !sections.isEmpty else {
            confirmedSectionId = nil
            lastSectionIds = []
            return
        }

        let oldIndex = lastSectionIds.firstIndex(of: confirmedSectionId ?? "") ?? confirmedIndex
        let oldConfirmedId = confirmedSectionId
        let newIndex: Int
        if let oldConfirmedId,
           let surviving = sections.firstIndex(where: { $0.id == oldConfirmedId }) {
            newIndex = surviving
        } else {
            newIndex = min(max(oldIndex, 0), sections.count - 1)
        }
        let newSection = sections[newIndex]
        let sourceWasRemoved = oldConfirmedId != nil && oldConfirmedId != newSection.id

        animationGeneration += 1
        if let flight {
            TVFrameHitchMonitor.shared.cancelSkylineVerticalInput(flight.inputLatencyToken)
        }
        focusConfirmationTask?.cancel()
        focusConfirmationTask = nil
        horizontalRestTask?.cancel()
        horizontalRestTask = nil
        if let preparingCommand { cancelLatencyToken(preparingCommand) }
        cancelQueuedVerticalCommands()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            applyPendingMeasurements()
            confirmedSectionId = newSection.id
            presentedRowIndex = CGFloat(newIndex)
            flight = nil
            preparingDestinationId = nil
            preparingCommand = nil
            focusRequestSectionId = nil
            focusRequestItemId = nil
            focusRestorationOwnerSectionId = newSection.id
        }

        let liveIds = Set(sections.map(\.id))
        measuredRows = measuredRows.filter { liveIds.contains($0.key) }
        pendingMeasuredRows = pendingMeasuredRows.filter { liveIds.contains($0.key) }
        rowContent = rowContent.filter { liveIds.contains($0.key) }
        preparedRails = preparedRails.filter { liveIds.contains($0.key) }
        railPreparationKeys = railPreparationKeys.filter { liveIds.contains($0.key) }
        railPreparations = railPreparations.filter { liveIds.contains($0.key) }
        lastSectionIds = sections.map(\.id)

        if let target = targetItem(for: newSection) {
            let content = marqueeContent(for: target, in: newSection)
            rowContent[newSection.id] = content
            if marqueeModel.content == nil {
                marqueeModel.seed(content)
            } else if sourceWasRemoved {
                preview(content, item: target, section: newSection, settlesImmediately: reduceMotion)
                focusRequestSectionId = newSection.id
                focusRequestItemId = target.contentId
                DispatchQueue.main.async { rowFocusRequestToken += 1 }
            }
        }
        scheduleAdjacentRailPreparation()
        if let pendingEntryFocusRequest { requestEntryFocus(pendingEntryFocusRequest) }
    }

    private func cancelActiveNavigation(restoreSource: Bool) {
        focusConfirmationTask?.cancel()
        focusConfirmationTask = nil
        horizontalRestTask?.cancel()
        horizontalRestTask = nil
        animationGeneration += 1
        if let flight {
            TVFrameHitchMonitor.shared.cancelSkylineVerticalInput(flight.inputLatencyToken)
        }
        let sourceIndex: Int
        let sourceId: String?
        if let flight, flight.hasAcceptedFocus {
            sourceIndex = flight.destinationIndex
            sourceId = flight.destinationId
        } else {
            sourceIndex = flight?.sourceIndex ?? confirmedIndex
            sourceId = flight?.sourceId ?? confirmedSectionId
        }
        if let preparingCommand { cancelLatencyToken(preparingCommand) }
        cancelQueuedVerticalCommands()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            applyPendingMeasurements()
            if restoreSource {
                confirmedSectionId = sourceId
                presentedRowIndex = CGFloat(sourceIndex)
            }
            flight = nil
            preparingDestinationId = nil
            preparingCommand = nil
            focusRequestSectionId = nil
            focusRequestItemId = nil
            focusRestorationOwnerSectionId = sourceId
        }
    }

    // MARK: - Entry and content helpers

    private func requestEntryFocus(_ request: Int) {
        guard request > 0 else { return }
        guard !sections.isEmpty else {
            pendingEntryFocusRequest = request
            return
        }
        pendingEntryFocusRequest = nil
        guard !isTopMenuFocused, request != lastAppliedEntryFocusRequest else { return }
        lastAppliedEntryFocusRequest = request
        cancelActiveNavigation(restoreSource: false)

        let section = sections[0]
        let item = section.items.first
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            confirmedSectionId = section.id
            presentedRowIndex = 0
            stickyColumn = 0
            focusRestorationOwnerSectionId = section.id
            focusRequestSectionId = section.id
            focusRequestItemId = item?.contentId
            entryLockActive = true
        }
        if let item {
            let content = marqueeContent(for: item, in: section)
            rowContent[section.id] = content
            if marqueeModel.content == nil { marqueeModel.seed(content) }
        }
        DispatchQueue.main.async {
            rowFocusRequestToken += 1
            DispatchQueue.main.async { entryLockActive = false }
        }
        scheduleAdjacentRailPreparation()
    }

    private func contentForPage(_ section: ResolvedSection) -> TVMarqueeContent? {
        if let content = rowContent[section.id],
           section.items.contains(where: { $0.contentId == content.contentId }) {
            return content
        }
        return targetContent(for: section)
    }

    private func marqueeContent(for item: SectionItem, in section: ResolvedSection) -> TVMarqueeContent {
        TVMarqueeContent(
            item: item,
            rowId: section.id,
            rowTitle: section.title,
            isContinueWatching: section.isContinueWatchingSection
        )
    }

    private func neighborBackdropURLs(around item: SectionItem, in section: ResolvedSection) -> [String] {
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

    private var sectionFingerprint: String {
        sections.map { "\($0.id):\(itemsVersion(for: $0))" }.joined(separator: "|")
    }

    private var presentationFingerprint: String {
        let presentation = uiCustomization.cardPresentation
        return "\(presentation.posterSize.rawValue)|\(presentation.caption.rawValue)|\(locale.identifier)|\(dynamicTypeSize)"
    }

    private func itemsVersion(for section: ResolvedSection) -> String {
        section.items.map { item in
            "\(item.contentId)#\(item.type)#\(item.title)#\(item.year ?? 0)#\(item.seriesTitle ?? "")"
        }.joined(separator: "\u{1f}")
    }

    private func layoutSignature(for section: ResolvedSection, width: CGFloat) -> TVSkylineLayoutSignature {
        TVSkylineLayoutSignature(
            sectionId: section.id,
            rowKind: rowKind(for: section),
            posterSize: uiCustomization.cardPresentation.posterSize.rawValue,
            caption: uiCustomization.cardPresentation.caption.rawValue,
            availableWidthPixels: Int(width.rounded()),
            locale: locale.identifier,
            dynamicType: String(describing: dynamicTypeSize),
            itemsVersion: itemsVersion(for: section)
        )
    }

    private func rowKind(for section: ResolvedSection) -> String {
        let type = section.sectionType.lowercased()
        if type.contains("next") || section.isContinueWatchingSection
            || section.items.contains(where: { $0.type.lowercased() == "episode" }) {
            return "thumbnail"
        }
        if !section.items.isEmpty && section.items.allSatisfy(\.isAudiobook) { return "square" }
        return "poster"
    }
}

// MARK: - Page leaves

private struct TVSkylineRowPage: View {
    let section: ResolvedSection
    let index: Int
    let bandTop: CGFloat
    let scale: TVFocusMarquee.Scale
    let fallbackMarqueeContent: TVMarqueeContent?
    let marqueeModel: TVFocusMarqueeModel
    let isLivePresentation: Bool
    let allowsLogoLoading: Bool
    let isFocusEnabled: Bool
    let restrictsFocusToRequestedItem: Bool
    let prefersDefaultFocus: Bool
    let focusRequest: Int
    let focusRequestItemId: String?
    let detailReturnFocusRequest: Int
    let railPreparation: TVMediaRailPreparation?
    let focusRestorationOwner: Binding<Bool>
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onItemTap: (_ destinationContentId: String, _ item: SectionItem) -> Void
    let onRemoveFromContinueWatching: ((SectionItem) -> Void)?
    let onSetWatched: ((SectionItem, Bool) async -> Bool)?
    let onItemFocus: (SectionItem) -> Void
    let onMeasured: (CGFloat) -> Void
    let onRailMounted: (UUID) -> Void
    let onRailUnmounted: (UUID) -> Void
    let onRailPreparationReady: (Int, UUID) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVSkylinePageMarquee(
                model: marqueeModel,
                fallbackContent: fallbackMarqueeContent,
                scale: scale,
                isLivePresentation: isLivePresentation,
                allowsLogoLoading: allowsLogoLoading
            )
            .offset(y: ContinuumTheme.Skyline.landingContentVerticalOffset)

            SectionRow(
                section: section,
                onItemTap: onItemTap,
                onRemoveFromContinueWatching: onRemoveFromContinueWatching,
                onSetWatched: onSetWatched,
                prefersDefaultFocusOnFirstItem: prefersDefaultFocus,
                defaultFocusPriority: .automatic,
                focusRequest: focusRequest,
                focusRequestItemId: focusRequestItemId,
                detailReturnFocusRequest: detailReturnFocusRequest,
                isFocusEnabled: isFocusEnabled,
                usesPreparedOneShotFocusRequest: true,
                restrictsFocusToRequestedItem: restrictsFocusToRequestedItem,
                railPreparation: railPreparation,
                onRailMounted: onRailMounted,
                onRailUnmounted: onRailUnmounted,
                onRailPreparationReady: onRailPreparationReady,
                onMoveUp: onMoveUp,
                onItemFocus: onItemFocus,
                cardWidth: ContinuumTheme.Skyline.densePosterCardWidth,
                cardVerticalPadding: ContinuumTheme.Skyline.rowBandCardVerticalPadding,
                onMoveDown: onMoveDown,
                focusRestorationOwner: focusRestorationOwner
            )
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in
                onMeasured(height)
            }
            .offset(y: bandTop)
            .environment(\.tvArtworkLoadingEnabled, true)
        }
    }
}

/// Isolates observation of the live marquee model from the card subtree.
private struct TVSkylinePageMarquee: View {
    let model: TVFocusMarqueeModel
    let fallbackContent: TVMarqueeContent?
    let scale: TVFocusMarquee.Scale
    let isLivePresentation: Bool
    let allowsLogoLoading: Bool

    var body: some View {
        TVFocusMarquee(
            content: isLivePresentation ? (model.content ?? fallbackContent) : fallbackContent,
            enrichment: isLivePresentation ? model.enrichment : nil,
            scale: scale,
            isLivePresentation: isLivePresentation,
            allowsLogoLoading: allowsLogoLoading
        )
    }
}

private struct TVSkylineBackdrop: View {
    let model: TVFocusMarqueeModel
    let reduceMotion: Bool

    var body: some View {
        TVRootHeroBackdrop(
            tintColor: model.tintColor,
            artworkURL: model.backdropURL,
            artworkThumbhash: model.backdropThumbhash,
            isVisible: model.backdropURL != nil,
            crossfadeDuration: reduceMotion ? 0 : ContinuumTheme.Skyline.marqueeCrossfadeDuration
        )
    }
}

private struct TVSkylineFlight {
    let sourceId: String
    let sourceIndex: Int
    var destinationId: String
    var destinationIndex: Int
    var visualTargetIndex: Int
    var direction: Int
    var generation: Int
    let pageExtents: [String: CGFloat]
    var isAwaitingFocus: Bool
    var hasAcceptedFocus: Bool
    var hasBeenRemoved: Bool
    var focusClaimFailed: Bool
    let reduceMotion: Bool
    var inputLatencyToken: Int
    let focusOwnerId: String
}

private struct TVSkylineVerticalCommand {
    /// Enough room for deliberate rapid clicks without allowing an unbounded
    /// hold to mount the entire feed or retain arbitrary remote events.
    static let queueLimit = 6

    let direction: Int
    let latencyToken: Int
}

private struct TVSkylineLayoutSignature: Equatable {
    let sectionId: String
    let rowKind: String
    let posterSize: String
    let caption: String
    let availableWidthPixels: Int
    let locale: String
    let dynamicType: String
    let itemsVersion: String
}

private struct TVSkylineMeasuredRow: Equatable {
    let signature: TVSkylineLayoutSignature
    let height: CGFloat
}

private struct TVSkylineRailPreparationKey: Equatable {
    let sectionId: String
    let stickyColumn: Int
    let itemsVersion: String
    let mountId: UUID
    let itemId: String
}

private struct TVSkylinePreparedRail: Equatable {
    let key: TVSkylineRailPreparationKey
    let generation: Int
}

#endif
