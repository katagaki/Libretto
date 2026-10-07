import UIKit

/// Follows the keyboard for a view that runs on underneath it, rather than
/// stopping short at its top edge, where the keyboard's rounded corners
/// would show the cut. The view lays itself out again as the keyboard
/// moves, and scrolls its content clear of how far the keyboard reaches.
@MainActor
final class KeyboardOverlap: NSObject {
    private weak var view: UIView?
    /// The keyboard's frame in the screen's coordinates, empty when it is away.
    private var keyboardFrame: CGRect = .zero

    init(view: UIView) {
        self.view = view
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )
    }

    /// How far up from the view's bottom edge the keyboard covers it.
    var height: CGFloat {
        guard let view, let window = view.window, !keyboardFrame.isEmpty else { return 0 }
        let frame = view.convert(keyboardFrame, from: window.screen.coordinateSpace)
        let covered = view.bounds.intersection(frame)
        return covered.isNull ? 0 : max(0, view.bounds.maxY - covered.minY)
    }

    /// The bottom inset that keeps a scroll view's content above the
    /// keyboard, less what the system already insets it by for the home indicator.
    func contentInset(for scrollView: UIScrollView) -> CGFloat {
        let system = scrollView.adjustedContentInset.bottom - scrollView.contentInset.bottom
        return max(0, height - system)
    }

    @objc private func keyboardWillChange(_ notification: Notification) {
        let info = notification.userInfo
        let end = info?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
        keyboardFrame = notification.name == UIResponder.keyboardWillHideNotification ? .zero : end
        guard let view else { return }
        let duration = info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
        let curve = info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curve << 16)) {
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }
}
