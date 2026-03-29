import SwiftUI

struct MainView: View {
    let api: ClashAPI
    let singBoxManager: SingBoxManager
    let configGenerator: ConfigGenerator

    var body: some View {
        Text("BoxX Dashboard")
            .frame(minWidth: 800, minHeight: 500)
    }
}
