import Foundation

@main struct GoogleSignInRetryTests {
    static func main() {
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let instant = ContinuousClock.now
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if condition { passed += 1 } else { failed += 1 }
        }
        func credential(expiresIn: TimeInterval = 3600) -> GoogleSignInRetryCredential {
            .init(idToken: "PRIVATE_SENTINEL", clientID: "client", projectID: "demo-myterm",
                  requestURI: URL(string: "http://127.0.0.1:12345/oauth2/callback")!,
                  expiresAt: wall.addingTimeInterval(expiresIn), now: wall, instant: instant)
        }
        let pending = credential()
        check(pending.remainingLifetime(now: wall, instant: instant) == 1800, "initial retry budget is thirty minutes")
        check(pending.remainingLifetime(now: wall.addingTimeInterval(1799), instant: instant.advanced(by: .seconds(1799))) == 1,
              "29:59 remains usable")
        check(pending.remainingLifetime(now: wall.addingTimeInterval(1800), instant: instant.advanced(by: .seconds(1800))) == 0,
              "30:00 is expired")
        let copy = pending
        check(copy.remainingLifetime(now: wall.addingTimeInterval(1801), instant: instant.advanced(by: .seconds(1801))) == 0,
              "copying or retrying never extends the original deadline")
        check(pending.remainingLifetime(now: wall.addingTimeInterval(-3600), instant: instant.advanced(by: .seconds(1800))) == 0,
              "wall clock rollback cannot extend the thirty-minute budget")
        check(pending.remainingLifetime(now: wall.addingTimeInterval(4000), instant: instant) == 0,
              "wall clock expiry is checked before exchange")
        let short = credential(expiresIn: 300)
        check(short.remainingLifetime(now: wall, instant: instant) == 270, "token expires earlier with a thirty-second safety margin")
        check(short.remainingLifetime(now: wall.addingTimeInterval(-3600), instant: instant.advanced(by: .seconds(270))) == 0,
              "clock rollback cannot extend the original shorter token deadline")
        check(credential(expiresIn: 29).remainingLifetime(now: wall, instant: instant) == 0,
              "nearly expired token is never retained")
        check(credential(expiresIn: .infinity).remainingLifetime(now: wall, instant: instant) == 0,
              "nonfinite lifetime fails closed")
        do {
            let token = try pending.tokenForExchange(clientID: "client", projectID: "demo-myterm", now: wall, instant: instant)
            check(token == "PRIVATE_SENTINEL", "matching original context can perform exchange")
        } catch { check(false, "matching context") }
        for (client, project) in [("other", "demo-myterm"), ("client", "other-project")] {
            do {
                _ = try pending.tokenForExchange(clientID: client, projectID: project, now: wall, instant: instant)
                check(false, "context mismatch")
            } catch GoogleSignInRetryError.contextMismatch { check(true, "another project/client cannot use this credential") }
            catch { check(false, "wrong context error") }
        }
        do {
            _ = try pending.tokenForExchange(clientID: "client", projectID: "demo-myterm", now: wall,
                                              instant: instant.advanced(by: .seconds(1800)))
            check(false, "expired exchange")
        } catch GoogleSignInRetryError.expired { check(true, "expired credential cannot be exchanged") }
        catch { check(false, "wrong expiry error") }
        check(!String(describing: pending).contains("PRIVATE_SENTINEL") && !String(reflecting: pending).contains("PRIVATE_SENTINEL"),
              "default credential descriptions redact the token")
        print("\(passed) Google retry deadline tests passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
