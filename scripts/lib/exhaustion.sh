#!/usr/bin/env bash
# scripts/lib/exhaustion.sh — detect per-agent exhaustion signals from a
# finished task's log.
#
# Provides one function:
#
#   _endy_detect_exhaustion <agent> <log-path>
#       Stdout: short reason string (e.g. "rate_limit_exceeded") OR empty.
#       Always exit 0 — empty stdout means "no known signal detected".
#
# Reasons emitted (stable; auto-handoff.sh and tests rely on these strings):
#
#   rate_limit_exceeded   — provider returned 429 / quota / rate-limit
#   provider_quota        — opencode-specific provider-side quota
#   credit_exhausted      — cmd account ran out of credit / payment required
#   auth_failed           — 401 / 403 / invalid api key / missing env var
#   auth_required         — gemini missing GEMINI_API_KEY (a special-case
#                           "rate-limit-like" failure: the request shape
#                           still wants a handoff, just not for quota)
#   max_turns             — cmd hit its --max-turns ceiling with empty output
#   model_unavailable     — hermes model_not_supported / invalid_request_error
#                           against the configured provider
#
# Design notes:
#   - Patterns are intentionally conservative. We grep the tail of the log
#     (last ~64 KB) and only match strings we've seen each CLI emit in
#     real exhaustion events. Generic words like "Error:" or "Exception:"
#     are NOT here on purpose — false positives are worse than missed
#     handoffs because Phase 4 ends up routing a healthy task to a new
#     agent and burning context.
#   - Each agent has its own case branch. New agents should be added with
#     their specific emitted strings, not generic catch-alls.
#   - This is a library file — `set -e` style fatal errors are NOT used.
#     Callers source it and call the function; the function never aborts
#     a shell.

_endy_detect_exhaustion() {
    local agent="$1" log_path="$2"
    [[ -n "$agent" && -f "$log_path" ]] || return 0

    # Tail the last 64 KB to keep grep cheap. Exhaustion signals are
    # always emitted near the end of the log (right before the agent
    # exits), and a CLI can produce a very large log over a long run.
    local tail_content
    tail_content="$(tail -c 65536 "$log_path" 2>/dev/null)" || return 0
    [[ -z "$tail_content" ]] && return 0

    case "$agent" in
        gemini)
            # Quota / rate-limit (the most common reason endy will route
            # away from gemini free tier).
            if printf '%s' "$tail_content" | grep -qE 'RESOURCE_EXHAUSTED|quotaExceeded|rateLimitExceeded|HTTP/.* 429'; then
                echo "rate_limit_exceeded"
                return 0
            fi
            # Missing auth — strictly speaking not "exhaustion", but the
            # task can't continue on this agent so a handoff is the right
            # remedy if the user has other agents auth'd.
            if printf '%s' "$tail_content" | grep -qE 'GEMINI_API_KEY|GOOGLE_GENAI_USE_VERTEXAI|GOOGLE_GENAI_USE_GCA|Please set an Auth method'; then
                echo "auth_required"
                return 0
            fi
            ;;
        opencode)
            # OpenCode surfaces backend-provider errors with these names.
            if printf '%s' "$tail_content" | grep -qE 'ProviderModelNotFoundError|rate_limit_exceeded|insufficient_quota|usage_limit_exceeded|InsufficientQuotaError'; then
                echo "provider_quota"
                return 0
            fi
            if printf '%s' "$tail_content" | grep -qE 'Unauthorized|InvalidApiKey|forbidden access'; then
                echo "auth_failed"
                return 0
            fi
            ;;
        cmd|commandcode)
            # cmd's --max-turns ceiling is a soft exhaustion: the agent
            # didn't fail, but the conversation hit the budget. Handoff
            # lets a different agent finish with more turns.
            if printf '%s' "$tail_content" | grep -qE 'Reached maximum conversation turns'; then
                echo "max_turns"
                return 0
            fi
            if printf '%s' "$tail_content" | grep -qE 'insufficient credit|payment required|account.*balance'; then
                echo "credit_exhausted"
                return 0
            fi
            if printf '%s' "$tail_content" | grep -qE 'Unauthorized|please.*log.*in|cmd login'; then
                echo "auth_failed"
                return 0
            fi
            ;;
        hermes)
            # Hermes's error envelope wraps OpenAI-style error JSON.
            if printf '%s' "$tail_content" | grep -qE '"code"[[:space:]]*:[[:space:]]*"rate_limit_exceeded"|too many requests|HTTP/.* 429'; then
                echo "rate_limit_exceeded"
                return 0
            fi
            if printf '%s' "$tail_content" | grep -qE 'model_not_supported|invalid_request_error.*model|"type"[[:space:]]*:[[:space:]]*"invalid_request_error"'; then
                echo "model_unavailable"
                return 0
            fi
            ;;
        claude)
            if printf '%s' "$tail_content" | grep -qE 'usage_limit_exceeded|rate_limit_error|"status"[[:space:]]*:[[:space:]]*429|Anthropic API Error.*429'; then
                echo "rate_limit_exceeded"
                return 0
            fi
            if printf '%s' "$tail_content" | grep -qE 'authentication_error|invalid.*api.*key|ANTHROPIC_API_KEY'; then
                echo "auth_failed"
                return 0
            fi
            ;;
        codex)
            if printf '%s' "$tail_content" | grep -qE 'rate.limit.exceeded|HTTP/.* 429|insufficient_quota'; then
                echo "rate_limit_exceeded"
                return 0
            fi
            if printf '%s' "$tail_content" | grep -qE 'OPENAI_API_KEY|Unauthorized|401.*Unauthorized'; then
                echo "auth_failed"
                return 0
            fi
            ;;
        bash|stub|noop)
            # Offline stubs never exhaust. The synthetic-fail variant used
            # in tests/smoke-auto-handoff.sh writes its own signal lines
            # into the log, which the patterns above catch under the real
            # agent's case (the test rewrites agent= in the fake meta).
            ;;
    esac
    return 0
}
