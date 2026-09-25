# Account quotas

The sidebar's **Usage и лимиты** button opens the account quota sheet. It shows each reported bucket and window independently: remaining percentage, reset time in the system time zone, and the snapshot fetch time. The account quota is distinct from per-chat context and cumulative token counts.

The native client reads `account/rateLimits/read` and prefers `rateLimitsByLimitId`; older engines fall back to `rateLimits`. `usedPercent` is consumed quota, so remaining is `100 - clamp(usedPercent, 0...100)`. Missing values remain unknown; absent windows are omitted. Unix reset timestamps are displayed as dates, not interpreted as evidence that quota has already recovered. The backend's explicit `ordinaryUsageAllowed: false` is surfaced separately.

Refresh happens after login, on opening the sheet, on manual refresh, and on `account/rateLimits/updated`. Notifications can be sparse, so they trigger a complete read. Concurrent reads are suppressed. There is no quota polling or model invocation. Failure retains the last snapshot with a stale-data message. Logout, account notifications and reconnection invalidate the cached snapshot and pending read identity.

Protocol reference: [Codex App Server account API](https://learn.chatgpt.com/docs/app-server#api-overview-1). This feature does not consume reset credits, buy credits, or change account settings.

Validation on 2026-09-25: 23 Swift Testing tests passed, including map precedence, independent quotas, legacy fallback, omitted windows, unknown values, reset units and out-of-range percentages. The release bundle built and was locally signed. The authenticated UI returned a single weekly Codex window; remaining percentage and local reset date were verified without sending a model turn. Live quota exhaustion and logout/login during an in-flight request were not exercised.
