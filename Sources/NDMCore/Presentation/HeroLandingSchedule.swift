import Foundation

/// Stage timings for the Hero → list-row landing morph, measured from the moment
/// the morph is requested.
///
/// Pure, because the defect it exists to prevent is pure arithmetic. Core Animation
/// groups are given a `beginTime` one frame in the future so they cannot start
/// mid-commit, but the reveal and the overlay teardown are wall-clock timers on the
/// main queue. The first version scheduled those from the *call* time while the
/// animation ran from the *begin* time, so the teardown deadline
/// (`duration + 0.02`) sat only ~3ms after the animation's real end
/// (`1/60 + duration`). One busy frame and the frozen cover was removed while still
/// fully opaque — which on screen is exactly the "pop" it was built to avoid.
///
/// Keeping the arithmetic here means the invariant ("teardown always lands clearly
/// after the last animated frame") is pinned by a test instead of by whoever edits
/// the animator next.
public struct HeroLandingSchedule: Equatable, Sendable {
    /// One frame at 60Hz — the unit the compositor actually works in.
    public static let frame: TimeInterval = 1.0 / 60.0

    /// Length of the morph itself.
    public let duration: TimeInterval
    /// How far in the future the CA group's `beginTime` is set.
    public let beginOffset: TimeInterval
    /// Fraction of the morph after which the live row takes over from the overlay.
    /// Below 1 on purpose: the handoff has to happen while the overlay still covers
    /// it, or there is a frame with neither drawn.
    public let revealFraction: Double
    /// Slack between the last animated frame and the overlay's removal.
    public let teardownMargin: TimeInterval

    public init(
        duration: TimeInterval = 0.46,
        beginOffset: TimeInterval = HeroLandingSchedule.frame,
        revealFraction: Double = 0.82,
        teardownMargin: TimeInterval = 3 * HeroLandingSchedule.frame
    ) {
        self.duration = max(0, duration)
        self.beginOffset = max(0, beginOffset)
        self.revealFraction = min(max(revealFraction, 0), 1)
        self.teardownMargin = max(HeroLandingSchedule.frame, teardownMargin)
    }

    /// When the morph's first animated frame lands.
    public var beginsAt: TimeInterval { beginOffset }

    /// When the morph's last animated frame lands.
    public var endsAt: TimeInterval { beginOffset + duration }

    /// When to hand the row back to the live view, mid-morph.
    public var revealAt: TimeInterval { beginOffset + duration * revealFraction }

    /// When the overlay may be removed.
    public var teardownAt: TimeInterval { endsAt + teardownMargin }

    /// Breathing room between the animation finishing and the overlay vanishing.
    /// The regression this type documents was this value going near zero.
    public var teardownSlack: TimeInterval { teardownAt - endsAt }
}
