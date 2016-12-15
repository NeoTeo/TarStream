//
//  TarEntry.swift
//  TarStream
//
//  A tar consists of a sequence of entries. TarEntry represents one such entry.
//  Created by Teo Sartori on 15/12/2016.
//
//

import Foundation

struct TarEntry {
    
    typealias HeaderType = [TarHeader.Field : String]
    
    var header = HeaderType()
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
        let rmdr = payload.count % TarStream.blockSize
        if rmdr > 0 {
            /// Align payload to nearest block size
            let remainder = TarStream.blockSize - rmdr
            let emptyBytes = Array<UInt8>(repeating: 0, count: remainder)
            payload += emptyBytes
        }
        
        endHandler?(self)
    }
}
