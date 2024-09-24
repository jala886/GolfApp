//
//  VideoRecorder.swift
//  PoseFinder
//
//  Created by jl on 9/24/24.
//  Copyright © 2024 Apple. All rights reserved.
//

import Foundation
import AVFoundation

class VideoRecorder: NSObject {
    private var _captureSession: AVCaptureSession?
    private var _videoOutput: AVCaptureVideoDataOutput?
    private var _assetWriter: AVAssetWriter?
    private var _assetWriterInput: AVAssetWriterInput?
    private var _adpater: AVAssetWriterInputPixelBufferAdaptor?
    private var _filename = ""
    private var _time: Double = 0
    
    init(session: AVCaptureSession) {
        super.init()
        let output = AVCaptureVideoDataOutput()
        guard session.canAddOutput(output) else { return }
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.golfapp.video"))
        session.beginConfiguration()
        session.addOutput(output)
        session.commitConfiguration()
        _videoOutput = output
        _captureSession = session
    }
    
    private enum _CaptureState {
        case idle, start, capturing, end
    }
    private var _captureState = _CaptureState.idle
    func capture() {
        switch _captureState {
        case .idle:
            _captureState = .start
        case .capturing:
            _captureState = .end
        default:
            break
        }
    }
}

extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        switch _captureState {
        case .start:
            // Set up recorder
            _filename = UUID().uuidString
            let videoPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("\(_filename).mov")
            let writer = try! AVAssetWriter(outputURL: videoPath, fileType: .mov)
            let settings = _videoOutput!.recommendedVideoSettingsForAssetWriter(writingTo: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings) // [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080])
            input.mediaTimeScale = CMTimeScale(bitPattern: 600)
            input.expectsMediaDataInRealTime = true
            input.transform = CGAffineTransform(rotationAngle: .pi/2)
            let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            if writer.canAdd(input) {
                writer.add(input)
            }
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            _assetWriter = writer
            _assetWriterInput = input
            _adpater = adapter
            _captureState = .capturing
            _time = timestamp
        case .capturing:
            if _assetWriterInput?.isReadyForMoreMediaData == true {
                let time = CMTime(seconds: timestamp - _time, preferredTimescale: CMTimeScale(600))
                _adpater?.append(CMSampleBufferGetImageBuffer(sampleBuffer)!, withPresentationTime: time)
            }
            break
        case .end:
            guard _assetWriterInput?.isReadyForMoreMediaData == true, _assetWriter!.status != .failed else { break }
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("\(_filename).mov")
            _assetWriterInput?.markAsFinished()
            _assetWriter?.finishWriting { [weak self] in
                self?._captureState = .idle
                self?._assetWriter = nil
                self?._assetWriterInput = nil
                /// show finished recording message
//                DispatchQueue.main.async {
//                    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
//                    self?.present(activity, animated: true, completion: nil)
//                }
            }
        default:
            break
        }
    }
}
