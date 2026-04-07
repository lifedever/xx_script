import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var viewModel: ProxyViewModel
    var body: some View {
        Text("Popover placeholder").frame(width: 280, height: 100)
    }
}
