import WidgetKit
import SwiftUI

@main
struct FinanceTrackerWidgetBundle: WidgetBundle {
    var body: some Widget {
        BudgetGaugeWidget()
        QuickLogWidget()
    }
}
