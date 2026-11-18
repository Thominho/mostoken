import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import VideoToolbox

/// Hardware H.264 encoder tuned for low latency screen content.
final class VideoEncoder {
    let width: Int
    let height: Int
    private var session: VTCompressionSession?
    private let output: (Data, Bool, [Data]) -> Void

    init?(width: Int, height: Int, output: @escaping (Data, Bool, [Data]) -> Void) {
        self.width = width
        self.height = height
        self.output = output

        var created: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true] as CFDictionary
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: lowLatency,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        if status != noErr || created == nil {
            Log.write("Kodér s nízkou latencí není k dispozici (\(status)), používám běžný")
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let s = created else {
            Log.write("Nelze vytvořit kodér videa: \(status)")
            return nil
        }
        session = s

        func set(_ key: CFString, _ value: CFTypeRef) {
            let r = VTSessionSetProperty(s, key: key, value: value)
            if r != noErr { Log.write("Kodér: nelze nastavit \(key) (\(r))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        let bitrate = min(max(width * height * 6, 6_000_000), 60_000_000)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 60))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 10))
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
        let out = output
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else {
                if status != noErr { Log.write("Chyba kódování snímku: \(status)") }
                return
            }
            VideoEncoder.extract(sampleBuffer, out)
        }
        if status != noErr { Log.write("Snímek nejde zakódovat: \(status)") }
    }

    static func extract(_ sb: CMSampleBuffer, _ out: (Data, Bool, [Data]) -> Void) {
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
        }

        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        out(data, isKey, sets)
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

    static func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
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
        guard copied == kCMBlockBufferNoErr else { return nil }

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
