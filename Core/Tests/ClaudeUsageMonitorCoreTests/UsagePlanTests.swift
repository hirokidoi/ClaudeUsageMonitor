import Foundation
import Testing
@testable import ClaudeUsageMonitorCore

struct UsagePlanTests {
    private let activeWindow = UsageWindow(utilization: 10, resetsAt: nil)
    private let enabledExtra = ExtraUsage(isEnabled: true, utilization: 50)
    private let disabledExtra = ExtraUsage(isEnabled: false, utilization: nil)

    private func cache(
        _ type: String?, five: UsageWindow? = nil, seven: UsageWindow? = nil, extra: ExtraUsage? = nil
    ) -> UsageCache {
        UsageCache(fetchedAtMs: 1, organizationType: type, fiveHour: five, sevenDay: seven, extraUsage: extra)
    }

    @Test func enterpriseTypeIsEnterprise() {
        #expect(UsagePlan.decide(cache("claude_enterprise", extra: enabledExtra)) == .enterprise)
        #expect(UsagePlan.decide(cache("claude_enterprise", five: activeWindow, seven: activeWindow)) == .enterprise)
    }

    @Test(arguments: ["claude_max", "claude_pro"])
    func maxAndProAreIndividualEvenWithExtraUsageAndEmptyFiveHour(type: String) {
        #expect(UsagePlan.decide(cache(type, five: nil, seven: activeWindow, extra: enabledExtra)) == .individual)
        #expect(UsagePlan.decide(cache(type, extra: enabledExtra)) == .individual)
        #expect(UsagePlan.decide(cache(type)) == .individual)
    }

    @Test(arguments: [nil, "claude_team", "something_new"] as [String?])
    func otherTypesFollowTheContent(type: String?) {
        #expect(UsagePlan.decide(cache(type, five: activeWindow)) == .individual)
        #expect(UsagePlan.decide(cache(type, seven: activeWindow)) == .individual)
        #expect(UsagePlan.decide(cache(type, five: activeWindow, extra: enabledExtra)) == .individual)
        #expect(UsagePlan.decide(cache(type, extra: enabledExtra)) == .enterprise)
        #expect(UsagePlan.decide(cache(type, extra: disabledExtra)) == .individual)
        #expect(UsagePlan.decide(cache(type)) == .individual)
    }
}
