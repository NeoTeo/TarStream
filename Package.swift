import PackageDescription

let package = Package(
    name: "TarStream",
    dependencies: [
        .Package(url: "https://github.com/NeoTeo/CallbackStreams.git", majorVersion: 0),
    ]
)
