import Foundation
import AVFoundation
import VideoToolbox

// MARK: - 1. 安全内存胶囊
private final class SafeMemory: @unchecked Sendable {
    private let address: UInt
    let count: Int
    
    init(from data: [UInt8]) {
        self.count = data.count
        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        ptr.initialize(from: data, count: count)
        self.address = UInt(bitPattern: ptr)
    }
    
    deinit {
        if let ptr = UnsafeMutablePointer<UInt8>(bitPattern: address) {
            ptr.deallocate()
        }
    }
    
    var pointer: UnsafeMutablePointer<UInt8> {
        return UnsafeMutablePointer<UInt8>(bitPattern: address)!
    }
}

// MARK: - 2. 线程安全传输包装器
struct SendableSampleBuffer: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
}

// MARK: - 3. H.264 解码器
final class H264Decoder: @unchecked Sendable {
    
    private let decodeQueue = DispatchQueue(label: "com.miniorange.h264decoder", qos: .userInteractive)
    private var naluBuffer: [UInt8] = []
    
    private var spsMemory: SafeMemory?
    private var ppsMemory: SafeMemory?
    
    private var formatDescription: CMVideoFormatDescription?
    
    var onNewSampleBuffer: ((SendableSampleBuffer) -> Void)?
    
    init() {
        print("✅ [H264Decoder] Initialized (Fixed Sample Size Mode)")
    }
    
    // MARK: - API
    
    nonisolated func handleData(_ data: Data) {
        let count = data.count
        var bytes = [UInt8](repeating: 0, count: count)
        data.copyBytes(to: &bytes, count: count)
        
        decodeQueue.async { [weak self] in
            guard let self = self else { return }
            self.processRawBytes(bytes)
        }
    }
    
    // MARK: - Internal Logic
    
    private func processRawBytes(_ data: [UInt8]) {
        // 简单校验
        guard data.count > 3, data[0] == 0xAA else { return }
        let snLen = Int(data[2])
        let headerSize = 3 + snLen
        guard data.count > headerSize else { return }
        
        let payload = Array(data[headerSize..<data.count])
        naluBuffer.append(contentsOf: payload)
        extractNALUs()
    }
    
    private func extractNALUs() {
        var offset = 0
        let totalLength = naluBuffer.count
        var lastStartCodeIndex: Int? = nil
        var lastStartCodeLen = 0
        
        while offset < totalLength - 3 {
            var isStartCode = false
            var currentStartCodeLen = 0
            
            if naluBuffer[offset] == 0 && naluBuffer[offset+1] == 0 {
                if naluBuffer[offset+2] == 1 {
                    isStartCode = true
                    currentStartCodeLen = 3
                } else if offset + 3 < totalLength && naluBuffer[offset+2] == 0 && naluBuffer[offset+3] == 1 {
                    isStartCode = true
                    currentStartCodeLen = 4
                }
            }
            
            if isStartCode {
                if let prevIndex = lastStartCodeIndex {
                    let naluBytes = Array(naluBuffer[(prevIndex + lastStartCodeLen)..<offset])
                    decodeSingleNALU(naluBytes)
                }
                lastStartCodeIndex = offset
                lastStartCodeLen = currentStartCodeLen
                offset += currentStartCodeLen
            } else {
                offset += 1
            }
        }
        
        if let lastIndex = lastStartCodeIndex {
            if lastIndex > 0 { naluBuffer.removeFirst(lastIndex) }
        } else if naluBuffer.count > 500_000 {
            naluBuffer.removeAll(keepingCapacity: false)
        }
    }
    
    private func decodeSingleNALU(_ nalu: [UInt8]) {
        guard !nalu.isEmpty else { return }
        let type = nalu[0] & 0x1F
        
        switch type {
        case 7: // SPS
            spsMemory = SafeMemory(from: nalu)
        case 8: // PPS
            ppsMemory = SafeMemory(from: nalu)
            createFormatDescription()
        case 5: // IDR
            createFormatDescription()
            enqueueFrame(nalu)
        case 1: // P/B Frame
            enqueueFrame(nalu)
        default:
            break
        }
    }
    
    private func createFormatDescription() {
        guard let sps = spsMemory, let pps = ppsMemory, formatDescription == nil else { return }
        
        let spsPtr = UnsafePointer(sps.pointer)
        let ppsPtr = UnsafePointer(pps.pointer)
        
        let parameterSetPointers = [spsPtr, ppsPtr]
        let parameterSetSizes = [sps.count, pps.count]
        
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: parameterSetPointers,
            parameterSetSizes: parameterSetSizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &formatDesc
        )
        
        if status == noErr {
            self.formatDescription = formatDesc
            print("✅ [H264Decoder] Format Description Created")
        }
    }
    
    private func enqueueFrame(_ nalu: [UInt8]) {
        guard let formatDesc = formatDescription else { return }
        
        let naluLen = nalu.count
        let totalSize = 4 + naluLen
        
        // 1. 申请内存
        let rawPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: totalSize)
        
        // 2. 写入长度头 (Big Endian)
        let length = UInt32(naluLen)
        rawPtr[0] = UInt8((length >> 24) & 0xFF)
        rawPtr[1] = UInt8((length >> 16) & 0xFF)
        rawPtr[2] = UInt8((length >> 8) & 0xFF)
        rawPtr[3] = UInt8(length & 0xFF)
        
        // 3. 拷贝 NALU 数据
        let naluData = Data(nalu)
        naluData.copyBytes(to: rawPtr + 4, count: naluLen)
        
        // 4. 创建 CMBlockBuffer
        var safeBlockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalSize,
            flags: 0,
            blockBufferOut: &safeBlockBuffer
        )
        
        if createStatus == noErr, let buffer = safeBlockBuffer {
            CMBlockBufferReplaceDataBytes(with: rawPtr, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: totalSize)
        }
        
        // 释放临时指针
        rawPtr.deallocate()
        
        guard createStatus == noErr, let buffer = safeBlockBuffer else { return }
        
        // 5. 创建 CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo()
        timingInfo.decodeTimeStamp = .invalid
        // 使用当前系统时间，配合 Layer 的默认设置可实现立即播放
        timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        timingInfo.duration = .invalid
        
        // 🔥 修复点 1：明确传入 sampleSizeArray，消除 "single-sample" 警告
        var sampleSize = totalSize
        
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,       // 明确指定有一个尺寸条目
            sampleSizeArray: &sampleSize,  // 传入尺寸数组的地址
            sampleBufferOut: &sampleBuffer
        )
        
        if sampleStatus == noErr, let sampleBuffer = sampleBuffer {
            // 🔥 修复点 2：添加 "Display Immediately" 附件
            // 告诉播放器不要等待时间戳，收到即渲染，解决卡在第一帧的问题
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
                let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                CFDictionarySetValue(dict, key, value)
            }
            
            onNewSampleBuffer?(SendableSampleBuffer(sampleBuffer: sampleBuffer))
        }
    }
}
