//
//  TarStream.swift
//  TarStream
//
//  Created by teo on 31/10/2016.
//  Copyright © 2016 Matteo Sartori. All rights reserved.
//

import Foundation
import CallbackStreams

typealias VoidFunc = (() -> Void)

struct TarEntry {
    
    typealias HeaderType = [TarHeader.Field : String]
    
    // FIXME: Set approprite access levels for properties and methods
    var header = HeaderType() //Dictionary<TarHeader.Field, String>()
    var payload = [UInt8]()
    var endHandler: ((TarEntry) -> Void)?
    var stream: OutputStream?
    
    mutating func write(data: String) {
        payload += Array(data.utf8)
    }
    
    /** From the tar definition:
     The name, linkname, magic, uname, and gname are null-terminated character strings. All other fields are zero-filled octal numbers in ASCII. Each numeric field of width w contains w minus 1 digits, and a null.
     **/
    /// Turn the header dictionary into a single easy to write blob.
    internal func makeHeaderBlob() -> [UInt8] {
        /// Make a mutable copy
        var header = self.header
        
        var blob = Array<UInt8>(repeating: 0, count: TarHeader.byteSize)
        
        func copyData(for field: TarHeader.Field, pad: Bool = true) {
            
            var val = header[field] ?? ""
            
            let (off, size) = TarHeader.offsets[field.rawValue]
            
            if pad == true {
                /// pad with ascii zero
                let b = val.lengthOfBytes(using: .ascii)
                let zs = (size - b) - 1	/// the -2 leaves space for terminating null
                let zpad = String(repeating: "0", count: zs)
                val = zpad + val
            }
            
            let valBytes = Array(val.utf8)
            let valByteCount = valBytes.count
            
            if valByteCount > size {
                fatalError("Error. Field value exceeds field size!")
            }
            
            for index in 0 ..< valByteCount {
                blob[off+index] = valBytes[index]
            }
        }
        
        copyData(for: .fileName, pad: false)
        copyData(for: .fileMode)
        copyData(for: .ownerId)
        copyData(for: .groupId)
        copyData(for: .fileByteSize)
        copyData(for: .fileModTime)
        
        copyData(for: .fileType, pad: false)
        copyData(for: .linkedFileName, pad: false)
        copyData(for: .magic, pad: false)
        copyData(for: .version, pad: false)
        copyData(for: .uName, pad: false)
        copyData(for: .gName, pad: false)
        copyData(for: .devMajor)
        copyData(for: .devMinor)
        copyData(for: .prefix, pad: false)
        
        /// As the last thing calculate the checksum of the header and add it to the header
        let chksum = String(checksum(data: blob), radix: 8)
        header[.headerChecksum] = chksum
        print("the checksum is \(chksum)")
        copyData(for: .headerChecksum)
        
        return blob
    }
    
    private func checksum(data: [UInt8]) -> UInt16 {
        var chksum: UInt16 = 8 * 32
        for byteIndex in 0 ..< data.count {
            chksum += UInt16(data[byteIndex])
        }
        return chksum
    }
    
    /// Signal the end of the entry and call user end handler if it exists.
    mutating func end() {
        let rmdr = payload.count % Tar.blockSize
        if rmdr > 0 {
            /// Align payload to nearest block size
            //		let remainder = Tar.blockSize - payload.count
            let remainder = Tar.blockSize - rmdr
            let emptyBytes = Array<UInt8>(repeating: 0, count: remainder)
            payload += emptyBytes
        }
        
        endHandler?(self)
    }
    
    
}

enum TarStreamError : Error {
    case headerFieldMissing
}

public class TarStream  : NSObject {
    
