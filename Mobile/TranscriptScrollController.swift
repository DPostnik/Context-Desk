import SwiftUI
import UIKit

/// SwiftUI's scrollTo can be ignored during UIKit deceleration. Explicit user
/// jumps cancel native motion before setting the final offset; passive following
/// continues to use SwiftUI and never interrupts someone reading older messages.
@MainActor final class TranscriptScrollController: ObservableObject {
    weak var scrollView: UIScrollView?
    @discardableResult func jumpToBottom() -> Bool {
        guard let scrollView else { return false }
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.panGestureRecognizer.isEnabled = true
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        scrollView.layoutIfNeeded()
        let bottom = max(-scrollView.adjustedContentInset.top,
                         scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: bottom), animated: false)
        return true
    }
}
