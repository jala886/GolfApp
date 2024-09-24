//
//  test.swift
//  PoseFinder
//
//  Created by jl on 9/22/24.
//  Copyright © 2024 Apple. All rights reserved.
//

import AVFoundation
import UIKit
import VideoToolbox

class ViewController: UIViewController {
    /// The view the controller uses to visualize the detected poses.
    @IBOutlet private var previewImageView: PoseImageView!
    
    private let videoCapture = VideoCapture()
    
    private lazy var videoRecorder = VideoRecorder(session: videoCapture.captureSession)
    
    private var poseNet: PoseNet!
    
    //private var frames = [UIImage]()
    
    //    private var videoWriter: VideoWriter? = {
    //        let filename = getDocumentsDirectory().appendingPathComponent("palying.mp4")
    //        //try? data.write(to: filename)
    //        let writer = VideoWriter(url: filename, width: 200, height: 200, sessionStartTime: CMTime(), isRealTime: true, queue: DispatchQueue.global())
    //        return writer
    //    }()
    
    var isPlaying: Bool = false
    
    /// The frame the PoseNet model is currently making pose predictions from.
    private var currentFrame: CGImage?
    
    /// The algorithm the controller uses to extract poses from the current frame.
    private var algorithm: Algorithm = .multiple
    
    /// The set of parameters passed to the pose builder when detecting poses.
    private var poseBuilderConfiguration = PoseBuilderConfiguration()
    
    private var popOverPresentationManager: PopOverPresentationManager?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // For convenience, the idle timer is disabled to prevent the screen from locking.
        UIApplication.shared.isIdleTimerDisabled = true
        
        do {
            poseNet = try PoseNet()
        } catch {
            fatalError("Failed to load model. \(error.localizedDescription)")
        }
        
        poseNet.delegate = self
        setupAndBeginCapturingVideoFrames()
    }
    
    private func setupAndBeginCapturingVideoFrames() {
        videoCapture.setUpAVCapture { error in
            if let error = error {
                print("Failed to setup camera with error \(error)")
                return
            }
            
            self.videoCapture.delegate = self
            
            self.videoCapture.startCapturing()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        videoCapture.stopCapturing {
            super.viewWillDisappear(animated)
        }
    }
    
    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        // Reinitilize the camera to update its output stream with the new orientation.
        setupAndBeginCapturingVideoFrames()
    }
    
    @IBAction func onCameraButtonTapped(_ sender: Any) {
        videoCapture.flipCamera { error in
            if let error = error {
                print("Failed to flip camera with error \(error)")
            }
        }
    }
    
    @IBAction func onAlgorithmSegmentValueChanged(_ sender: UISegmentedControl) {
        guard let selectedAlgorithm = Algorithm(
            rawValue: sender.selectedSegmentIndex) else {
            return
        }
        
        algorithm = selectedAlgorithm
    }
}

// MARK: - Navigation

extension ViewController {
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        guard let uiNavigationController = segue.destination as? UINavigationController else {
            return
        }
        guard let configurationViewController = uiNavigationController.viewControllers.first
                as? ConfigurationViewController else {
            return
        }
        
        configurationViewController.configuration = poseBuilderConfiguration
        configurationViewController.algorithm = algorithm
        configurationViewController.delegate = self
        
        popOverPresentationManager = PopOverPresentationManager(presenting: self,
                                                                presented: uiNavigationController)
        segue.destination.modalPresentationStyle = .custom
        segue.destination.transitioningDelegate = popOverPresentationManager
    }
}

// MARK: - ConfigurationViewControllerDelegate

extension ViewController: ConfigurationViewControllerDelegate {
    func configurationViewController(_ viewController: ConfigurationViewController,
                                     didUpdateConfiguration configuration: PoseBuilderConfiguration) {
        poseBuilderConfiguration = configuration
    }
    
    func configurationViewController(_ viewController: ConfigurationViewController,
                                     didUpdateAlgorithm algorithm: Algorithm) {
        self.algorithm = algorithm
    }
}

// MARK: - VideoCaptureDelegate

extension ViewController: VideoCaptureDelegate {
    func videoCapture(_ videoCapture: VideoCapture, didCaptureFrame capturedImage: CGImage?) {
        guard currentFrame == nil else {
            return
        }
        guard let image = capturedImage else {
            fatalError("Captured image is null")
        }
        
        currentFrame = image
        poseNet.predict(image)
    }
}

// MARK: - PoseNetDelegate

extension ViewController: PoseNetDelegate {
    func poseNet(_ poseNet: PoseNet, didPredict predictions: PoseNetOutput) {
        defer {
            // Release `currentFrame` when exiting this method.
            self.currentFrame = nil
        }
        
        guard let currentFrame = currentFrame else {
            return
        }
        
        let poseBuilder = PoseBuilder(output: predictions,
                                      configuration: poseBuilderConfiguration,
                                      inputImage: currentFrame)
        
        let poses = algorithm == .single
        ? [poseBuilder.pose]
        : poseBuilder.poses
        
        updateRecorder(poses: poses)
        
        previewImageView.show(poses: poses, on: currentFrame)
    }
    
    private func updateRecorder(poses: [Pose]) {
        // MARK: record function
        if checkHasBody(poses: poses) {
            // hand blow of hip and within ankle to start recording
            if checkWristInHipToAnkle(poses: poses) && checkWristInAnkleToAnkle(poses: poses) {
                self.isPlaying = true
            }
            // "stop" have priority always
            if checkWristInEyeToHip(poses: poses) {
                self.isPlaying = false
            }
        } else {
            // stop recording for others
            self.isPlaying = false
        }
        // update recorder
        if videoRecorder._captureState != .start && isPlaying {
            videoRecorder._captureState = .start
        } else {
            videoRecorder._captureState = .end
        }
    }
    // MARK: check funtions
    private func checkHasBody(poses: [Pose]) -> Bool {
        // if posese empty, mean that no body in image
        return !poses.isEmpty
    }
    private func checkIsPlaying(poses: [Pose]) -> Bool {
        // very raw check
        if let eye = poses.first!.joints[.leftEar]?.position,
           let ankle = poses.first!.joints[.leftAnkle]?.position,
           let lwrist = poses.first!.joints[.leftWrist]?.position {
            // hand is lower than half body
            return abs(eye.y-ankle.y)/2 < abs(eye.y-lwrist.y)
        }
        return false
    }
    private func checkWristInEyeToHip(poses: [Pose]) -> Bool {
        if let eye = poses.first!.joints[.leftEar]?.position,
           let lwrist = poses.first!.joints[.leftWrist]?.position,
           let lhip = poses.first!.joints[.leftHip]?.position {
            return abs(eye.y-lhip.y) > abs(eye.y-lwrist.y)
        }
        return false
    }
    private func checkWristInHipToAnkle(poses: [Pose]) -> Bool {
        if let lankle = poses.first!.joints[.leftAnkle]?.position,
           let lwrist = poses.first!.joints[.leftWrist]?.position,
           let lhip = poses.first!.joints[.leftHip]?.position {
            return abs(lhip.y-lankle.y) < abs(lwrist.y-lankle.y)
        }
        return false
    }
    
    private func checkWristInAnkleToAnkle(poses: [Pose]) -> Bool {
        if let lankle = poses.first!.joints[.leftAnkle]?.position,
           let rankle = poses.first!.joints[.rightAnkle]?.position,
           let lwrist = poses.first!.joints[.leftWrist]?.position {
            let tmp = [lankle.x, rankle.x].sorted()
            return (tmp[0]...tmp[1]).contains(lwrist.x)
        }
        return false
    }
}
