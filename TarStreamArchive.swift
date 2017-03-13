//
//  TarStreamArchive.swift
//  TarStream
//
//  Created by teo on 31/10/2016.
//  Copyright © 2016 Matteo Sartori. All rights reserved.
//

import Foundation
import CallbackStreams

typealias VoidFunc = (() -> Void)

enum TarStreamArchiveError : Error {
    case headerFieldMissing
}

public class TarStreamArchive  : NSObject {
    
    public var tarReadStream: InputStream?
    var tarWriteStream: OutputStream?
    
    
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
            let sema = DispatchSemaphore(value: 0)
            var entry = TarEntry()
            
            var actualRead = 0
            
            /// close the entry (by writing size etc. to header)
            /// and add it to the self stream so a user can read the tar stream.
            dataStream.on(event: .endOfStream) {

                dataStream.close()
                dataStream.remove(from: .main, forMode: .defaultRunLoopMode)
                
                entry.header = header
                
                let mode = header[TarHeader.Field.fileMode] ?? "0"
                
                guard let m = mode_t(mode) else { fatalError("invalid filemode") }
                let fileType = self.modeToFileType(mode: m)
                entry.header[TarHeader.Field.fileType] = String(fileType.rawValue, radix: 8)
                
                entry.header[TarHeader.Field.fileMode] = fileType == .directory ? self.dmode : self.fmode
                
                entry.header[TarHeader.Field.fileByteSize] = String(actualRead, radix: 8)
                
                /// Convert Double time interval to Octal
                entry.header[TarHeader.Field.fileModTime] = String(Int(Date().timeIntervalSince1970), radix: 8)
                
                entry.header[TarHeader.Field.magic] = "ustar"
                
                entry.header[TarHeader.Field.version] = "00"
                
                self.close(entry: entry) {
                    /// Now that we've succefully closed and written the entry to 
                    /// the output stream we can signal this entry is done.
                    sema.signal()
                }
            }
            
            /// read the data stream as long as it has bytes available.
            dataStream.on(event: .hasBytesAvailable) {
                
                var localDat: [UInt8] = Array(repeating: 0, count: self.bytesPerBlock)
                actualRead += dataStream.read(&localDat, maxLength: self.bytesPerBlock)
                
                /// append the localDat to the entry's payload
                entry.payload += localDat
            }
            
            dataStream.schedule(in: .main, forMode: .defaultRunLoopMode)
            dataStream.open()
            
            /// Wait for the signal that the entry has been written to the output stream.
            _ = sema.wait(timeout: .distantFuture)
        }
    }
    
    
    
    func addEntry(header: [TarHeader.Field : String], endHandler: VoidFunc? = nil) -> TarEntry {
        var entry = TarEntry()
        
        entry.header = header
        
        entry.endHandler = { (updatedEntry: TarEntry) in
            /// add the end handler to the serial queue so we can be sure it doesn't
            /// get called before any previous writes are done.
            self.serialQueue.async() {
                self.close(entry: updatedEntry, completionHandler: endHandler!)
            }
        }
        
        
        return entry
    }
    
    /// Called when the user is done adding data to the current entry.
    func close(entry: TarEntry, completionHandler: @escaping VoidFunc) {

        var e = entry
        e.end()
        
        self.write(entry: entry, to: self.tarWriteStream!) {
            completionHandler()
        }
    }
    
    /// Called when user is done adding entries to the archive
    public func closeArchive() {
        
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
