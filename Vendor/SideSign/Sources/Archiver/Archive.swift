//
//  Archive.swift
//  SideSign
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import libdeflate
import CZlib

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum Archive {

    public struct Entry: Sendable, Hashable {
        public let filename: String
        public let uncompressedSize: Int64
        public let compressedSize: Int64
        public let crc: UInt32
        public let externalAttributes: UInt32
        public let compressionMethod: UInt16
        public let localHeaderOffset: UInt64

        public var isDirectory: Bool {
            return filename.hasSuffix("/") || ((externalAttributes >> 16) & 0o040000 != 0)
        }

        public var posixPermissions: UInt32 {
            let perms = (externalAttributes >> 16) & 0o777
            if perms != 0 { return perms }
            return isDirectory ? 0o755 : 0o644
        }

        public init(
            filename: String,
            uncompressedSize: Int64,
            compressedSize: Int64,
            crc: UInt32,
            externalAttributes: UInt32,
            compressionMethod: UInt16 = 0,
            localHeaderOffset: UInt64 = 0
        ) {
            self.filename = filename
            self.uncompressedSize = uncompressedSize
            self.compressedSize = compressedSize
            self.crc = crc
            self.externalAttributes = externalAttributes
            self.compressionMethod = compressionMethod
            self.localHeaderOffset = localHeaderOffset
        }
    }

    public final class Reader {
        private let fileURL: URL
        private let fileHandle: FileHandle
        private let parsedEntries: [Entry]
        private var currentIndex: Int = 0

        private init(fileURL: URL, fileHandle: FileHandle, entries: [Entry]) {
            self.fileURL = fileURL
            self.fileHandle = fileHandle
            self.parsedEntries = entries
            self.currentIndex = 0
        }

        deinit {
            try? fileHandle.close()
        }

        public static func open(at url: URL) throws -> Reader {
            verboseLog("[SideSign] Archive.Reader.open(at: \(url.path)) started")
            guard FileManager.default.fileExists(atPath: url.path) else {
                debugLog("[SideSign] Archive.Reader.open failed: file not found at \(url.path)")
                throw Archive.Error.fileNotFound(url)
            }

            guard let handle = try? FileHandle(forReadingFrom: url) else {
                throw Archive.Error.readFailed(url)
            }

            let entries = try parseCentralDirectory(handle: handle, fileURL: url)
            verboseLog("[SideSign] Archive.Reader.open succeeded with \(entries.count) entries")
            return Reader(fileURL: url, fileHandle: handle, entries: entries)
        }

        public func goToFirstFile() throws {
            verboseLog("[SideSign] Archive.Reader.goToFirstFile called")
            guard !parsedEntries.isEmpty else {
                throw Archive.Error.readFailed(fileURL)
            }
            currentIndex = 0
        }

        public func goToNextFile() -> Bool {
            let nextIndex = currentIndex + 1
            let hasNext = nextIndex < parsedEntries.count
            if hasNext {
                currentIndex = nextIndex
            }
            verboseLog("[SideSign] Archive.Reader.goToNextFile called. Has next file: \(hasNext)")
            return hasNext
        }

        public func currentFilename() throws -> String {
            guard currentIndex < parsedEntries.count else {
                throw Archive.Error.readFailed(fileURL)
            }
            let filename = parsedEntries[currentIndex].filename
            verboseLog("[SideSign] Archive.Reader.currentFilename retrieved: \(filename)")
            return filename
        }

        public func currentFileExternalAttributes() -> UInt32 {
            guard currentIndex < parsedEntries.count else { return 0 }
            return parsedEntries[currentIndex].externalAttributes
        }

        public func currentEntry() throws -> Entry {
            guard currentIndex < parsedEntries.count else {
                throw Archive.Error.readFailed(fileURL)
            }
            return parsedEntries[currentIndex]
        }

        public func entries() throws -> [Entry] {
            return parsedEntries
        }

        public func readCurrentFile() throws -> Data {
            guard currentIndex < parsedEntries.count else {
                throw Archive.Error.readFailed(fileURL)
            }
            let entry = parsedEntries[currentIndex]
            verboseLog("[SideSign] Archive.Reader.readCurrentFile started for \(entry.filename)")
            return try extractData(for: entry)
        }

        public func extractCurrentFile(to destinationURL: URL) throws {
            guard currentIndex < parsedEntries.count else {
                throw Archive.Error.readFailed(fileURL)
            }
            let entry = parsedEntries[currentIndex]
            verboseLog("[SideSign] Archive.Reader.extractCurrentFile started: \(entry.filename) -> \(destinationURL.path)")

            let fileManager = FileManager.default
            if entry.isDirectory {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                applyPermissions(entry.posixPermissions, to: destinationURL)
                verboseLog("[SideSign] Archive.Reader.extractCurrentFile created directory")
                return
            }

            let parentDir = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

            let data = try extractData(for: entry)
            try data.write(to: destinationURL, options: .atomic)
            applyPermissions(entry.posixPermissions, to: destinationURL)
            verboseLog("[SideSign] Archive.Reader.extractCurrentFile completed successfully")
        }

        private func extractData(for entry: Entry) throws -> Data {
            if entry.isDirectory || entry.uncompressedSize == 0 {
                return Data()
            }

            try fileHandle.seek(toOffset: entry.localHeaderOffset)
            guard let localHeaderData = try fileHandle.read(upToCount: 30), localHeaderData.count == 30 else {
                throw Archive.Error.readFailed(fileURL)
            }

            let magic = localHeaderData.readUInt32LE(at: 0)
            guard magic == 0x04034b50 else {
                throw Archive.Error.corruptArchive(fileURL)
            }

            let nameLen = Int(localHeaderData.readUInt16LE(at: 26))
            let extraLen = Int(localHeaderData.readUInt16LE(at: 28))
            let skipOffset = entry.localHeaderOffset + 30 + UInt64(nameLen + extraLen)

            try fileHandle.seek(toOffset: skipOffset)
            guard let rawData = try fileHandle.read(upToCount: Int(entry.compressedSize)),
                  rawData.count == Int(entry.compressedSize) else {
                throw Archive.Error.readFailed(fileURL)
            }

            if entry.compressionMethod == 0 {
                if entry.crc != 0 {
                    let computedCRC = rawData.withUnsafeBytes { rawBuf in
                        libdeflate_crc32(0, rawBuf.baseAddress, rawBuf.count)
                    }
                    guard computedCRC == entry.crc else {
                        throw Archive.Error.corruptArchive(fileURL)
                    }
                }
                return rawData
            } else if entry.compressionMethod == 8 {
                guard let decompressor = libdeflate_alloc_decompressor() else {
                    throw Archive.Error.readFailed(fileURL)
                }
                defer { libdeflate_free_decompressor(decompressor) }

                var uncompressed = Data(count: Int(entry.uncompressedSize))
                var actualOutBytes: Int = 0

                let result = uncompressed.withUnsafeMutableBytes { outBuf in
                    rawData.withUnsafeBytes { inBuf in
                        libdeflate_deflate_decompress(
                            decompressor,
                            inBuf.baseAddress,
                            inBuf.count,
                            outBuf.baseAddress,
                            outBuf.count,
                            &actualOutBytes
                        )
                    }
                }

                guard result == LIBDEFLATE_SUCCESS, actualOutBytes == Int(entry.uncompressedSize) else {
                    debugLog("[SideSign] Archive.Reader decompress failed with libdeflate result: \(result.rawValue)")
                    throw Archive.Error.corruptArchive(fileURL)
                }

                if entry.crc != 0 {
                    let computedCRC = uncompressed.withUnsafeBytes { outBuf in
                        libdeflate_crc32(0, outBuf.baseAddress, outBuf.count)
                    }
                    guard computedCRC == entry.crc else {
                        debugLog("[SideSign] Archive.Reader CRC mismatch for \(entry.filename): expected \(entry.crc), got \(computedCRC)")
                        throw Archive.Error.corruptArchive(fileURL)
                    }
                }
                return uncompressed
            } else {
                throw Archive.Error.corruptArchive(fileURL)
            }
        }

        private static func parseCentralDirectory(handle: FileHandle, fileURL: URL) throws -> [Entry] {
            let fileSize = try handle.seekToEnd()
            guard fileSize >= 22 else {
                throw Archive.Error.corruptArchive(fileURL)
            }

            let searchLen = min(fileSize, 65536 + 22)
            let searchOffset = fileSize - searchLen
            try handle.seek(toOffset: searchOffset)
            guard let searchData = try handle.read(upToCount: Int(searchLen)), !searchData.isEmpty else {
                throw Archive.Error.readFailed(fileURL)
            }

            var eocdOffsetInSearch: Int? = nil
            for i in stride(from: searchData.count - 22, through: 0, by: -1) {
                if searchData.readUInt32LE(at: i) == 0x06054b50 {
                    eocdOffsetInSearch = i
                    break
                }
            }

            guard let eocdPos = eocdOffsetInSearch else {
                throw Archive.Error.corruptArchive(fileURL)
            }

            let totalEntries = searchData.readUInt16LE(at: eocdPos + 10)
            let cdSize = UInt64(searchData.readUInt32LE(at: eocdPos + 12))
            let cdOffset = UInt64(searchData.readUInt32LE(at: eocdPos + 16))

            guard cdOffset + cdSize <= fileSize else {
                throw Archive.Error.corruptArchive(fileURL)
            }

            try handle.seek(toOffset: cdOffset)
            guard let cdData = try handle.read(upToCount: Int(cdSize)), cdData.count == Int(cdSize) else {
                throw Archive.Error.readFailed(fileURL)
            }

            var entries: [Entry] = []
            var offset = 0
            for _ in 0..<totalEntries {
                guard offset + 46 <= cdData.count else { break }
                let magic = cdData.readUInt32LE(at: offset)
                guard magic == 0x02014b50 else { break }

                let method = cdData.readUInt16LE(at: offset + 10)
                let crc = cdData.readUInt32LE(at: offset + 16)
                let compSize = Int64(cdData.readUInt32LE(at: offset + 20))
                let uncompSize = Int64(cdData.readUInt32LE(at: offset + 24))
                let nameLen = Int(cdData.readUInt16LE(at: offset + 28))
                let extraLen = Int(cdData.readUInt16LE(at: offset + 30))
                let commentLen = Int(cdData.readUInt16LE(at: offset + 32))
                let externalAttr = cdData.readUInt32LE(at: offset + 38)
                let localOffset = UInt64(cdData.readUInt32LE(at: offset + 42))

                let nameStart = offset + 46
                guard nameStart + nameLen <= cdData.count else { break }
                let nameBytes = cdData.subdata(in: nameStart..<(nameStart + nameLen))
                let filename = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)

                entries.append(Entry(
                    filename: filename,
                    uncompressedSize: uncompSize,
                    compressedSize: compSize,
                    crc: crc,
                    externalAttributes: externalAttr,
                    compressionMethod: method,
                    localHeaderOffset: localOffset
                ))

                offset = nameStart + nameLen + extraLen + commentLen
            }

            return entries
        }

        private func applyPermissions(_ permissions: UInt32, to url: URL) {
            #if !os(Windows)
            #if canImport(Darwin) || canImport(Android) || canImport(Bionic) || canImport(Glibc) || canImport(Musl)
            _ = chmod(url.path, mode_t(permissions))
            #endif
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
            #endif
        }
    }

    public final class Writer {
        private static let streamingThreshold = 64 * 1_024 * 1_024
        // Larger buffers reduce FileHandle writes and transient Data allocations on large IPAs.
        private static let streamBufferSize = 1 * 1_024 * 1_024
        private static let regularFileType: UInt32 = 0o100000
        private static let directoryFileType: UInt32 = 0o040000
        private static let symbolicLinkFileType: UInt32 = 0o120000

        private let destinationURL: URL
        private let fileHandle: FileHandle
        private var compressLevel: Int16 = 0
        private var currentOffset: UInt64 = 0
        private var centralDirectoryEntries: [CentralDirectoryRecord] = []
        private var isClosed: Bool = false

        private struct CentralDirectoryRecord {
            let filename: String
            let compressionMethod: UInt16
            let modTime: UInt16
            let modDate: UInt16
            let crc32: UInt32
            let compressedSize: UInt32
            let uncompressedSize: UInt32
            let externalAttributes: UInt32
            let localHeaderOffset: UInt64
        }

        private init(destinationURL: URL, fileHandle: FileHandle) {
            self.destinationURL = destinationURL
            self.fileHandle = fileHandle
            self.currentOffset = 0
            self.compressLevel = 0
        }

        deinit {
            if !isClosed {
                try? close()
            }
        }

        public static func create(at url: URL) throws -> Writer {
            verboseLog("[SideSign] Archive.Writer.create(at: \(url.path)) started")
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw Archive.Error.writeFailed(url)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                throw Archive.Error.writeFailed(url)
            }
            verboseLog("[SideSign] Archive.Writer.create succeeded")
            return Writer(destinationURL: url, fileHandle: handle)
        }

        public func setCompressLevel(_ level: Int16) {
            self.compressLevel = level
        }

        public func addFile(at fileURL: URL, pathInZip: String) throws {
            verboseLog("[SideSign] Archive.Writer.addFile started: \(fileURL.path) -> \(pathInZip)")
            let attributes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
            let posixPerms = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
            let modDate = (attributes[.modificationDate] as? Date) ?? Date()

            if let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
               fileSize >= Int64(Self.streamingThreshold) {
                try writeStreamingFile(
                    at: fileURL,
                    pathInZip: pathInZip,
                    permissions: posixPerms,
                    modificationDate: modDate
                )
                verboseLog("[SideSign] Archive.Writer.addFile completed with streaming writer")
                return
            }

            // mmap keeps the input file out of the app's resident heap. Small files still use
            // libdeflate's fast one-shot path; large files take the bounded-memory stream above.
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)

            try writeEntry(
                path: pathInZip,
                data: data,
                permissions: posixPerms,
                isDir: false,
                isSymlink: false,
                date: modDate
            )
            verboseLog("[SideSign] Archive.Writer.addFile completed successfully")
        }

        public func addSymbolicLink(at fileURL: URL, pathInZip: String) throws {
            let fileManager = FileManager.default
            let destination = try fileManager.destinationOfSymbolicLink(atPath: fileURL.path)
            let attributes = (try? fileManager.attributesOfItem(atPath: fileURL.path)) ?? [:]
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o777
            let modificationDate = (attributes[.modificationDate] as? Date) ?? Date()
            setCompressLevel(0)
            try writeEntry(
                path: pathInZip,
                data: Data(destination.utf8),
                permissions: permissions,
                isDir: false,
                isSymlink: true,
                date: modificationDate
            )
        }

        public func writeFile(
            path: String,
            data: Data?,
            permissions: UInt32,
            modificationDate: Date = Date()
        ) throws {
            verboseLog("[SideSign] Archive.Writer.writeFile started for internal path: '\(path)'")
            let isDir = path.hasSuffix("/") || (data == nil)
            try writeEntry(
                path: path,
                data: data ?? Data(),
                permissions: permissions,
                isDir: isDir,
                isSymlink: false,
                date: modificationDate
            )
            verboseLog("[SideSign] Archive.Writer.writeFile completed successfully")
        }

        private func writeEntry(
            path: String,
            data: Data,
            permissions: UInt32,
            isDir: Bool,
            isSymlink: Bool,
            date: Date
        ) throws {
            guard !isClosed else { throw Archive.Error.writeFailed(destinationURL) }

            let (dosDate, dosTime) = Self.dosDateTime(from: date)
            let nameData = Data(path.utf8)
            guard nameData.count <= Int(UInt16.max),
                  centralDirectoryEntries.count < Int(UInt16.max),
                  currentOffset < UInt64(UInt32.max),
                  data.count < Int(UInt32.max) else {
                throw Archive.Error.writeFailed(destinationURL)
            }
            let uncompressedSize = UInt32(data.count)

            let crc: UInt32
            if isDir || data.isEmpty {
                crc = 0
            } else {
                crc = data.withUnsafeBytes { rawBuf in
                    libdeflate_crc32(0, rawBuf.baseAddress, rawBuf.count)
                }
            }

            var method: UInt16 = 0 // Store
            var payload = data

            if !isDir && !isSymlink && !data.isEmpty && compressLevel > 0 {
                if let compressor = libdeflate_alloc_compressor(Int32(compressLevel)) {
                    defer { libdeflate_free_compressor(compressor) }
                    let maxBound = libdeflate_deflate_compress_bound(compressor, data.count)
                    var outBuf = [UInt8](repeating: 0, count: maxBound)

                    let compressedLen = data.withUnsafeBytes { inBuf in
                        libdeflate_deflate_compress(
                            compressor,
                            inBuf.baseAddress,
                            inBuf.count,
                            &outBuf,
                            outBuf.count
                        )
                    }

                    if compressedLen > 0 {
                        method = 8 // Deflate
                        payload = Data(outBuf.prefix(compressedLen))
                    }
                }
            }

            let compressedSize = UInt32(payload.count)
            let localHeaderOffset = currentOffset

            // Local File Header (30 bytes + filename)
            var localHeader = Data(count: 30)
            localHeader.writeUInt32LE(0x04034b50, at: 0)
            localHeader.writeUInt16LE(20, at: 4) // Version needed
            localHeader.writeUInt16LE(0x0800, at: 6) // UTF-8
            localHeader.writeUInt16LE(method, at: 8)
            localHeader.writeUInt16LE(dosTime, at: 10)
            localHeader.writeUInt16LE(dosDate, at: 12)
            localHeader.writeUInt32LE(crc, at: 14)
            localHeader.writeUInt32LE(compressedSize, at: 18)
            localHeader.writeUInt32LE(uncompressedSize, at: 22)
            localHeader.writeUInt16LE(UInt16(nameData.count), at: 26)
            localHeader.writeUInt16LE(0, at: 28) // Extra field length

            try fileHandle.write(contentsOf: localHeader)
            try fileHandle.write(contentsOf: nameData)
            if !payload.isEmpty {
                try fileHandle.write(contentsOf: payload)
            }

            currentOffset += UInt64(30 + nameData.count + payload.count)
            guard currentOffset < UInt64(UInt32.max) else {
                throw Archive.Error.writeFailed(destinationURL)
            }

            let externalAttr: UInt32
            if isSymlink {
                externalAttr = (Self.symbolicLinkFileType | (permissions & 0o777)) << 16
            } else if isDir {
                externalAttr = (Self.directoryFileType | (permissions & 0o777)) << 16
            } else {
                externalAttr = (Self.regularFileType | (permissions & 0o777)) << 16
            }

            centralDirectoryEntries.append(CentralDirectoryRecord(
                filename: path,
                compressionMethod: method,
                modTime: dosTime,
                modDate: dosDate,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                externalAttributes: externalAttr,
                localHeaderOffset: localHeaderOffset
            ))
        }

        private func writeStreamingFile(
            at fileURL: URL,
            pathInZip: String,
            permissions: UInt32,
            modificationDate: Date
        ) throws {
            guard !isClosed,
                  centralDirectoryEntries.count < Int(UInt16.max) else {
                throw Archive.Error.writeFailed(destinationURL)
            }

            let fileManager = FileManager.default
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let expectedSize = (attributes[.size] as? NSNumber)?.int64Value,
                  expectedSize >= 0,
                  expectedSize < Int64(UInt32.max) else {
                throw Archive.Error.writeFailed(fileURL)
            }

            let nameData = Data(pathInZip.utf8)
            guard nameData.count <= Int(UInt16.max),
                  currentOffset < UInt64(UInt32.max) else {
                throw Archive.Error.writeFailed(destinationURL)
            }

            let (dosDate, dosTime) = Self.dosDateTime(from: modificationDate)
            let method: UInt16 = compressLevel > 0 ? 8 : 0
            let localHeaderOffset = currentOffset
            let localHeader = Self.localFileHeader(
                filename: nameData,
                method: method,
                dosTime: dosTime,
                dosDate: dosDate,
                crc32: 0,
                compressedSize: 0,
                uncompressedSize: UInt32(expectedSize)
            )

            try fileHandle.write(contentsOf: localHeader)
            try fileHandle.write(contentsOf: nameData)
            currentOffset += UInt64(localHeader.count + nameData.count)

            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }

            var checksum: UInt32 = 0
            var bytesRead: Int64 = 0
            var compressedSize: UInt64 = 0

            if method == 8 {
                let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.streamBufferSize)
                defer { outputBuffer.deallocate() }

                var stream = z_stream()
                let zlibLevel = Int32(min(max(Int(compressLevel), Int(Z_NO_COMPRESSION)), Int(Z_BEST_COMPRESSION)))
                let initStatus = ZLIB_VERSION.withCString { version in
                    deflateInit2_(
                        &stream,
                        zlibLevel,
                        Z_DEFLATED,
                        -MAX_WBITS,
                        8,
                        Z_DEFAULT_STRATEGY,
                        version,
                        Int32(MemoryLayout<z_stream>.size)
                    )
                }
                guard initStatus == Z_OK else {
                    throw Archive.Error.writeFailed(fileURL)
                }
                defer { _ = deflateEnd(&stream) }

                var reachedEnd = false
                while !reachedEnd {
                    let chunk = try input.read(upToCount: Self.streamBufferSize) ?? Data()
                    let isFinalChunk = bytesRead + Int64(chunk.count) == expectedSize
                    if chunk.isEmpty && expectedSize != 0 {
                        throw Archive.Error.readFailed(fileURL)
                    }
                    if !chunk.isEmpty {
                        checksum = chunk.withUnsafeBytes { rawBuffer in
                            libdeflate_crc32(
                                checksum,
                                rawBuffer.baseAddress,
                                rawBuffer.count
                            )
                        }
                    }
                    bytesRead += Int64(chunk.count)

                    try chunk.withUnsafeBytes { rawBuffer in
                        if let baseAddress = rawBuffer.baseAddress {
                            stream.next_in = UnsafeMutablePointer(
                                mutating: baseAddress.assumingMemoryBound(to: Bytef.self)
                            )
                        } else {
                            stream.next_in = nil
                        }
                        stream.avail_in = uInt(rawBuffer.count)
                        let flush = isFinalChunk ? Z_FINISH : Z_NO_FLUSH

                        while true {
                            stream.next_out = outputBuffer
                            stream.avail_out = uInt(Self.streamBufferSize)
                            let status = deflate(&stream, flush)
                            guard status == Z_OK || status == Z_STREAM_END else {
                                throw Archive.Error.writeFailed(fileURL)
                            }

                            let produced = Self.streamBufferSize - Int(stream.avail_out)
                            if produced > 0 {
                                try fileHandle.write(contentsOf: Data(bytes: outputBuffer, count: produced))
                                compressedSize += UInt64(produced)
                                currentOffset += UInt64(produced)
                            }

                            if status == Z_STREAM_END {
                                reachedEnd = true
                                break
                            }
                            if stream.avail_in == 0 && stream.avail_out > 0 && !isFinalChunk {
                                break
                            }
                            if produced == 0 && stream.avail_in == 0 && isFinalChunk {
                                throw Archive.Error.writeFailed(fileURL)
                            }
                        }
                    }

                    guard bytesRead <= expectedSize else {
                        throw Archive.Error.readFailed(fileURL)
                    }
                }
            } else {
                while true {
                    let chunk = try input.read(upToCount: Self.streamBufferSize) ?? Data()
                    if chunk.isEmpty { break }
                    bytesRead += Int64(chunk.count)
                    guard bytesRead <= expectedSize else {
                        throw Archive.Error.readFailed(fileURL)
                    }
                    checksum = chunk.withUnsafeBytes { rawBuffer in
                        libdeflate_crc32(checksum, rawBuffer.baseAddress, rawBuffer.count)
                    }
                    try fileHandle.write(contentsOf: chunk)
                    compressedSize += UInt64(chunk.count)
                    currentOffset += UInt64(chunk.count)
                }
            }

            let trailingBytes = try input.read(upToCount: 1) ?? Data()
            guard bytesRead == expectedSize,
                  trailingBytes.isEmpty,
                  compressedSize < UInt64(UInt32.max),
                  currentOffset < UInt64(UInt32.max) else {
                throw Archive.Error.readFailed(fileURL)
            }

            let finalHeader = Self.localFileHeader(
                filename: nameData,
                method: method,
                dosTime: dosTime,
                dosDate: dosDate,
                crc32: checksum,
                compressedSize: UInt32(compressedSize),
                uncompressedSize: UInt32(expectedSize)
            )
            let endOffset = currentOffset
            try fileHandle.seek(toOffset: localHeaderOffset)
            try fileHandle.write(contentsOf: finalHeader)
            try fileHandle.seek(toOffset: endOffset)

            let externalAttributes = (Self.regularFileType | (permissions & 0o777)) << 16
            centralDirectoryEntries.append(CentralDirectoryRecord(
                filename: pathInZip,
                compressionMethod: method,
                modTime: dosTime,
                modDate: dosDate,
                crc32: checksum,
                compressedSize: UInt32(compressedSize),
                uncompressedSize: UInt32(expectedSize),
                externalAttributes: externalAttributes,
                localHeaderOffset: localHeaderOffset
            ))
        }

        private static func localFileHeader(
            filename: Data,
            method: UInt16,
            dosTime: UInt16,
            dosDate: UInt16,
            crc32: UInt32,
            compressedSize: UInt32,
            uncompressedSize: UInt32
        ) -> Data {
            var header = Data(count: 30)
            header.writeUInt32LE(0x04034b50, at: 0)
            header.writeUInt16LE(20, at: 4)
            header.writeUInt16LE(0x0800, at: 6)
            header.writeUInt16LE(method, at: 8)
            header.writeUInt16LE(dosTime, at: 10)
            header.writeUInt16LE(dosDate, at: 12)
            header.writeUInt32LE(crc32, at: 14)
            header.writeUInt32LE(compressedSize, at: 18)
            header.writeUInt32LE(uncompressedSize, at: 22)
            header.writeUInt16LE(UInt16(filename.count), at: 26)
            header.writeUInt16LE(0, at: 28)
            return header
        }

        public func close() throws {
            guard !isClosed else { return }

            let centralDirectorySize = centralDirectoryEntries.reduce(UInt64(0)) { size, entry in
                size + 46 + UInt64(entry.filename.utf8.count)
            }
            let (archiveSizeWithDirectory, sizeOverflow) = currentOffset
                .addingReportingOverflow(centralDirectorySize + 22)
            guard centralDirectoryEntries.count < Int(UInt16.max),
                  currentOffset < UInt64(UInt32.max),
                  centralDirectorySize < UInt64(UInt32.max),
                  !sizeOverflow,
                  archiveSizeWithDirectory < UInt64(UInt32.max) else {
                throw Archive.Error.writeFailed(destinationURL)
            }

            isClosed = true

            let cdStartOffset = currentOffset
            for record in centralDirectoryEntries {
                let nameData = Data(record.filename.utf8)

                var cdHeader = Data(count: 46)
                cdHeader.writeUInt32LE(0x02014b50, at: 0)
                cdHeader.writeUInt16LE(0x031e, at: 4) // Version made by: UNIX 3.0
                cdHeader.writeUInt16LE(20, at: 6) // Version needed: 2.0
                cdHeader.writeUInt16LE(0x0800, at: 8) // UTF-8
                cdHeader.writeUInt16LE(record.compressionMethod, at: 10)
                cdHeader.writeUInt16LE(record.modTime, at: 12)
                cdHeader.writeUInt16LE(record.modDate, at: 14)
                cdHeader.writeUInt32LE(record.crc32, at: 16)
                cdHeader.writeUInt32LE(record.compressedSize, at: 20)
                cdHeader.writeUInt32LE(record.uncompressedSize, at: 24)
                cdHeader.writeUInt16LE(UInt16(nameData.count), at: 28)
                cdHeader.writeUInt16LE(0, at: 30) // Extra field length
                cdHeader.writeUInt16LE(0, at: 32) // File comment length
                cdHeader.writeUInt16LE(0, at: 34) // Disk number start
                cdHeader.writeUInt16LE(0, at: 36) // Internal attributes
                cdHeader.writeUInt32LE(record.externalAttributes, at: 38)
                cdHeader.writeUInt32LE(UInt32(record.localHeaderOffset), at: 42)

                try fileHandle.write(contentsOf: cdHeader)
                try fileHandle.write(contentsOf: nameData)
                currentOffset += UInt64(46 + nameData.count)
            }

            let cdSize = UInt32(currentOffset - cdStartOffset)
            let totalRecords = UInt16(centralDirectoryEntries.count)

            // End of Central Directory (EOCD: 22 bytes)
            var eocd = Data(count: 22)
            eocd.writeUInt32LE(0x06054b50, at: 0)
            eocd.writeUInt16LE(0, at: 4) // Disk number
            eocd.writeUInt16LE(0, at: 6) // Disk with CD
            eocd.writeUInt16LE(totalRecords, at: 8) // Entries this disk
            eocd.writeUInt16LE(totalRecords, at: 10) // Total entries
            eocd.writeUInt32LE(cdSize, at: 12) // CD size
            eocd.writeUInt32LE(UInt32(cdStartOffset), at: 16) // CD start offset
            eocd.writeUInt16LE(0, at: 20) // Comment length

            try fileHandle.write(contentsOf: eocd)
            try fileHandle.synchronize()
            try fileHandle.close()
            verboseLog("[SideSign] Archive.Writer finalized with \(totalRecords) entries")
        }

        private static func dosDateTime(from date: Date) -> (UInt16, UInt16) {
            let calendar = Calendar(identifier: .gregorian)
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let year = max(1980, comps.year ?? 1980) - 1980
            let month = comps.month ?? 1
            let day = comps.day ?? 1
            let hour = comps.hour ?? 0
            let minute = comps.minute ?? 0
            let second = comps.second ?? 0

            let dosDate = UInt16(((year & 0x7F) << 9) | ((month & 0x0F) << 5) | (day & 0x1F))
            let dosTime = UInt16(((hour & 0x1F) << 11) | ((minute & 0x3F) << 5) | ((second / 2) & 0x1F))
            return (dosDate, dosTime)
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case fileNotFound(URL)
        case corruptArchive(URL)
        case readFailed(URL)
        case writeFailed(URL)
        case missingAppBundle(URL)

        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let url):
                return "File not found: \(url.lastPathComponent)"
            case .corruptArchive(let url):
                return "Archive appears to be corrupt: \(url.lastPathComponent)"
            case .readFailed(let url):
                return "Failed to read archive: \(url.lastPathComponent)"
            case .writeFailed(let url):
                return "Failed to write archive: \(url.lastPathComponent)"
            case .missingAppBundle(let url):
                return "No .app bundle found inside \(url.lastPathComponent)"
            }
        }
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        let idx = self.startIndex + offset
        let b0 = UInt16(self[idx])
        let b1 = UInt16(self[idx + 1])
        return b0 | (b1 << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        let idx = self.startIndex + offset
        let b0 = UInt32(self[idx])
        let b1 = UInt32(self[idx + 1])
        let b2 = UInt32(self[idx + 2])
        let b3 = UInt32(self[idx + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { valBuf in
            let idx = self.startIndex + offset
            self.replaceSubrange(idx..<(idx + 2), with: valBuf)
        }
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { valBuf in
            let idx = self.startIndex + offset
            self.replaceSubrange(idx..<(idx + 4), with: valBuf)
        }
    }
}
