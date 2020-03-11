//
//  CubicManager.swift
//  cubic-demo
//
//

import Foundation
import AVFoundation
import SwiftProtobuf
import GRPC
import NIO
import NIOSSL

public protocol CubicManagerDelegate: class {
    
    func managerDidRecognizeWithResponse(_ res: Cobaltspeech_Cubic_RecognitionResponse)
    func streamCompletion(_ result: Cobaltspeech_Cubic_RecognitionResponse?)
    func streamReceive(_ result: Cobaltspeech_Cubic_RecognitionResponse)
    
}

public class CubicManager: NSObject, AVAudioRecorderDelegate {
    
    private let client: Cobaltspeech_Cubic_CubicServiceClient
    private var whistleRecorder: AVAudioRecorder!
    private var selectedModelId: String = "\(1)"
    private var selectedSampleRate: uint = 16000
    private var callStream: BidirectionalStreamingCall<Cobaltspeech_Cubic_StreamingRecognizeRequest, Cobaltspeech_Cubic_RecognitionResponse>?
    private var audioEngine : AVAudioEngine!
    private var audioFile : AVAudioFile!
    private var outref: ExtAudioFileRef?
    private var filePath : String? = nil
    private var eventLoopGroup: EventLoopGroup
    public weak var delegate: CubicManagerDelegate?
    var isRecord = false
    
    public var selectedModel: Cobaltspeech_Cubic_Model? {
        didSet {
            if let c = selectedModel {
                selectedModelId = c.id
                selectedSampleRate = c.attributes.sampleRate
            }
        }
    }
    
    public required init(client: Cobaltspeech_Cubic_CubicServiceClient) {
        self.client = client
        self.eventLoopGroup = PlatformSupport.makeEventLoopGroup(loopCount: 1,
                                                                 networkPreference: .best)
    }
    
    public init(host: String, port: Int, useTLS: Bool = false) {
        let target = ConnectionTarget.hostAndPort(host, port)
        self.eventLoopGroup = PlatformSupport.makeEventLoopGroup(loopCount: 1,
                                                                 networkPreference: .best)
        
        let tls = useTLS ? ClientConnection.Configuration.TLS() : nil
        
        let configuration = ClientConnection.Configuration(target: target, eventLoopGroup: self.eventLoopGroup, errorDelegate: nil, connectivityStateDelegate: nil, tls: tls, connectionBackoff: nil)
        let connection = ClientConnection.init(configuration: configuration)
        self.client = Cobaltspeech_Cubic_CubicServiceClient(connection: connection)
    }
    
    public init(host: String, port: Int, tlsCertificateFileName: String, tlsCertificateFormat: NIOSSLSerializationFormats) {
        let target = ConnectionTarget.hostAndPort(host, port)
        self.eventLoopGroup = PlatformSupport.makeEventLoopGroup(loopCount: 1,
                                                                 networkPreference: .best)
        
        var configuration = ClientConnection.Configuration(target: target, eventLoopGroup: self.eventLoopGroup)
        
        if let cert = try? NIOSSLCertificate(file: tlsCertificateFileName, format: tlsCertificateFormat) {
            let source = NIOSSLCertificateSource.certificate(cert)
            var tls = ClientConnection.Configuration.TLS()
            tls.certificateChain.append(source)
            configuration.tls = tls
        }
        
        let connection = ClientConnection.init(configuration: configuration)
        self.client = Cobaltspeech_Cubic_CubicServiceClient(connection: connection)
    }
    
    func log(_ text: String){
        print("CF: \(text)")
    }
    
    public func listModels(callback: @escaping(_ models: [Cobaltspeech_Cubic_Model]?, _ errorMessage: String?) -> ()) {
        let listModels = Cobaltspeech_Cubic_ListModelsRequest()
        
        client.listModels(listModels).response.whenComplete({ (result) in
            DispatchQueue.main.async {
                do {
                    let response = try result.get()
                    callback( response.models, nil)
                } catch let e {
                    print("\(e)")
                    callback(nil, e.localizedDescription)
                }
            }
        })
    }
    
    public func isAuthorized() -> Bool {
        return AVCaptureDevice.authorizationStatus(for: AVMediaType.audio) == .authorized
    }
    
    public func requestAccess(completionHandler: @escaping((_ granted: Bool) -> ())) {
        AVCaptureDevice.requestAccess(for:  AVMediaType.audio, completionHandler: completionHandler)
    }
    
    private class func getDocumentsDirectory() -> URL {
       let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
       let documentsDirectory = paths[0]
       return documentsDirectory
    }
    
    private class func getWavURL(_ name: String = "") -> URL {
        return CubicManager.getDocumentsDirectory().appendingPathComponent("whistle\(name).wav")
    }
    
    @available(iOS 9.0, *)
    public func startStream() {
        let call = self.client.streamingRecognize(handler: { (recres) in
            self.delegate?.streamCompletion(recres)
        })

        var conReq = Cobaltspeech_Cubic_StreamingRecognizeRequest()
        conReq.config.modelID = self.selectedModelId
        conReq.config.idleTimeout.seconds = 5
        conReq.config.audioEncoding = .rawLinear16
        call.sendMessage(conReq).whenComplete({ (result) in
            do {
                try result.get()
            } catch let e {
                self.log("Error \(e)")
            }
        })
        
        callStream = call
        self.startAudioEngine()
    }
    
