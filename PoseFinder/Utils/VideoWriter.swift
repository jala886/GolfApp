//
//  SaveUIImageArrayToVideo.swift
//  GolfApp
//
//  Created by jason li on 9/20/24.
//  Copyright © 2024 Apple. All rights reserved.
//

import Foundation

import UIKit
import AVFoundation

class VideoWriter {
    fileprivate var writer: AVAssetWriter
    fileprivate var writerInput: AVAssetWriterInput
    fileprivate var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    fileprivate let queue: DispatchQueue
    static var ciContext = CIContext.init() // we reuse a single context for performance reasons

    let pixelSize: CGSize
    var lastPresentationTime: CMTime?

    init?(url: URL, width: Int, height: Int, sessionStartTime: CMTime, isRealTime: Bool, queue: DispatchQueue) {
        NSLog("VideoWriter init: width=\(width) height=\(height), url=\(url)")
        self.queue = queue
        let outputSettings: [String:Any] = [
            AVVideoCodecKey : AVVideoCodecType.h264, // or .hevc if you like
            AVVideoWidthKey : width,
            AVVideoHeightKey: height,
        ]
        self.pixelSize = CGSize.init(width: width, height: height)
        let input = AVAssetWriterInput.init(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = isRealTime
        guard
            let writer = try? AVAssetWriter.init(url: url, fileType: .mp4),
            writer.canAdd(input),
            sessionStartTime != .invalid
        else {
            return nil
        }
        
        let sourceBufferAttributes: [String:Any] = [
            String(kCVPixelBufferPixelFormatTypeKey) : kCVPixelFormatType_32ARGB, // yes, ARGB is right here for images...
            String(kCVPixelBufferWidthKey) : width,
            String(kCVPixelBufferHeightKey) : height,
        ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor.init(assetWriterInput: input, sourcePixelBufferAttributes: sourceBufferAttributes)
        self.pixelBufferAdaptor = pixelBufferAdaptor
        
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: sessionStartTime)
        
        if let error = writer.error {
            NSLog("VideoWriter init: ERROR - \(error)")
            return nil
        }
        
        self.writer = writer
        self.writerInput = input
    }

    func add(image: UIImage, presentationTime: CMTime) -> Bool {
        if self.writerInput.isReadyForMoreMediaData == false {
            return false
        }
        if self.pixelBufferAdaptor.appendPixelBufferForImage(image, presentationTime: presentationTime) {
            self.lastPresentationTime = presentationTime
            return true
        }
        return false
    }
    
    func add(sampleBuffer: CMSampleBuffer) -> Bool {
        if self.writerInput.isReadyForMoreMediaData == false {
            NSLog("VideoWriter: not ready for more data")
            return false
        }

        if self.writerInput.append(sampleBuffer) {
            self.lastPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            return true
        }
        return false
    }
    
    func finish(_ completionBlock: ((AVURLAsset?)->Void)? = nil) {
        writerInput.markAsFinished()
        NSLog("VideoWriter: calling writer.finishWriting()")
        writer.finishWriting(completionHandler: {
            self.queue.async {
                guard self.writer.status == .completed else {
                    NSLog("VideoWriter finish: error in finishWriting - \(String(describing: self.writer.error))")
                    completionBlock?(nil)
                    return
                }
                let asset = AVURLAsset.init(url: self.writer.outputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey : true])
                let duration = CMTimeGetSeconds(asset.duration)
                // can check for minimum duration here (ie. consider a failure if too short)
                NSLog("VideoWriter: finishWriting() complete, duration=\(duration)")
                completionBlock?(asset)
            }
        })
    }
}

extension AVAssetWriterInputPixelBufferAdaptor {
    func appendPixelBufferForImage(_ image: UIImage, presentationTime: CMTime) -> Bool {
        var appendSucceeded = false
        
        autoreleasepool {
            guard let pixelBufferPool = self.pixelBufferPool else {
                NSLog("appendPixelBufferForImage: ERROR - missing pixelBufferPool") // writer can have error:  writer.error=\(String(describing: self.writer.error))
                return
            }
                
            let pixelBufferPointer = UnsafeMutablePointer<CVPixelBuffer?>.allocate(capacity: 1)
            let status: CVReturn = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pixelBufferPool,
                pixelBufferPointer
            )
            
            if let pixelBuffer = pixelBufferPointer.pointee, status == 0 {
                pixelBuffer.fillPixelBufferFromImage(image)
                appendSucceeded = self.append(pixelBuffer, withPresentationTime: presentationTime)
                if !appendSucceeded {
                    // If a result of NO is returned, clients can check the value of AVAssetWriter.status to determine whether the writing operation completed, failed, or was cancelled.  If the status is AVAssetWriterStatusFailed, AVAsset.error will contain an instance of NSError that describes the failure.
                    NSLog("VideoWriter appendPixelBufferForImage: ERROR appending")
                }
                pixelBufferPointer.deinitialize(count: 1)
            } else {
                NSLog("VideoWriter appendPixelBufferForImage: ERROR - Failed to allocate pixel buffer from pool, status=\(status)") // -6680 = kCVReturnInvalidPixelFormat
            }
            pixelBufferPointer.deallocate()
        }
        return appendSucceeded
    }
}

extension CVPixelBuffer {
    func fillPixelBufferFromImage(_ image: UIImage) {
        CVPixelBufferLockBaseAddress(self, [])
        
        if let cgImage = image.cgImage {
            let pixelData = CVPixelBufferGetBaseAddress(self)
            let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
            guard
                let context = CGContext.init(
                    data: pixelData,
                    width: Int(image.size.width),
                    height: Int(image.size.height),
                    bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(self),
                    space: rgbColorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                )
            else {
                assert(false)
                return
            }
            
            context.draw(cgImage, in: CGRect.init(x: 0, y: 0, width: image.size.width, height: image.size.height))
        } else if let ciImage = image.ciImage {
            VideoWriter.ciContext.render(ciImage, to: self)
        }
        CVPixelBufferUnlockBaseAddress(self, [])
    }
}

func getDocumentsDirectory() -> URL {
    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    return paths[0]
}

