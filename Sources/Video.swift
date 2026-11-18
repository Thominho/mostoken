import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import VideoToolbox

enum VideoCodec {
    /// H.264 without transparency; works with every MostOken version.
    case h264
    /// HEVC with an alpha channel (Apple silicon): sharper at the same bitrate and keeps the
    /// window's rounded corners and shadow shape.
    case hevcAlpha
}

/// Hardware video encoder tuned for low latency screen content.
final class VideoEncoder {
    let width: Int
    let height: Int
    let codec: VideoCodec
    private var session: VTCompressionSession?
    private let output: (Data, Bool, [Data]) -> Void

    /// Whether this Mac can encode HEVC with alpha in hardware (checked once).
    static let hevcAlphaSupported: Bool = {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: 256, height: 256, codecType: kCMVideoCodecType_HEVCWithAlpha,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        if let s { VTCompressionSessionInvalidate(s) }
        return status == noErr
    }()

    init?(width: Int, height: Int, codec: VideoCodec = .h264, output: @escaping (Data, Bool, [Data]) -> Void) {
        self.width = width
        self.height = height
        self.codec = codec
        self.output = output

        let codecType = codec == .hevcAlpha ? kCMVideoCodecType_HEVCWithAlpha : kCMVideoCodecType_H264
        var created: VTCompressionSession?
        func create(_ spec: [String: Any]?) -> OSStatus {
            VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: codecType, encoderSpecification: spec as CFDictionary?,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        var status = create([kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true])
        if status != noErr || created == nil {
            status = create(nil)
        }
        guard status == noErr, let s = created else {
            Log.write("Nelze vytvořit kodér videa (\(codec)): \(status)")
            return nil
        }
        session = s

        func set(_ key: CFString, _ value: CFTypeRef) {
            let r = VTSessionSetProperty(s, key: key, value: value)
            if r != noErr && r != kVTPropertyNotSupportedErr { Log.write("Kodér: nelze nastavit \(key) (\(r))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 60))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 10))
        let pixels = width * height
        switch codec {
        case .h264:
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
            set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: min(max(pixels * 6, 6_000_000), 60_000_000)))
        case .hevcAlpha:
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
            set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: min(max(pixels * 4, 4_000_000), 45_000_000)))
            set(kVTCompressionPropertyKey_TargetQualityForAlpha, NSNumber(value: 0.75))
        }
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { invalidate() }

    func invalidate() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        session = nil
    }

    func flush() {
        if let s = session { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid) }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, forceKey: Bool) {
        guard let session else { return }
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        let props: CFDictionary? = forceKey
            ? ([kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary) : nil
        let out = output, codec = self.codec
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else {
                if status != noErr { Log.write("Chyba kódování snímku: \(status)") }
                return
            }
            VideoEncoder.extract(sampleBuffer, codec: codec, out)
        }
        if status != noErr { Log.write("Snímek nejde zakódovat: \(status)") }
    }

    static func extract(_ sb: CMSampleBuffer, codec: VideoCodec, _ out: (Data, Bool, [Data]) -> Void) {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }

        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary.self)
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            if let value = CFDictionaryGetValue(dict, key) {
                isKey = !CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
            }
        }

        var sets: [Data] = []
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb) {
            switch codec {
            case .h264:
                var count = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                for i in 0..<count {
                    var ptr: UnsafePointer<UInt8>?
                    var size = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                        sets.append(Data(bytes: ptr, count: size))
                    }
                }
            case .hevcAlpha:
                // The whole description (incl. the alpha layer info), not just VPS/SPS/PPS.
                if let d = VideoFormat.serialize(fmt) { sets = [d] }
            }
        }

        guard let data = blockData(block) else { return }
        out(data, isKey, sets)
    }

    private static func blockData(_ block: CMBlockBuffer) -> Data? {
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }
}

enum VideoFormat {
    private static let encoding = CFStringBuiltInEncodings.UTF8.rawValue

    static func serialize(_ fmt: CMVideoFormatDescription) -> Data? {
        var block: CMBlockBuffer?
        guard CMVideoFormatDescriptionCopyAsBigEndianImageDescriptionBlockBuffer(
            allocator: kCFAllocatorDefault, videoFormatDescription: fmt, stringEncoding: encoding,
            flavor: nil, blockBufferOut: &block) == noErr, let block else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    static func deserialize(_ data: Data) -> CMVideoFormatDescription? {
        guard let block = H264.blockBuffer(data) else { return nil }
        var fmt: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionBlockBuffer(
            allocator: kCFAllocatorDefault, bigEndianImageDescriptionBlockBuffer: block, stringEncoding: encoding,
            flavor: nil, formatDescriptionOut: &fmt)
        if status != noErr { Log.write("Neplatný popis videa: \(status)") }
        return fmt
    }

    /// Format description carried by a keyframe, for either codec.
    static func from(_ frame: VideoFrame) -> CMVideoFormatDescription? {
        guard frame.isKey else { return nil }
        if frame.isHEVC {
            return frame.parameterSets.first.flatMap(deserialize)
        }
        return H264.makeFormat(frame.parameterSets)
    }
}

enum H264 {
    static func makeFormat(_ sets: [Data]) -> CMVideoFormatDescription? {
        guard sets.count >= 2 else { return nil }
        let buffers: [UnsafeMutablePointer<UInt8>] = sets.map { d in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, d.count))
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        let sizes = sets.map { $0.count }
        var fmt: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
            parameterSetPointers: pointers, parameterSetSizes: sizes,
            nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        if status != noErr { Log.write("Neplatné parametry videa: \(status)") }
        return fmt
    }

    static func blockBuffer(_ data: Data) -> CMBlockBuffer? {
        guard !data.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        return copied == kCMBlockBufferNoErr ? block : nil
    }

    /// Works for both codecs (both use length-prefixed NAL units).
    static func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        guard let block = blockBuffer(data) else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue!).toOpaque())
        }
        return sample
    }
}

/// Composites the captured window (which has transparent rounded corners) over a solid
/// background, because H.264 has no alpha channel and would otherwise show black corners.
final class Flattener {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                              .cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    let background: CIColor

    init(background: CIColor) { self.background = background }

    func flatten(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
        if pool == nil || w != poolWidth || h != poolHeight {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                    [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                    attrs as CFDictionary, &p)
            pool = p
            poolWidth = w
            poolHeight = h
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let out else { return nil }
        CVBufferPropagateAttachments(source, out)
        let image = CIImage(cvPixelBuffer: source)
        let backdrop = CIImage(color: background).cropped(to: image.extent)
        context.render(image.composited(over: backdrop), to: out)
        return out
    }
}
