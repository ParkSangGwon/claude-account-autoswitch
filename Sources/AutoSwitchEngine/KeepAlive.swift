import Foundation
import AutoSwitchCore

/// Keeping the five-hour windows running on the clock.
///
/// Claude starts an account's five-hour window at its first request, so a window entered at 16:30
/// runs to 21:30 and the day holds fewer of them than the 4.8 it could. When this is on, the engine
/// sends one tiny request of its own the moment a window resets, and the next one starts on time
/// whether or not anybody is at the Mac.
///
/// It does not go through `Relay`: no session is pinned, the cursor does not move, and the account's
/// traffic counters stay a record of what the user actually sent.
extension Engine {
    /// How often the pass wakes when no reset is closer than that. Short enough that a Mac that has
    /// just woken picks up a reset it slept through within the minute, and cheap next to the probe.
    static let keepAliveTick: TimeInterval = 60
    /// A try that opened nothing is not repeated before this — a rejection every minute on the
    /// user's own account is worse than a window that opens late.
    static let keepAliveRetry: TimeInterval = 300

    func startKeepAliveLoop() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let seconds = await self.keepSessionsOpen()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    /// One pass; returns how long to sleep before the next.
    @discardableResult
    func keepSessionsOpen(now: Date = Date()) async -> TimeInterval {
        guard configuration.quota.keepSessionOpen else { return Engine.keepAliveTick }
        sweepAccounts(now: now)
        for id in runtime.filter({ needsOpening($0, now: now) }).map(\.id) { await openWindow(of: id) }
        return sleepBeforeNextPass(now: now)
    }

    /// `sweep` drops a reading whose reset has passed, so a missing five-hour window *is* a closed
    /// one. `blocker` covers the rest in one line: a disabled, held, capped, cooling, refused or
    /// logged-out account, and one whose week is spent — a new five hours it could not use anyway.
    private func needsOpening(_ r: AccountRuntime, now: Date) -> Bool {
        guard r.record.kind == .subscription else { return false }
        guard r.windows[.session] == nil else { return false }
        guard blocker(of: r, now: now) == nil else { return false }
        guard let last = r.lastKeepAliveAt else { return true }
        return now.timeIntervalSince(last) >= Engine.keepAliveRetry
    }

    private func openWindow(of id: AccountID) async {
        guard let i = runtimeIndex(id) else { return }
        let label = runtime[i].label
        runtime[i].lastKeepAliveAt = Date()
        func fail(_ why: String) { keepAliveError = "\(label): \(why)" }
        guard await ensureFreshToken(id), let j = runtimeIndex(id), let token = runtime[j].oauthTokens?.access else {
            return fail(L("no usable token"))
        }
        do {
            let asked = Date()
            let headers = try await OAuth.ping(accessToken: token)
            guard let k = runtimeIndex(id) else { return }
            Signals.absorb(headers, into: &runtime[k].windows)
            keepAliveError = nil
            lastKeepAliveOpenedAt = asked
            saveObservations()
        } catch EngineError.oauthRejected(let status, _) where status == 401 {
            _ = await ensureFreshToken(id, force: true)
            fail("401")
        } catch let e as EngineError {
            fail(e.message)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Until the first window reset, capped at the tick: a reset an hour out is not worth waking for
    /// sooner, and one two seconds out is worth waking for exactly then.
    private func sleepBeforeNextPass(now: Date) -> TimeInterval {
        let next = runtime.compactMap { $0.windows[.session]?.resetsAt }.filter { $0 > now }.min()
        let until = next.map { $0.timeIntervalSince(now) } ?? Engine.keepAliveTick
        return max(1, min(until, Engine.keepAliveTick))
    }
}
