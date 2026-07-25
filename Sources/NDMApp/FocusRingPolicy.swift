import AppKit

/// Show the focus ring for keyboard focus, and not for pointer focus.
///
/// A focus ring answers the question "where will my next keystroke go". Someone who
/// just clicked a button already knows — their pointer is on it — so the ring tells
/// them nothing and reads as an accidental highlight. Someone tabbing has no other
/// way to find out, and for them the ring is the entire navigation model. AppKit
/// draws it for both, because `focusRingType` is a property of the control rather
/// than of how the control was reached.
///
/// The web solved this with `:focus-visible`; there is no AppKit equivalent, so this
/// is it. A single monitor records what kind of input most recently moved focus, and
/// controls consult it when they become first responder.
///
/// Before this the app had twenty scattered `focusRingType` assignments — some
/// `.none`, some `.default`, some `.exterior` — set by whoever last noticed a ring
/// in the wrong place. That is a symptom, not a policy: a control cannot decide
/// statically whether its ring is wanted, because the answer depends on the user.
@MainActor
enum FocusRingPolicy {
    /// The ring shown when focus arrived by keyboard.
    static let keyboardRing: NSFocusRingType = .exterior

    /// True when the most recent input that could move focus was a key press.
    ///
    /// Starts true: an app launched and driven from the keyboard should show focus
    /// before the user has touched the mouse at all.
    private(set) static var lastInputWasKeyboard = true

    private static var monitor: Any?

    /// Install once, at startup. Idempotent.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            switch event.type {
            case .keyDown:
                // Modifier-only presses (⌘ held before a click) are not navigation.
                if !event.modifierFlags.intersection([.command, .control, .option])
                    .isEmpty && event.charactersIgnoringModifiers?.isEmpty != false {
                    break
                }
                lastInputWasKeyboard = true
            default:
                lastInputWasKeyboard = false
            }
            return event
        }
    }

    /// The ring a control should be wearing right now.
    static var currentRing: NSFocusRingType {
        lastInputWasKeyboard ? keyboardRing : .none
    }
}

extension NSView {
    /// Adopt the focus-ring policy. Call from `becomeFirstResponder`.
    ///
    /// Returns its argument so an override can stay a one-liner:
    ///
    ///     override func becomeFirstResponder() -> Bool {
    ///         adoptFocusRingPolicy(super.becomeFirstResponder())
    ///     }
    @discardableResult
    func adoptFocusRingPolicy(_ became: Bool) -> Bool {
        if became { focusRingType = FocusRingPolicy.currentRing }
        return became
    }
}
