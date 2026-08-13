import Foundation

enum PlaybackSourcePrefetchPolicy {
    /// Bound only the speculative lead while SiloPlayer is preparing its
    /// first local-HLS fragment. The MKV planner performs latency-sensitive
    /// head, tail, and midpoint reads before it can publish the VOD manifest.
    /// Letting the unrelated sequential window fill the complete 256 MiB
    /// source-cache budget during those probes can consume the WAN, evict
    /// startup bytes, and make the real reader re-anchor the window.
    ///
    /// This is an ahead-of-demand limit, not a download or startup quota:
    /// cached reads advance the demand mark every 256 KiB, and a blocked read
    /// at the cursor always overrides the limit. The view model releases it
    /// after first frame so steady-state playback recovers the full cache
    /// budget and its normal outage runway.
    static let loopbackStartupMaximumAheadBytes: Int64 = 64 * 1024 * 1024

    static func initialOffset(
        sourceStartTimeSeconds: Double,
        sourceBitrateBps: Double?
    ) -> Int64 {
        guard sourceStartTimeSeconds.isFinite,
              sourceStartTimeSeconds > 0,
              let sourceBitrateBps,
              sourceBitrateBps.isFinite,
              sourceBitrateBps > 0 else {
            return 0
        }

        let offset = (sourceStartTimeSeconds * sourceBitrateBps / 8).rounded(.down)
        guard offset.isFinite, offset > 0 else { return 0 }

        return Int64(min(offset, Double(Int64.max - 1)))
    }
}