    var tarReadStream: InputStream?
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
    /// get their data from the inpustream. This is because there's no guarantee
    /// that the inputstream of the first call to addEntry will finish before any
    /// subsequent calls to addEntry will. If we didn't order them sequentially we
    /// might end up with an interleaved or scrambled tar archive on the output.
    func addEntry(header: [TarHeader.Field : String], dataStream: InputStream) {
        
        serialQueue.async() {
            let sema = DispatchSemaphore(value: 0)
            var entry = TarEntry()
            
            var actualRead = 0
            
            print("addEntry received input stream \(dataStream)")
            
            /// close the entry (by writing size etc. to header)
            /// and add it to the self stream so a user can read the tar stream.
            dataStream.on(event: .endOfStream) {
                print("the given data stream has ended. The final payload was \(String(bytes: entry.payload, encoding: String.Encoding.utf8))")
                dataStream.close()
                dataStream.remove(from: .main, forMode: .defaultRunLoopMode)
                
                entry.header = header
                
                let mode = header[TarHeader.Field.fileMode] ?? "0"
                
                guard let m = mode_t(mode) else { fatalError("invalid filemode") }
                let fileType = self.modeToFileType(mode: m)
                entry.header[TarHeader.Field.fileType] = String(fileType.rawValue, radix: 8)
                
                entry.header[TarHeader.Field.fileMode] = fileType == .directory ? self.dmode : self.fmode
                
                // FIXME: Maybe move this into the entry itself as an action when it is closed
                entry.header[TarHeader.Field.fileByteSize] = String(actualRead, radix: 8)//String(entry.payload.count)
                // FIXME: Need to fill the header with data. Also need there to be reasonable defaults.
                //				entry.header[TarHeader.Field.fileType] =
                /// Convert Double time interval to Octal
                entry.header[TarHeader.Field.fileModTime] = String(Int(Date().timeIntervalSince1970), radix: 8)
                
                entry.header[TarHeader.Field.magic] = "ustar"
                
                entry.header[TarHeader.Field.version] = "00"
                
                //				entry.header[TarHeader.Field.prefix] = ""
                
                self.close(entry: entry) {
                    print("done writing entry!")
                    
                    sema.signal()
                }
            }
            
            /// read the data stream until end
            dataStream.on(event: .hasBytesAvailable) {
                print("addEntry hasbytesavailable on input stream \(dataStream)")
                
                var localDat: [UInt8] = Array(repeating: 0, count: self.bytesPerBlock)
                actualRead += dataStream.read(&localDat, maxLength: self.bytesPerBlock)
                
                /// append the localDat to the entry's payload
                entry.payload += localDat
            }
            
            dataStream.on(event: .openCompleted) {
                print("we're on!")
            }
            
            dataStream.schedule(in: .main, forMode: .defaultRunLoopMode)
            dataStream.open()
            
            print( "data has bytes available \(dataStream.hasBytesAvailable)")
            print("is main thread? \(Thread.isMainThread)")
            _ = sema.wait(timeout: .distantFuture)
            print("past sema")
            
        }
        
        //Operation.addDependency(previousOperation)
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
        print("Close entry")
        var e = entry
        e.end()
        /// Deadlock! This block will never get taken off the serialQueue
        /// addEntry isn't taken off serialQueue until the close it calls returns.
        /// But close, being on the serialQueue, doesn't get executed until all
        /// previous calls are done and thus we have a deadlock
        /// [addEntry, close]
        //		serialQueue.async() {
        //			let sema = DispatchSemaphore(value: 0)
        
        self.write(entry: entry, to: self.tarWriteStream!) {
            //				sema.signal()
            completionHandler()
        }
        //			print("waiting for semaphore")
        //			_ = sema.wait(timeout: .distantFuture)
        //			print("past semaphore")
        //		}
    }
    
    /// Called when user is done adding entries to the archive
    func closeArchive() {
        
        //		DispatchQueue.global(qos: .default).sync {
        serialQueue.async {
            /// an archive is terminated with two blocks of zeros
            let terminatorData = Array<UInt8>(repeating: 0, count: 2 * 512)
            
            //			self.write(payload: terminatorData, to: self.tarWriteStream!) {
            self.tarWriteStream!.write(payload: terminatorData) {
                print("Archive terminated")
                //			self.tarReadStream?.close()
                //			self.tarReadStream?.remove(from: .main, forMode: .defaultRunLoopMode)
                
                self.tarWriteStream?.close()
                self.tarWriteStream?.remove(from: .main, forMode: .defaultRunLoopMode)
            }
            
            print("Close archive")
        }
    }
    
    func write(entry: TarEntry, to stream: OutputStream, endHandler: @escaping VoidFunc) {
        
        /// First write out the header
        let hdr = entry.makeHeaderBlob()
        
        //		self.write(payload: hdr, to: stream) {
        stream.write(payload: hdr) {
            
            /// then write out the payload
            //			self.write(payload: entry.payload, to: stream, endHandler: endHandler)
            stream.write(payload: entry.payload, completionHandler: endHandler)
        }
    }
}

/// Helper methods
extension TarStream {
    
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
