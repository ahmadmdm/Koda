import AVFoundation
import CoreMedia
import Foundation

/// Writes an offline HLS download (`.movpkg`) out as one `.mp4`, without re-encoding.
///
/// AVFoundation plays a `.movpkg` but neither exports nor reads it (`AVAssetExportSession` and
/// `AVAssetReader` refuse HLS). Koda's downloads are YouTube's H.264 variants: MPEG-TS video
/// segments and packed-AAC audio segments (an ID3 timestamp, then ADTS frames), each kept as a file
/// in the package with its order in the stream's `StreamInfoBoot.xml`. This reads those segments,
/// takes the H.264 access units and AAC frames out with their timestamps, and passes them to
/// `AVAssetWriter` as they are.
nonisolated enum HLSPackageRemuxer {
    enum RemuxError: LocalizedError {
        case unsupported
        case noVideo
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .unsupported, .noVideo:
                String(localized: "Only downloads in H.264 (up to 1080p) can be saved as a file. Download the video again in 1080p or lower.")
            case .writer(let message): message
            }
        }
    }

    // MARK: Package

    struct Segment: Equatable { var path: String; var offset: Int; var length: Int; var sequence: Int }

    struct Stream {
        var directory: URL
        var isAudio: Bool
        var segments: [Segment]
    }

    /// The streams of a package, each with its segments in order.
    static func streams(in package: URL) throws -> [Stream] {
        let dirs = try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: [.isDirectoryKey])
        return dirs.compactMap { dir -> Stream? in
            guard let xml = try? String(contentsOf: dir.appendingPathComponent("StreamInfoBoot.xml"), encoding: .utf8) else { return nil }
            let segments = parseSegments(xml)
            guard !segments.isEmpty else { return nil }
            return Stream(directory: dir, isAudio: xml.contains("<MediaType type=\"soun\""), segments: segments)
        }
    }

    /// The `<SEG … PATH="…" SeqNum="…" Off="…" Len="…">` entries of a `StreamInfoBoot.xml`, in order.
    static func parseSegments(_ xml: String) -> [Segment] {
        func attribute(_ name: String, in tag: Substring) -> String? {
            guard let start = tag.range(of: " \(name)=\"") else { return nil }
            let rest = tag[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        var segments: [Segment] = []
        var search = xml[...]
        while let open = search.range(of: "<SEG ") {
            guard let close = search[open.upperBound...].firstIndex(of: ">") else { break }
            let tag = search[open.lowerBound..<close]
            if let path = attribute("PATH", in: tag) {
                segments.append(Segment(path: path.decodingHTMLEntities,
                                        offset: attribute("Off", in: tag).flatMap { Int($0) } ?? 0,
                                        length: attribute("Len", in: tag).flatMap { Int($0) } ?? 0,
                                        sequence: attribute("SeqNum", in: tag).flatMap { Int($0) } ?? segments.count))
            }
            search = search[close...]
        }
        return segments.sorted { $0.sequence < $1.sequence }
    }

    private static func read(_ segment: Segment, in stream: Stream) throws -> Data {
        let url = stream.directory.appendingPathComponent(segment.path)
        guard segment.offset > 0 || segment.length > 0 else { return try Data(contentsOf: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(segment.offset))
        return try handle.read(upToCount: segment.length) ?? Data()
    }

    // MARK: Remux

    /// Writes `package` to `output` (an `.mp4`). `progress` gets 0...1.
    static func remux(_ package: URL, to output: URL, progress: @Sendable (Double) -> Void) async throws {
        let all = try streams(in: package)
        guard let video = all.first(where: { !$0.isAudio }) else { throw RemuxError.noVideo }
        let audio = all.first(where: \.isAudio)
        // Only MPEG-TS video can be taken apart here (VP9 variants are fragmented MP4).
        guard let first = video.segments.first, try read(first, in: video).first == 0x47 else { throw RemuxError.unsupported }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var base: Int64?
        var demuxer = TSDemuxer()
        var lastVideoDuration: Int64 = 3000
        var audioFormat: CMAudioFormatDescription?
        var nextAudioPTS: Int64?

        func start() throws {
            guard writer.status == .unknown else { return }
            guard writer.startWriting() else { throw RemuxError.writer(writer.error?.localizedDescription ?? "") }
            writer.startSession(atSourceTime: .zero)
        }

        // Buffers read but not yet written. Each input takes what it can: AVAssetWriter holds one
        // back when it runs ahead of the other, so a strict one-by-one order can deadlock.
        var videoQueue: [(time: Int64, buffer: CMSampleBuffer)] = []
        var audioQueue: [(time: Int64, buffer: CMSampleBuffer)] = []
        var next = 0
        let count = video.segments.count
        var videoFinished = false
        var audioFinished = false

        /// Reads the next segment into the queues.
        func load() throws {
            let i = next
            next += 1
            let ts = try read(video.segments[i], in: video)
            let units = demuxer.feed(ts, flush: i == count - 1)
            // Audio: the packed-AAC segment of the same index, else AAC carried in the TS itself.
            var frames: [ADTSFrame] = []
            if let audio {
                if i < audio.segments.count { frames = parsePackedAudio(try read(audio.segments[i], in: audio), startPTS: &nextAudioPTS) }
            } else {
                frames = units.audio
            }
            guard base != nil || !units.video.isEmpty else { return }
            if base == nil { base = min(units.video.first.map(\.dts) ?? .max, frames.first?.pts ?? .max) }
            let zero = base ?? 0

            if videoInput == nil, let format = units.videoFormat {
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else { throw RemuxError.writer("video") }
                writer.add(input)
                videoInput = input
            }
            if audioInput == nil, writer.status == .unknown, let header = frames.first {
                audioFormat = try header.formatDescription()
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) { writer.add(input); audioInput = input }
            }
            guard videoInput != nil, let format = units.videoFormat else { return }
            try start()

            for (j, unit) in units.video.enumerated() {
                let following = j + 1 < units.video.count ? units.video[j + 1].dts : nil
                let duration = following.map { $0 - unit.dts } ?? lastVideoDuration
                if duration > 0 { lastVideoDuration = duration }
                if let buffer = try unit.sampleBuffer(format: format, base: zero, duration: duration) {
                    videoQueue.append((unit.dts - zero, buffer))
                }
            }
            if let audioFormat, audioInput != nil {
                let kept = frames.filter { $0.pts >= zero }
                for first in stride(from: 0, to: kept.count, by: 16) {
                    let group = Array(kept[first..<min(first + 16, kept.count)])
                    if let buffer = try ADTSFrame.sampleBuffer(group, format: audioFormat, base: zero) {
                        audioQueue.append((group[0].pts - zero, buffer))
                    }
                }
            }
        }

        do {
            while true {
                try Task.checkCancellation()
                if writer.status == .failed { throw RemuxError.writer(writer.error?.localizedDescription ?? "") }
                if next < count, videoQueue.isEmpty || (audioInput != nil && audioQueue.isEmpty) {
                    try load()
                    progress(Double(next) / Double(count))
                    continue
                }
                if videoQueue.isEmpty, audioQueue.isEmpty { break }
                // A track with nothing more to come is finished, or the writer keeps waiting for it
                // before it takes the rest of the other one.
                if next == count {
                    if videoQueue.isEmpty, !videoFinished { videoInput?.markAsFinished(); videoFinished = true }
                    if audioQueue.isEmpty, !audioFinished { audioInput?.markAsFinished(); audioFinished = true }
                }
                // The earlier of the two first, else whichever input is ready.
                let videoFirst = audioQueue.isEmpty || (!videoQueue.isEmpty && videoQueue[0].time <= audioQueue[0].time)
                var appended = false
                for isVideo in videoFirst ? [true, false] : [false, true] {
                    guard let input = isVideo ? videoInput : audioInput, input.isReadyForMoreMediaData else { continue }
                    if isVideo, !videoQueue.isEmpty {
                        guard input.append(videoQueue.removeFirst().buffer) else { throw RemuxError.writer(writer.error?.localizedDescription ?? "") }
                        appended = true
                    } else if !isVideo, !audioQueue.isEmpty {
                        guard input.append(audioQueue.removeFirst().buffer) else { throw RemuxError.writer(writer.error?.localizedDescription ?? "") }
                        appended = true
                    }
                    if appended { break }
                }
                if !appended { try await Task.sleep(for: .milliseconds(5)) }
            }
            guard writer.status == .writing else { throw RemuxError.noVideo }
            if !videoFinished { videoInput?.markAsFinished() }
            if !audioFinished { audioInput?.markAsFinished() }
            await writer.finishWriting()
            if writer.status != .completed { throw RemuxError.writer(writer.error?.localizedDescription ?? "") }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // MARK: Packed audio

    /// A packed-audio segment: an ID3 tag whose PRIV frame holds the 90 kHz timestamp, then ADTS
    /// frames. A segment without a timestamp continues from the previous one.
    static func parsePackedAudio(_ data: Data, startPTS: inout Int64?) -> [ADTSFrame] {
        let bytes = [UInt8](data)
        var offset = 0
        var pts = startPTS
        while offset + 10 <= bytes.count, bytes[offset] == 0x49, bytes[offset + 1] == 0x44, bytes[offset + 2] == 0x33 {
            let size = Int(bytes[offset + 6] & 0x7F) << 21 | Int(bytes[offset + 7] & 0x7F) << 14
                | Int(bytes[offset + 8] & 0x7F) << 7 | Int(bytes[offset + 9] & 0x7F)
            let tag = bytes[offset..<min(offset + 10 + size, bytes.count)]
            if let stamp = id3Timestamp(Array(tag)) { pts = stamp }
            offset += 10 + size
        }
        var frames = ADTSFrame.parse(bytes, from: offset, pts: pts ?? 0)
        if pts == nil { frames = [] }
        if let last = frames.last { startPTS = last.pts + last.duration }
        return frames
    }

    /// `com.apple.streaming.transportStreamTimestamp`: 8 bytes, of which the low 33 bits count.
    static func id3Timestamp(_ tag: [UInt8]) -> Int64? {
        let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8) + [0]
        guard tag.count >= owner.count + 8 else { return nil }
        for i in 0...(tag.count - owner.count - 8) where tag[i] == owner[0] && Array(tag[i..<(i + owner.count)]) == owner {
            let start = i + owner.count
            let value = tag[start..<(start + 8)].reduce(Int64(0)) { $0 << 8 | Int64($1) }
            return value & 0x1_FFFF_FFFF
        }
        return nil
    }
}

// MARK: AAC

nonisolated struct ADTSFrame {
    var objectType: Int
    var frequencyIndex: Int
    var channels: Int
    var payload: Data
    /// 90 kHz.
    var pts: Int64

    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    var sampleRate: Int { frequencyIndex < Self.sampleRates.count ? Self.sampleRates[frequencyIndex] : 44100 }
    /// One frame is 1024 samples, in 90 kHz ticks.
    var duration: Int64 { Int64(1024 * 90000 / sampleRate) }

    /// The ADTS frames in `bytes` from `start`, the first at `pts`.
    static func parse(_ bytes: [UInt8], from start: Int, pts: Int64) -> [ADTSFrame] {
        var frames: [ADTSFrame] = []
        var i = start
        var time = pts
        while i + 7 <= bytes.count {
            guard bytes[i] == 0xFF, bytes[i + 1] & 0xF0 == 0xF0 else { i += 1; continue }
            let protectionAbsent = bytes[i + 1] & 1 == 1
            let header = protectionAbsent ? 7 : 9
            let length = Int(bytes[i + 3] & 0x03) << 11 | Int(bytes[i + 4]) << 3 | Int(bytes[i + 5] >> 5)
            guard length > header, i + length <= bytes.count else { break }
            var frame = ADTSFrame(objectType: Int(bytes[i + 2] >> 6) + 1, frequencyIndex: Int(bytes[i + 2] >> 2 & 0x0F),
                                  channels: Int(bytes[i + 2] & 1) << 2 | Int(bytes[i + 3] >> 6),
                                  payload: Data(bytes[(i + header)..<(i + length)]), pts: time)
            if frame.channels == 0 { frame.channels = 2 }
            time += frame.duration
            frames.append(frame)
            i += length
        }
        return frames
    }

    /// The AudioSpecificConfig: object type, frequency index, channel configuration.
    var audioSpecificConfig: [UInt8] {
        let value = objectType << 11 | frequencyIndex << 7 | channels << 3
        return [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    /// The magic cookie of MPEG-4 AAC: an ES_Descriptor around the AudioSpecificConfig, which the
    /// writer stores as the `esds` box (the bare AudioSpecificConfig gives a track nothing reads).
    var esdsCookie: [UInt8] {
        let decoderSpecific: [UInt8] = [0x05, UInt8(audioSpecificConfig.count)] + audioSpecificConfig
        let decoderConfig: [UInt8] = [0x04, UInt8(13 + decoderSpecific.count), 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            + decoderSpecific
        let sl: [UInt8] = [0x06, 0x01, 0x02]
        return [0x03, UInt8(3 + decoderConfig.count + sl.count), 0, 0, 0] + decoderConfig + sl
    }

    func formatDescription() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
                                               mBitsPerChannel: 0, mReserved: 0)
        let cookie = esdsCookie
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: raw.count, magicCookie: raw.baseAddress,
                                           extensions: nil, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw HLSPackageRemuxer.RemuxError.writer("audio format \(status)") }
        return format
    }

    /// Several frames as one sample buffer, timed from the first.
    static func sampleBuffer(_ frames: [ADTSFrame], format: CMAudioFormatDescription, base: Int64) throws -> CMSampleBuffer? {
        guard let first = frames.first else { return nil }
        var data = Data()
        var descriptions: [AudioStreamPacketDescription] = []
        for f in frames {
            descriptions.append(AudioStreamPacketDescription(mStartOffset: Int64(data.count), mVariableFramesInPacket: 0,
                                                             mDataByteSize: UInt32(f.payload.count)))
            data.append(f.payload)
        }
        let block = try blockBuffer(data)
        var buffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames.count,
            presentationTimeStamp: CMTime(value: first.pts - base, timescale: 90000),
            packetDescriptions: descriptions, sampleBufferOut: &buffer)
        guard status == noErr else { throw HLSPackageRemuxer.RemuxError.writer("audio sample \(status)") }
        return buffer
    }
}

nonisolated func blockBuffer(_ data: Data) throws -> CMBlockBuffer {
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                    offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
    guard status == noErr, let block else { throw HLSPackageRemuxer.RemuxError.writer("block \(status)") }
    status = data.withUnsafeBytes { raw in
        CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
    }
    guard status == noErr else { throw HLSPackageRemuxer.RemuxError.writer("block \(status)") }
    return block
}

// MARK: MPEG-TS

/// One H.264 access unit, length-prefixed (AVCC), with its 90 kHz timestamps.
nonisolated struct H264AccessUnit {
    var data: Data
    var pts: Int64
    var dts: Int64
    var isKeyframe: Bool

    func sampleBuffer(format: CMVideoFormatDescription, base: Int64, duration: Int64) throws -> CMSampleBuffer? {
        guard !data.isEmpty else { return nil }
        let block = try blockBuffer(data)
        var timing = CMSampleTimingInfo(duration: CMTime(value: max(duration, 1), timescale: 90000),
                                        presentationTimeStamp: CMTime(value: pts - base, timescale: 90000),
                                        decodeTimeStamp: CMTime(value: dts - base, timescale: 90000))
        var size = data.count
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                               sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw HLSPackageRemuxer.RemuxError.writer("video sample \(status)") }
        if !isKeyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return buffer
    }
}

