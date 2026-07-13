package registry

import "time"

func (t *cacheRoutingTracker) hints(route CacheRoute, mode string, now time.Time) map[string]cacheRoutingHint {
	if t == nil || mode == CacheRoutingOff {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.sweepIfDueLocked(now)
	out := make(map[string]cacheRoutingHint)
	apply := func(key, kind string, confidence float64) {
		holders := t.holders[key]
		for providerID, holder := range holders {
			if !now.Before(holder.ExpiresAt) {
				t.removeHolderLocked(key, providerID)
				continue
			}
			if !holder.Confirmed || now.Before(holder.SuppressedUntil) {
				continue
			}
			saved := holder.PrefillTokensSaved
			if saved <= 0 {
				saved = holder.ReadyTokens - holder.RequiredRecomputeTokens
			}
			if saved <= 0 {
				continue
			}
			if prior, ok := out[providerID]; !ok || confidence > prior.Confidence {
				out[providerID] = cacheRoutingHint{Kind: kind, Confidence: confidence, PrefillTokensSaved: saved, CachedTokens: holder.CachedTokens, ReadyTokens: holder.ReadyTokens, RecomputeTokens: holder.RequiredRecomputeTokens, StageMs: holder.StageMs, Tier: holder.Tier}
			}
		}
	}
	if route.ExactKey != "" {
		apply(route.ExactKey, "exact", 1)
	}
	if (mode == CacheRoutingConversation || mode == CacheRoutingObserve) && route.ConversationKey != "" {
		confidence := 0.4
		if route.ConversationKind == "explicit" {
			confidence = 0.6
		}
		apply(route.ConversationKey, "conversation_"+route.ConversationKind, confidence)
	}
	return out
}