    @available(iOS 9.0, *)
    func startAudioEngine() {
        try! AVAudioSession.sharedInstance().setCategory(.playAndRecord)
        try! AVAudioSession.sharedInstance().setActive(true)

        if audioEngine == nil {
            audioEngine = AVAudioEngine()
        }

        let format = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatInt16,
                                   sampleRate: 44100.0,
                                   channels: 1,
                                   interleaved: true)
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: selectedSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        let downFormat = AVAudioFormat(settings: settings)
        audioEngine.connect(audioEngine.inputNode, to: audioEngine.mainMixerNode, format: format)
        
        /*If you want record to file */
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first! as String
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filePath = dir.appending(String(format: "/%@.wav", formatter.string(from: Date())))
        let outurl = URL(fileURLWithPath: filePath)
        self.filePath = filePath
        
        _ = ExtAudioFileCreateWithURL(outurl as CFURL,
            kAudioFileWAVEType,
            downFormat!.streamDescription,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &outref)
        
        /*if you want record to file end */
        audioEngine.inputNode.installTap(onBus: 0,
                                         bufferSize: AVAudioFrameCount(format!.sampleRate * 0.4),
                                         format: format,
                                         block: { (buffer: AVAudioPCMBuffer!, time: AVAudioTime!) -> Void in
            let converter = AVAudioConverter(from: format!, to: downFormat!)
            let newbuffer = AVAudioPCMBuffer(pcmFormat: downFormat!,
                frameCapacity: AVAudioFrameCount(downFormat!.sampleRate * 0.4))
                                            
            let inputBlock: AVAudioConverterInputBlock = { (inNumPackets, outStatus) -> AVAudioBuffer? in
                outStatus.pointee = AVAudioConverterInputStatus.haveData
                let audioBuffer : AVAudioBuffer = buffer
                return audioBuffer
            }
                                            
            if let nb = newbuffer {
                var error: NSError?
                //converter!.convert(to: nb, from: buffer)
                converter!.convert(to: nb, error: &error, withInputFrom: inputBlock)
                self.sendStreamPartToServer(nb,time)
                _ = ExtAudioFileWrite(self.outref!, nb.frameLength, nb.audioBufferList)
            }
        })

        try! audioEngine.start()
        self.isRecord = true
    }
    
    @available(iOS 9.0, *)
    private func sendStreamPartToServer(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        if let oldCall = self.callStream {
            var req = Cobaltspeech_Cubic_StreamingRecognizeRequest()
            let data = Data(buffer: buffer, time: time)
            req.audio.data = data
            oldCall.sendMessage(req).whenComplete({ (result) in
                do {
                    try result.get()
                } catch let e {
                    self.log("Send error: \(e)")
                }
            })
            
            self.log("sendToServer")
        }
    }
    
    @available(iOS 9.0, *)
    func stopStream() {
        stopAudioEngine()
        stopGRPCStream()
    }
    
    @available(iOS 9.0, *)
    private func stopAudioEngine() {
        if audioEngine != nil && audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            ExtAudioFileDispose(self.outref!)
            try! AVAudioSession.sharedInstance().setActive(false)
            self.isRecord = false
        }
    }
    
    private func stopGRPCStream() {
        if let call = self.callStream {
            call.sendEnd().whenFailure { (error) in
                print("\(error)")
            }
        }
    }
    
    @discardableResult
    public func record() -> Bool {
        //kAudioFormatMPEG4AAC default
        if !isAuthorized() {
            return false
        }
        
        let settings: [String : Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: selectedSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            let audioURL = CubicManager.getWavURL()
            whistleRecorder = try AVAudioRecorder(url: audioURL, settings: settings)
            whistleRecorder.delegate = self
            isRecord = whistleRecorder.record()
            return isRecord
        } catch {
            finishRecording(success: false)
        }
        
        return false
    }
    
    func finishRecording(success: Bool) {
        whistleRecorder?.stop()
        whistleRecorder = nil
    }
    
    public func stop() {
        if (isRecord) {
            finishRecording(success: true)
            uploadRecord()
        }
    }
    
    func uploadRecord() {
        do {
            var req = Cobaltspeech_Cubic_RecognizeRequest()
            req.config = Cobaltspeech_Cubic_RecognitionConfig()
            req.config.modelID = selectedModelId
            req.config.idleTimeout = Google_Protobuf_Duration()
            req.config.idleTimeout.seconds = 5
            req.config.audioEncoding = .rawLinear16
            
            req.audio = Cobaltspeech_Cubic_RecognitionAudio()
            let audioUrl = CubicManager.getWavURL()
            req.audio.data = try Data(contentsOf: audioUrl)
            client.recognize(req).response.whenComplete({ (response) in
                do {
                    let res = try response.get()
                    self.log("Res from \(String(describing: try res.jsonString()))")
                    DispatchQueue.main.async {
                        self.delegate?.managerDidRecognizeWithResponse(res)
                    }
                } catch let e {
                    print("\(e)")
                }
              
            })
        } catch let e {
            print("\(e)")
        }
    }
}

extension Data {
    
    init(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        self.init(bytes: audioBuffer.mData!, count: Int(audioBuffer.mDataByteSize))
    }

}
