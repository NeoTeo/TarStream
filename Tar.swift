//
//  Tar.swift
//  TarStream
//
//  Created by Teo Sartori on 29/09/2016.
//  Copyright © 2016 Matteo Sartori. All rights reserved.
//

import Cocoa

enum TarHeaderError : Error {
    case fileName
    case fileMode
    case ownerId
    case groupId
    case fileSize
    case modificationDate
    case checksum
    case fileType
    case linkName
    
    case ustarVersion
    case ustarUName
    case ustarGName
    case ustarDevMajor
    case ustarDevMinor
    case ustarPrefix
}

class Tar : NSObject {
    
    open static let blockSize = 512
    //        parseTarHeader(in: getBytes(in: data, fromByte: 0, count: data.count))
    //    var retString = ""
    var tarBytes = [UInt8]()
    var runningTotal = 0
    var tarStream: InputStream?
    var entryHandler: ((TarHeader, InputStream, @escaping () -> Void) -> Void)?
    var endHandler: (() -> Void)?
    
    /// Track the number of null blocks read to catch end of tar file.
    var nullBlocks = 0
    
    override init() {
        super.init()
    }
    
    /// Return an archive to which the client can add entries.
    func archive() -> TarStream {
        /** Make a read stream from which a user can read the tar stream.
         It will, when the user adds entries to the archive, make those entries
         readable as data in the Tar format.
         **/
        return TarStream()
    }
    
    func nextEntry() {
        parse(tarStream: tarStream!)
    }
    
    func setInputStream(tarStream: InputStream) {
        self.tarStream = tarStream
        //		self.tarStream!.delegate = self
        
        tarStream.on(event: .openCompleted) {
            self.parse(tarStream: tarStream)
        }
    }
    
    func setEntryHandler(handler: @escaping ((TarHeader, InputStream, @escaping () -> Void))-> Void) {
        entryHandler = handler
    }
    
    
    /// Read byteCount bytes from the stream collecting it in readData.
    /// Call the handler when the data is successfully read.
    ///
    /// - parameter stream:    <#stream description#>
    /// - parameter byteCount: <#byteCount description#>
    /// - parameter readData:  <#readData description#>
    /// - parameter handler:   <#handler description#>
    func read(stream: InputStream, byteCount: Int, readData: [UInt8], handler: @escaping ([UInt8]) -> Void) {
        
        var newData = readData
        
        /// Keep reading the stream until we've reached the required amount.
        while newData.count < byteCount {
            
            guard stream.hasBytesAvailable == true else {
                
                /// No bytes available at this time. Register a callback for when bytes become available.
                let handlerId = UUID().uuidString
                stream.on(event: .hasBytesAvailable, handlerUuid: handlerId) {
                    
                    /// Now that bytes are available again we diable the callback...
                    stream.on(event: .hasBytesAvailable, handlerUuid: handlerId, handler: nil)
                    
                    /// ...and call read recursively.
                    self.read(stream: stream, byteCount: byteCount, readData: newData, handler: handler)
                }
                return
            }
            
            /// Read available bytes and add them to the newData buffer.
            let maxLen = Tar.blockSize
            let streamBuf: [UInt8] = Array(repeating: 0, count: maxLen)
            let buf = UnsafeMutablePointer<UInt8>(mutating: streamBuf)
            
            let bytesRead = stream.read(buf, maxLength: byteCount)
            
            newData += streamBuf[0 ..< bytesRead]
        }
        
        /// We've read all the requested data. Call the handler with it.
        handler(newData)
    }
    
