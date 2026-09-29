import WidgetKit
import SwiftUI

@main
struct OmnivoxNeoWidgetBundle: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        DayWidget()
    }
}
