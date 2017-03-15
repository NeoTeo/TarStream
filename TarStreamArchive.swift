//
//  TarStreamArchive.swift
//  TarStream
//
//  Created by teo on 31/10/2016.
//  Copyright © 2016 Matteo Sartori. All rights reserved.
//

import Foundation
import CallbackStreams

public typealias VoidFunc = (() -> Void)

enum TarStreamArchiveError : Error {
    case headerFieldMissing
}

public class TarStreamArchive  : NSObject {
    
    public var tarReadStream: InputStream?
    var tarWriteStream: OutputStream?
    
    var previousEntryFileName: String?
    
    let bytesPerBlock = 512
    let bufferSize: Int
    
    //	var currentEntry: TarEntry?
    var archiveCloser: VoidFunc?
    var serialQueue: DispatchQueue = DispatchQueue(label: "entryWriterQ", qos: .background)
    
    /// File and directory access flags
    let dmode = "755"
    let fmode = "644"
    
    public override init() {
        
        bufferSize = 2048 //bytesPerBlock
        
        super.init()
        
        /// Connect the tarReadStream to the tarWriteStream
        Stream.getBoundStreams(withBufferSize: bufferSize, inputStream: &tarReadStream, outputStream: &tarWriteStream)
        
        tarReadStream?.schedule(in: .main, forMode: .defaultRunLoopMode)
        tarWriteStream?.schedule(in: .main, forMode: .defaultRunLoopMode)
        
        tarReadStream?.open()
        tarWriteStream?.open()
    }
    
    func completeHeader(from headerFields: [TarHeader.Field : String], fileByteSize: Int = 0) -> [TarHeader.Field : String] {
        /// First we populate the return object with the default header fields.
        var complete = Dictionary<TarHeader.Field, String>() // shortform errored with "missing context"
        
        let mode = headerFields[TarHeader.Field.fileMode] ?? "0"
        
        guard let m = mode_t(mode) else { fatalError("invalid filemode") }
        let fileType = self.modeToFileType(mode: m)
        
        complete[TarHeader.Field.fileType] = String(fileType.rawValue, radix: 8)
        
        complete[TarHeader.Field.fileMode] = fileType == .directory ? self.dmode : self.fmode
        
        complete[TarHeader.Field.fileByteSize] = String(fileByteSize, radix: 8)
        
        /// Convert Double time interval to Octal
        complete[TarHeader.Field.fileModTime] = String(Int(Date().timeIntervalSince1970), radix: 8)
        
        //entry.header[TarHeader.Field.linkedFileName] = self.previousEntryFileName
        
        complete[TarHeader.Field.magic] = "ustar"
        
        complete[TarHeader.Field.version] = "00"
        
        /// Then add/override with fields from headerFields
        for (key, value) in headerFields {
            complete[key] = value
            print("key is \(key) and value is \(value) so we get \(complete[key])")
        }
        print("complete is \(complete)")
        return complete
    }
    
    /// A convenience method that takes no end handler and thus closes the archive
    /// immediately. It does not return the entry.
    /// This should be queued as an operation in a serial queue to avoid multiple
    /// addEntries trying to write to the same outputstream in whatever order they
    /// get their data from the inputstream. This is because there's no guarantee
    /// that the inputstream of the first call to addEntry will finish before any
    /// subsequent calls to addEntry will. If we didn't order them sequentially we
    /// might end up with an interleaved or scrambled tar archive on the output.
    public func addEntry(header: [TarHeader.Field : String], dataStream: InputStream) {
        /// Asynchronously add the block to the serial queue. The block won't return until done.
        serialQueue.async() {

            let fileName = header[TarHeader.Field.fileName]
            
            let group = DispatchGroup.init()
            var entry = TarEntry()
            
            
            var actualRead = 0
            
            /// close the entry (by writing size etc. to header)
            /// and add it to the self stream so a user can read the tar stream.
            dataStream.on(event: .endOfStream) {

                dataStream.close()
                dataStream.remove(from: .main, forMode: .defaultRunLoopMode)
                
                entry.header = self.completeHeader(from: header, fileByteSize: actualRead)
                
                self.close(entry: entry) {
                    /// Now that we've succefully closed and written the entry to 
                    /// the output stream we can signal this entry is done.
                    self.previousEntryFileName = fileName
                    
                    group.leave()

                }
            }
            
            /// read the data stream as long as it has bytes available.
            dataStream.on(event: .hasBytesAvailable) {
                
                var localDat: [UInt8] = Array(repeating: 0, count: self.bytesPerBlock)
            
                let bytesRead = dataStream.read(&localDat, maxLength: self.bytesPerBlock)
                if bytesRead > 0 {
                    actualRead += bytesRead
                
                    /// append the localDat to the entry's payload
                    entry.payload += localDat
                    print("payload size \(entry.payload.count)")
                }
            }
            
            group.enter()
            dataStream.schedule(in: .main, forMode: .defaultRunLoopMode)
            dataStream.open()
       
            group.wait()
            print("Add Entry Done")
        }
    }
    
    public func addEntry(header: [TarHeader.Field : String], endHandler: VoidFunc? = nil) -> TarEntry {
        print("TarStreamArchive addEntry called.")
        
        let fileName = header[TarHeader.Field.fileName]
        
        var entry = TarEntry()

        entry.header = completeHeader(from: header)

        /// Wrap the user's entry end handler in a closure that is called
        /// (with an updated entry where extra house keeping has been done)
        /// when TarEntry's end() is called by the user.
        entry.endHandler = { (updatedEntry: TarEntry) in
        
            self.previousEntryFileName = fileName
            /// add the call to the close method on the serial queue to ensure it doesn't
            /// get called before any previously queued writes are done. Pass the user's
            /// entry end handler through to the close method.
            self.serialQueue.async() {
                self.close(entry: updatedEntry, completionHandler: endHandler!)
            }
        }
        
        return entry
    }
    
    /// Called when the user is done adding data to the current entry.
    func close(entry: TarEntry, completionHandler: @escaping VoidFunc) {
        
        /// This is where we end up calling the end twice; once when the user explicitly calls entry.end()
        /// and once here which is called as part of the TarEntry's end handler.
        //var e = entry
        //e.end()
        
        self.write(entry: entry, to: self.tarWriteStream!) {
            completionHandler()
        }
    }
    
    /// Called when user is done adding entries to the archive
    public func closeArchive() {
        
        print("TarStreamArchive close")
        serialQueue.async {
            /// an archive is terminated with two blocks of zeros
            let terminatorData = Array<UInt8>(repeating: 0, count: 2 * 512)
            
            self.tarWriteStream!.write(payload: terminatorData) {
                
                self.tarWriteStream?.close()
                self.tarWriteStream?.remove(from: .main, forMode: .defaultRunLoopMode)
            }
        }
    }
    
    func write(entry: TarEntry, to stream: OutputStream, endHandler: @escaping VoidFunc) {
        
        print("TarStreamArchive write called.")

        /// First write out the header
        let hdr = entry.makeHeaderBlob()
        
        stream.write(payload: hdr) {
        
            /// then write out the payload
            stream.write(payload: entry.payload, completionHandler: endHandler)
        }
    }
}

/// Helper methods
extension TarStreamArchive {
    
    internal func modeToFileType(mode: mode_t) -> TarHeader.FileTypes {
        switch mode & S_IFMT {
        case S_IFBLK: return .blockSpecial
        case S_IFCHR: return .characterSpecial
        case S_IFDIR: return .directory
        case S_IFIFO: return .fifo
        case S_IFLNK: return .symbolicLink
        default:	  return .regular
        }
    }
}
