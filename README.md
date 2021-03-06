# TarStream

> A tar streaming library written in Swift.

The SwiftTarStream allows the reading and writing of streams encoded in the tar format.

## Install

In the Package.swift file of your project add the line

`.Package(url: "https://github.com/NeoTeo/TarStream.git", majorVersion: 0)`

to the dependencies section of your package definition.

## Usage

In the file where you need to use the SwiftTarStream add the following statement:

`import TarStream`

## Examples

Create a tar stream containing two files and output it to stdout:

```Swift
/// Set up a read stream and feed it a string as input.
guard let d = "A simple stream of characters.".data(using: .utf8) else { fatalError("Invalid string!") }
let readStream = InputStream(data: d)

/// Create a tar stream instance and get a new archive from it.
let tar = TarStream()
let archive = tar.archive()

// Add an entry to the archive with the content of the read stream.
archive.addEntry(header: [TarHeader.Field.fileName : "file.txt"], dataStream: readStream)

/// Add an empty entry. We set the file's expected byte size in octal.
var entry: TarEntry = archive.addEntry(header: [.fileName : "greeting.txt", .fileByteSize : "12"]) {
    /// This is the entry end handler. 
    archive.closeArchive()
}

entry.write(data: "Hej")
entry.write(data: " ")
entry.write(data: "Verden")
entry.end()

/// Get the read stream from the archive. 
guard let tarStr = archive.tarReadStream else { fatalError("Cannot read archive!") }

/// Create write stream to stdout and pipe the archive to it.
guard let writeStream = OutputStream(toFileAtPath: "/dev/stdout", append: false) else {
    fatalError("Cannot create output stream!")
}

tarStr.pipe(into: writeStream) { exit(EXIT_SUCCESS) }
```

An example project using TarStream is [here](//github.com/NeoTeo/TarStreamExample)

## Requirements

Swift 3

## Todo

* Full extended tar compliance.
* Add linkedfile support.
* Add more examples

## Notes

HT to @mafintosh for inspiration.

## License
[MIT](LICENSE)