    func parse(tarStream: InputStream) {
        
        let headerData = [UInt8]()
        
        /// read the byteCount number of bytes and call the block with the result.
        read(stream: tarStream, byteCount: Tar.blockSize, readData: headerData) { data in
            /// This is the handler that receives the 512 bytes of header data.
            //			print("header data is \(data.count) bytes")
            //			print("and it is: \(String(bytes: data, encoding: String.Encoding.utf8))")
            
            do {
                /// Parse the header data...
                let header = try self.parseTarHeader(in: data)
                //				print("parse header: \(header)")
                
                /// The header data will reveal how much subsequent data to expect.
                let dataData = [UInt8]()
                
                /// Extract the file byte size from the header
                guard let fileByteSize = Int(header.fileByteSize, radix: 8) else {
                    throw TarHeaderError.fileSize
                }
                
                /// Calculate the number of bytes to read (in multiples of block sizes)
                let byteCount = Int(ceil(Double(fileByteSize) / Double(Tar.blockSize))) * Tar.blockSize
                
                print("bytecount is \(byteCount) bytes")
                self.read(stream: tarStream, byteCount: byteCount, readData: dataData) { data in
                    
                    /// This is the handler that receives the read header data.
                    //					print("Data data is \(data.count) bytes")
                    //					print("and it is: \(String(bytes: data, encoding: String.Encoding.utf8))")
                    
                    /// In here we call the entry handler since we have both the header and the data.
                    /// To allow the entry handler to read the data as a stream we put the data into a
                    /// new stream; dataStream and pass it into the handler.
                    /// The callback we pass in should, when called, initiate the reading of the next entry.
                    /// The tarStream at this point is set to the first byte of the next header.
                    print("Adding \(data.count) bytes to dataInputStream")
                    /// The data we put into the data stream does not need to be aligned
                    /// to the tar block size so we just add the actual data.
                    let dataStream = InputStream(data: Data(bytes: data[0 ..< fileByteSize]))
                    //					dataStream.open()
                    
                    self.entryHandler?(header, dataStream, self.nextEntry)
                    
                }
                
            } catch {
                /// This block is called if the parseTarHeader threw an error.
                
                /// check we have 512 bytes of 0
                /// This marks one of two blocks that signal the end of an archive.
                guard data.count == Tar.blockSize, self.isNullBlock(block: data) == true else {
                    print("Parse tar error \(error)")
                    return
                }
                
                /// At this point we know we have a null block.
                /// If it's the first one, remember and try the next entry.
                if self.nullBlocks == 0 {
                    self.nullBlocks = 1
                    /// Try the next entry
                    self.nextEntry()
                } else {
                    // We've received two consecutive null blocks. Exit.
                    self.finish()
                    return
                }
            }
        }
    }
    
    func isNullBlock(block: [UInt8]) -> Bool {
        for val in block {
            if val != 0 { return false }
        }
        return true
    }
    
    func finish() {
        print("Tar done")
        endHandler?()
    }
    
    
    func trim(bytes: [UInt8]) -> [UInt8] {
        guard bytes.count > 0 else { return bytes }
        
        func isTrimVal(val: UInt8) -> Bool {
            return (val == 0) || (val == 32)
        }
        
        var trimmed = 0
        for val in bytes.reversed() {
            guard isTrimVal(val: val) == true else { break }
            trimmed += 1
        }
        //		var i = bytes.count - 1
        //		while isTrimVal(val: bytes[i]) == true { i -= 1 }
        
        return Array(bytes[0 ..< bytes.count - trimmed])
    }
    
    func trimAndStringify(bytes: [UInt8]) -> String? {
        /// Trim trailing 0 or newlines
        let nubytes = trim(bytes: bytes)
        
        return String(bytes: nubytes, encoding: String.Encoding.ascii)
    }
    
    func bytesToInt(bytes: [UInt8], radix: Int) -> Int? {
        /// Trim trailing 0 or newlines
        let nubytes = trim(bytes: bytes)
        
        guard let val = String(bytes: nubytes, encoding: String.Encoding.ascii) else {
            return nil
        }
        
        return Int(val, radix: radix)
    }
    
