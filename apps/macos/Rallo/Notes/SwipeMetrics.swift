import CoreGraphics

/// Which action tray a row is showing.
enum SwipeSide: Equatable {
    case remind
    case delete
}

struct OpenSwipe: Equatable {
    let id: String
    let side: SwipeSide
}

/// Tray widths and thresholds shared by mouse drags and trackpad swipes.
enum SwipeMetrics {
    static let remindButtonWidth: CGFloat = 64
    static var remindWidth: CGFloat { remindButtonWidth * CGFloat(RemindPreset.allCases.count) }
    static let deleteWidth: CGFloat = 78
    /// Past this share of the row width, releasing a left swipe deletes.
    static let fullDeleteFraction: CGFloat = 0.55

    static func restingOffset(_ side: SwipeSide?) -> CGFloat {
        switch side {
        case .remind: remindWidth
        case .delete: -deleteWidth
        case nil: 0
        }
    }

    /// Past a tray's full width the row resists instead of sliding freely.
    static func rubberBanded(_ offset: CGFloat, rowWidth: CGFloat) -> CGFloat {
        let maxRight = remindWidth
        let maxLeft = rowWidth
        if offset > maxRight { return maxRight + (offset - maxRight) * 0.25 }
        if offset < -maxLeft { return -maxLeft }
        return offset
    }
}
