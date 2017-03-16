//
//  TarHeader.swift
//  TarStream
//
//  Created by teo on 25/10/2016.
//  Copyright © 2016 Matteo Sartori. All rights reserved.
//

import Foundation

public struct TarHeader {
    
    public enum Field : Int {
        case fileName
        case fileMode
        case ownerId
        case groupId
        case fileByteSize
        case fileModTime
        case headerChecksum
        case fileType
        case linkedFileName

        /// ustar extension
        case magic
        case version
        case uName
        case gName
        case devMajor
        case devMinor
        case prefix
    }
    
    public static let byteSize = 512
    
    /// Offset and size (in bytes) of tar header fields.
    static let offsets = [(0, 100), (100, 8), (108, 8), (116, 8), (124, 12), (136, 12), (148, 8), (156, 1), (157, 100), (257, 6), (263, 2), (265, 32), (297, 32), (329, 8), (337, 8), (345, 155)]
    
    /* Types used in the fileType field. */
    public enum FileTypes : Int {
        case regular            = 0
        case link               = 1
        case symbolicLink       = 2
        case characterSpecial   = 3
        case blockSpecial       = 4
        case directory          = 5
        case fifo               = 6
        case contiguousFile     = 7
        
        case paxHeader          = 72
        
        static func typeFor(flag: Int) -> FileTypes? {
            switch flag {
            case 0: return .regular
            case 1: return .link
            case 2: return .symbolicLink
            case 3: return .characterSpecial
            case 4: return .blockSpecial
            case 5: return .directory
            case 6: return .fifo
            case 7: return .contiguousFile
                
            case 72: return .paxHeader
                
            default: return nil
            }
        }
        
    }
    
    enum Modes : String {
        case tsuid   = "04000"
        case tsgid   = "02000"
        case tsvtx   = "01000"
        
        case turead  = "00400"
        case tuwrite = "00200"
        case tuexec  = "00100"
        
        case tgread  = "00040"
        case tgwrite = "00020"
        case tgexec  = "00010"
        
        case toread  = "00004"
        case towrite = "00002"
        case toexec  = "00001"
    }
    
    public let fileName: String
    public let fileMode: String
    public let ownerID: String
    public let groupID: String
    public let fileByteSize: String
    public let fileModTime: String
    public let headerChecksum: String
    public let fileType: String         /// The type of the file
    public let linkedFileName: String
    
    // UStar Header extension
    public let magic: String        /// anything but NUL
    public let version: String
    public let uName: String
    public let gName: String
    public let devMajor: String
    public let devMinor: String
    public let prefix: String
    
    
    init(fileName: String,
         fileMode: String,
         ownerID: String,
         groupID: String,
         fileByteSize: String,
         fileModTime: String,
         headerChecksum: String,
         fileType: String,
         linkedFileName: String,
         magic: String = "42",
         version: String = "",
         uName: String = "",
         gName: String = "",
         devMajor: String = "", 
         devMinor: String = "",
         prefix: String = "") {
        
        self.fileName = fileName
        self.fileMode = fileMode
        self.ownerID = ownerID
        self.groupID = groupID
        self.fileByteSize = fileByteSize
        self.fileModTime = fileModTime
        self.headerChecksum = headerChecksum
        self.fileType = fileType
        self.linkedFileName = linkedFileName
        self.magic = magic
        self.version = version
        self.uName = uName
        self.gName = gName
        self.devMajor = devMajor
        self.devMinor = devMinor
        self.prefix = prefix
    }
}
