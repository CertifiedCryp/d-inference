import Foundation

/// Provider-side result used to build both the lookup receipt and terminal
/// usage. A lookup is final only after the engine resolves adoption.
public struct PrefixCacheLookupResult: Sendable, Equatable {
    public let outcome: PrefixCacheLookupOutcome
    public let tier: PrefixCacheTier?
    public let cachedTokens: Int
    public let prefillTokensSaved: Int
    public let stageMs: Double?

    public init(
        outcome: PrefixCacheLookupOutcome,
        tier: PrefixCacheTier? = nil,
        cachedTokens: Int = 0,
        prefillTokensSaved: Int = 0,
        stageMs: Double? = nil
    ) {
        self.outcome = outcome
        self.tier = tier
        self.cachedTokens = max(0, cachedTokens)
        self.prefillTokensSaved = max(0, prefillTokensSaved)
        self.stageMs = stageMs.map { max(0, $0) }
    }
}

public struct PrefixCacheReadyResult: Sendable, Equatable {
    public let readyTokens: Int
    public let requiredRecomputeTokens: Int
    public let expectedPrefillTokensSaved: Int
    public let tier: PrefixCacheTier

    public init(
        readyTokens: Int,
        requiredRecomputeTokens: Int,
        expectedPrefillTokensSaved: Int,
        tier: PrefixCacheTier = .ssd
    ) {
        self.readyTokens = max(0, readyTokens)
        self.requiredRecomputeTokens = max(0, requiredRecomputeTokens)
        self.expectedPrefillTokensSaved = max(0, expectedPrefillTokensSaved)
        self.tier = tier
    }
}

struct RemotePrefixCacheContext: Sendable, Equatable {
    let scope: String?
    let receiptNonce: String?

    init(cacheScope: String?, cacheReceiptNonce: String?) {
        self.scope = Self.nonEmpty(cacheScope)
        self.receiptNonce = Self.nonEmpty(cacheReceiptNonce)
    }

    var cacheEnabled: Bool { scope != nil }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}

enum PrefixCacheReceiptEmitter {
    static func callbacks(
        requestID: String,
        nonce: String?,
        send: SendHandle
    ) -> (
        lookup: (@Sendable (PrefixCacheLookupResult) -> Void)?,
        ready: (@Sendable (PrefixCacheReadyResult) -> Void)?
    ) {
        guard let nonce else { return (nil, nil) }
        let lookup: @Sendable (PrefixCacheLookupResult) -> Void = { result in
            let message = OutboundMessage.prefixCacheLookup(
                requestId: requestID,
                cacheReceiptNonce: nonce,
                outcome: result.outcome,
                tier: result.tier,
                cachedTokens: result.cachedTokens > 0 ? UInt64(result.cachedTokens) : nil,
                prefillTokensSaved: result.prefillTokensSaved > 0
                    ? UInt64(result.prefillTokensSaved) : nil,
                stageMs: result.stageMs)
            Task.detached { send.send(message) }
        }
        let ready: @Sendable (PrefixCacheReadyResult) -> Void = { result in
            let message = OutboundMessage.prefixCacheReady(
                requestId: requestID,
                cacheReceiptNonce: nonce,
                readyTokens: UInt64(result.readyTokens),
                requiredRecomputeTokens: UInt64(result.requiredRecomputeTokens),
                expectedPrefillTokensSaved: UInt64(result.expectedPrefillTokensSaved),
                tier: result.tier)
            Task.detached { send.send(message) }
        }
        return (lookup, ready)
    }
}

enum SSDPrefixCacheStageDisposition: Sendable, Equatable {
    case staged(matchedTokens: Int, expectedPrefillTokensSaved: Int, shortenedByCorruption: Bool)
    case missAbsent
    case missCorrupt
    case skippedCapacity
    case skippedCost
    case skippedPolicy
}

struct SSDPrefixCacheStageResult: Sendable, Equatable {
    let disposition: SSDPrefixCacheStageDisposition
    let stageMs: Double

    var staged: Bool {
        if case .staged = disposition { return true }
        return false
    }

    var stagedTokens: Int {
        if case .staged(let matched, _, _) = disposition { return max(0, matched) }
        return 0
    }

    func resolved(actualCachedTokens: Int, actualPrefillTokensSaved: Int? = nil)
        -> PrefixCacheLookupResult
    {
        let cached = max(0, actualCachedTokens)
        if cached > 0 {
            let saved = max(0, actualPrefillTokensSaved ?? cached)
            return PrefixCacheLookupResult(
                outcome: .hit,
                tier: .ssd,
                cachedTokens: cached,
                prefillTokensSaved: saved,
                stageMs: stageMs)
        }
        let outcome: PrefixCacheLookupOutcome
        switch disposition {
        case .staged:
            // Staging succeeded but the engine could not adopt. The engine's
            // richer terminal outcome overrides this fallback when available.
            outcome = .skippedCapacity
        case .missAbsent:
            outcome = .missAbsent
        case .missCorrupt:
            outcome = .missCorrupt
        case .skippedCapacity:
            outcome = .skippedCapacity
        case .skippedCost:
            outcome = .skippedCost
        case .skippedPolicy:
            outcome = .skippedPolicy
        }
        return PrefixCacheLookupResult(outcome: outcome, tier: .ssd, stageMs: stageMs)
    }
}