/// Takes H.264 (stream type 0x1B) and ADTS AAC (0x0F) out of MPEG-TS packets, across segments.
nonisolated struct TSDemuxer {
    struct Output {
        var video: [H264AccessUnit] = []
        var audio: [ADTSFrame] = []
        var videoFormat: CMVideoFormatDescription?
    }

    private var pmtPID: Int?
    private var videoPID: Int?
    private var audioPID: Int?
    private var pending: [Int: (data: [UInt8], pts: Int64?, dts: Int64?)] = [:]
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private(set) var format: CMVideoFormatDescription?

    /// The access units and frames completed by `data`; `flush` ends the stream.
    mutating func feed(_ data: Data, flush: Bool) -> Output {
        var out = Output()
        let bytes = [UInt8](data)
        var i = 0
        while i + 188 <= bytes.count {
            guard bytes[i] == 0x47 else { i += 1; continue }
            packet(bytes[i..<(i + 188)], into: &out)
            i += 188
        }
        if flush {
            for pid in Array(pending.keys) { finish(pid, into: &out) }
        }
        out.videoFormat = format
        return out
    }

    private mutating func packet(_ p: ArraySlice<UInt8>, into out: inout Output) {
        let s = p.startIndex
        let pid = Int(p[s + 1] & 0x1F) << 8 | Int(p[s + 2])
        let start = p[s + 1] & 0x40 != 0
        let control = (p[s + 3] >> 4) & 3
        var offset = s + 4
        if control == 2 || control == 3 { offset += 1 + Int(p[s + 4]) }
        guard control & 1 == 1, offset < p.endIndex else { return }
        let payload = p[offset...]

        if pid == 0 {
            // PAT: the first program's PMT.
            let t = payload.startIndex + 1 + Int(payload.first ?? 0)
            if t + 12 <= payload.endIndex { pmtPID = Int(payload[t + 10] & 0x1F) << 8 | Int(payload[t + 11]) }
            return
        }
        if pid == pmtPID {
            let t = payload.startIndex + 1 + Int(payload.first ?? 0)
            guard t + 12 <= payload.endIndex else { return }
            let sectionLength = Int(payload[t + 1] & 0x0F) << 8 | Int(payload[t + 2])
            let infoLength = Int(payload[t + 10] & 0x0F) << 8 | Int(payload[t + 11])
            var e = t + 12 + infoLength
            let end = min(t + 3 + sectionLength - 4, payload.endIndex)
            while e + 5 <= end {
                let type = payload[e]
                let epid = Int(payload[e + 1] & 0x1F) << 8 | Int(payload[e + 2])
                if type == 0x1B, videoPID == nil { videoPID = epid }
                if type == 0x0F, audioPID == nil { audioPID = epid }
                e += 5 + (Int(payload[e + 3] & 0x0F) << 8 | Int(payload[e + 4]))
            }
            return
        }
        guard pid == videoPID || pid == audioPID else { return }
        if start {
            finish(pid, into: &out)
            // PES header: start code, stream id, length, flags, header length, PTS/DTS.
            let b = payload.startIndex
            guard payload.count >= 9, payload[b] == 0, payload[b + 1] == 0, payload[b + 2] == 1 else { return }
            let flags = payload[b + 7]
            let headerLength = Int(payload[b + 8])
            var pts: Int64?
            var dts: Int64?
            if flags & 0x80 != 0, payload.count >= 14 { pts = Self.timestamp(payload[(b + 9)..<(b + 14)]) }
            if flags & 0x40 != 0, payload.count >= 19 { dts = Self.timestamp(payload[(b + 14)..<(b + 19)]) }
            let dataStart = b + 9 + headerLength
            pending[pid] = (dataStart < payload.endIndex ? Array(payload[dataStart...]) : [], pts, dts ?? pts)
        } else if pending[pid] != nil {
            pending[pid]!.data.append(contentsOf: payload)
        }
    }

    static func timestamp(_ b: ArraySlice<UInt8>) -> Int64 {
        let s = b.startIndex
        return Int64(b[s] >> 1 & 0x07) << 30 | Int64(b[s + 1]) << 22 | Int64(b[s + 2] >> 1) << 15
            | Int64(b[s + 3]) << 7 | Int64(b[s + 4] >> 1)
    }

    private mutating func finish(_ pid: Int, into out: inout Output) {
        guard let pes = pending.removeValue(forKey: pid), let pts = pes.pts else { return }
        if pid == audioPID {
            out.audio += ADTSFrame.parse(pes.data, from: 0, pts: pts)
            return
        }
        var avcc = Data()
        var keyframe = false
        for nal in Self.nalUnits(pes.data) {
            guard let header = nal.first else { continue }
            switch header & 0x1F {
            case 7: sps = Array(nal); continue
            case 8: pps = Array(nal); continue
            case 9: continue // access unit delimiter
            case 5: keyframe = true
            default: break
            }
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: nal)
        }
        if format == nil, let sps, let pps { format = Self.makeFormat(sps: sps, pps: pps) }
        guard !avcc.isEmpty, format != nil else { return }
        out.video.append(H264AccessUnit(data: avcc, pts: pts, dts: pes.dts ?? pts, isKeyframe: keyframe))
    }

    /// The NAL units of an Annex B byte stream (split at 00 00 01 and 00 00 00 01).
    static func nalUnits(_ b: [UInt8]) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var starts: [(code: Int, data: Int)] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                starts.append((i > 0 && b[i - 1] == 0 ? i - 1 : i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].code : b.count
            if s.data < end { units.append(b[s.data..<end]) }
        }
        return units
    }

    private static func makeFormat(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }
}