    /** filename, linkname, magic, uname and gname are null terminated character strings.
     All other fields are zero-filled octal numbers in ascii.
     Each numeric field of width w contains w - 1 digits and a NUL, except
     size and mtime which do not contain trailing NUL.
     
     FIXME: The code that extracts the individual fields should be specialized
     so that it can handle the quirks and special cases of each.
     **/
    func parseTarHeader(in bytes: [UInt8]) throws -> TarHeader {
        /// Some sanity checks
        print("parse tar received \(bytes.count) bytes")
        /// File name
        var fieldIndex = 0
        
        guard let filename = headerField(at: fieldIndex, bytes: bytes) else {
            throw TarHeaderError.fileName
        }
        fieldIndex += 1
        
        /// File mode
        guard let mode = headerField(at: fieldIndex, bytes: bytes) else {
            throw TarHeaderError.fileMode
        }
        fieldIndex += 1
        /// Owner id
        guard let ownerId = headerField(at: fieldIndex, bytes: bytes) else {
            throw TarHeaderError.ownerId
        }
        fieldIndex += 1
        
        /// Group id
        guard let groupId = headerField(at: fieldIndex, bytes: bytes) else {
            throw TarHeaderError.fileMode
        }
        fieldIndex += 1
        
        /// File size
        guard let fileSize = headerField(at: fieldIndex, bytes: bytes) else {
            throw TarHeaderError.fileSize
        }
        fieldIndex += 1
        
        /// Modification date
        guard let fileModTime = headerField(at: fieldIndex, bytes: bytes) else {
            throw TarHeaderError.modificationDate
        }
        fieldIndex += 1
        
        guard let checksum = headerField(at: fieldIndex, bytes: bytes) else {
            throw TarHeaderError.checksum
        }
        fieldIndex += 1
        
        /// Link type indicator
        guard let fileType = headerField(at: fieldIndex, bytes: bytes) else {
            throw TarHeaderError.fileType
        }
        fieldIndex += 1
        
        guard let linkName = headerField(at: fieldIndex, bytes: bytes) else {
            throw TarHeaderError.linkName
        }
        fieldIndex += 1
        
        /// Check for ustar format
        if let magic = headerField(at: fieldIndex, bytes: bytes), magic == "ustar" {
            fieldIndex += 1
            print("header is ustar")
            
            /// get the ustar version
            guard let version = headerField(at: fieldIndex, bytes: bytes) else {
                throw TarHeaderError.ustarVersion
            }
            fieldIndex += 1
            
            guard let uname = headerField(at: fieldIndex, bytes: bytes) else {
                throw TarHeaderError.ustarUName
            }
            fieldIndex += 1
            
            guard let gname = headerField(at: fieldIndex, bytes: bytes) else {
                throw TarHeaderError.ustarGName
            }
            fieldIndex += 1
            
            guard let devMajor = headerField(at: fieldIndex, bytes: bytes) else {
                throw TarHeaderError.ustarDevMajor
            }
            fieldIndex += 1
            
            guard let devMinor = headerField(at: fieldIndex, bytes: bytes) else {
                throw TarHeaderError.ustarDevMinor
            }
            fieldIndex += 1
            
            guard let prefix = headerField(at: fieldIndex, bytes: bytes) else {
                throw TarHeaderError.ustarPrefix
            }
            fieldIndex += 1
            
            print("Version: \(version), uname \(uname) and gname \(gname)")
            return TarHeader(fileName: filename, fileMode: mode, ownerID: ownerId, groupID: groupId, fileByteSize: fileSize, fileModTime: fileModTime, headerChecksum: checksum, fileType: fileType, linkedFileName: linkName, magic: magic, version: version, uName: uname, gName: gname, devMajor: devMajor, devMinor: devMinor, prefix: prefix)
        }
        
        return TarHeader(fileName: filename, fileMode: mode, ownerID: ownerId, groupID: groupId, fileByteSize: fileSize, fileModTime: fileModTime, headerChecksum: checksum, fileType: fileType, linkedFileName: linkName)
        
    }
    
    
    /// Return, as a string, the field data found in the given bytes at the given offset.
    ///
    /// - parameter index: The index of the field in the header structure.
    /// - parameter bytes: The byte array containing the header data.
    ///
    /// - returns: A string with the data of the requested field or nil if nothing was found.
    func headerField(at index: Int, bytes: [UInt8]) -> String? {
        
        let (offset, size) = TarHeader.offsets[index]
        let buffer = bytes[offset ..< offset + size]
        let data = trimAndStringify(bytes: Array(buffer))
        return data
    }
    
    func getBytes(in data: Data, fromByte: Int, count: Int) -> [UInt8] {
        
        var buffer: [UInt8] = Array(repeating: 0, count: count)
        data.copyBytes(to: &buffer, from: Range(fromByte ..< fromByte + count))
        
        return buffer
    }
}

/*
 extension Tar : StreamDelegate {
	
	func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
 
 let isInputStream = aStream.isEqual(tarStream)
 let streamTypeDescription = isInputStream ? "ReadStream" : "WriteStream"
 
 //		print("Tar stream event on \(streamTypeDescription)")
 switch eventCode {
 case Stream.Event.openCompleted:
 guard isInputStream == true else { break }
 /// Parse the tar stream and call the entry handler with the result.
 parse(tarStream: tarStream!)
 
 break
 
 case Stream.Event.hasBytesAvailable:
 guard isInputStream == true else { break }
 //			readerCallback?()
 
 case Stream.Event.endEncountered:
 guard isInputStream == true else { break }
 print("Tar call end handler")
 tarStream?.close()
 endHandler?()
 
 case Stream.Event.errorOccurred:
 print("Error! \(aStream.streamError?.localizedDescription)")
 
 default:
 print("We got nuffink.")
 }
	}
 
 }
 */
