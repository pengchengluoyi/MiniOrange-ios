import Foundation
import ReplayKit
import VideoToolbox

class ScreenRecorder: NSObject {
    static let shared = ScreenRecorder()
    
    private var compressionSession: VTCompressionSession?
    private var isRecording = false
    
    func startRecording() {
        guard !isRecording else { return }
        
        RPScreenRecorder.shared().startCapture { sampleBuffer, type, error in
            if let error = error {
                print("❌ [ScreenRecorder] Capture error: \(error)")
                return
            }
            
            if type == .video {
                self.processVideoSampleBuffer(sampleBuffer)
            }
        } completionHandler: { error in
            if let error = error {
                print("❌ [ScreenRecorder] Start capture error: \(error)")
            } else {
                Task { @MainActor in
                    self.isRecording = true
                    print("✅ [ScreenRecorder] Started")
                }
            }
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        RPScreenRecorder.shared().stopCapture { error in
            Task { @MainActor in
                self.isRecording = false
                self.invalidateCompressionSession()
                print("🛑 [ScreenRecorder] Stopped")
            }
        }
    }
    
    private func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if compressionSession == nil {
            setupCompressionSession(width: width, height: height)
        }
        
        guard let session = compressionSession else { return }
        
        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(session,
                                        imageBuffer: imageBuffer,
                                        presentationTimeStamp: presentationTimestamp,
                                        duration: .invalid,
                                        frameProperties: nil,
                                        sourceFrameRefcon: nil,
                                        infoFlagsOut: &flags)
    }
    
    private func setupCompressionSession(width: Int, height: Int) {
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: Int32(width),
                                                height: Int32(height),
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: compressionCallback,
                                                refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                                compressionSessionOut: &compressionSession)
        
        if status != noErr {
            print("❌ [ScreenRecorder] Failed to create compression session: \(status)")
            return
        }
        
        guard let session = compressionSession else { return }
        
        // H.264 Configuration
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber) // GOP ~1-2s
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)
        
        VTCompressionSessionPrepareToEncodeFrames(session)
        print("✅ [ScreenRecorder] Compression session created: \(width)x\(height)")
    }
    
    private func invalidateCompressionSession() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }
    
    // C-style callback for VideoToolbox
    private var compressionCallback: VTCompressionOutputCallback = { (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer) in
        guard status == noErr, let sampleBuffer = sampleBuffer, let refCon = outputCallbackRefCon else { return }
        let recorder = Unmanaged<ScreenRecorder>.fromOpaque(refCon).takeUnretainedValue()
        recorder.handleEncodedFrame(sampleBuffer)
    }
    
    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        // Handle SPS/PPS for Keyframes if needed (omitted for brevity, usually handled by sending IDR with headers)
        
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard let pointer = dataPointer else { return }
        
        // Read NALUs (AVCC format: 4 byte length + data) and convert to Annex B (00 00 00 01 + data)
        var bufferOffset = 0
        let headerLength = 4
        
        while bufferOffset < length - headerLength {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, pointer + bufferOffset, headerLength)
            naluLength = CFSwapInt32BigToHost(naluLength)
            
            let naluOffset = bufferOffset + headerLength
            let naluData = Data(bytes: pointer + naluOffset, count: Int(naluLength))
            
            // Construct Annex B NALU
            var packetData = Data([0x00, 0x00, 0x00, 0x01])
            packetData.append(naluData)
            
            sendPacket(nalu: packetData)
            
            bufferOffset += headerLength + Int(naluLength)
        }
    }
    
    private func sendPacket(nalu: Data) {
        Task { @MainActor in
            guard let viewerSN = WebSocketManager.shared.currentViewerSN else { return }
            guard let snData = viewerSN.data(using: .utf8) else { return }
            let snLen = UInt8(snData.count)
            
            var packet = Data()
            packet.append(0xAA) // Magic
            packet.append(0x02) // Type
            packet.append(snLen) // SN Len
            packet.append(snData) // SN
            packet.append(nalu) // Payload
            
            WebSocketManager.shared.send(data: packet)
        }
    }
}