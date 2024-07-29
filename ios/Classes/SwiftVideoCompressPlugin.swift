import Flutter
import AVFoundation

public class SwiftVideoCompressPlugin: NSObject, FlutterPlugin {
    private let channelName = "video_compress"
    private var exporter: AVAssetExportSession? = nil
    private var stopCommand = false
    private let channel: FlutterMethodChannel
    private let avController = AvController()
    
    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "video_compress", binaryMessenger: registrar.messenger())
        let instance = SwiftVideoCompressPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? Dictionary<String, Any>
        switch call.method {
        case "getByteThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getByteThumbnail(path, quality, position, result)
        case "getFileThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getFileThumbnail(path, quality, position, result)
        case "getMediaInfo":
            let path = args!["path"] as! String
            getMediaInfo(path, result)
        case "compressVideo":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let deleteOrigin = args!["deleteOrigin"] as! Bool
            let startTime = args!["startTime"] as? Double
            let duration = args!["duration"] as? Double
            let includeAudio = args!["includeAudio"] as? Bool
            let frameRate = args!["frameRate"] as? Int
            compressVideo(path, quality, deleteOrigin, startTime, duration, includeAudio,
                          frameRate, result)
        case "cancelCompression":
            cancelCompression(result)
        case "deleteAllCache":
            Utility.deleteFile(Utility.basePath(), clear: true)
            result(true)
        case "setLogLevel":
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func getBitMap(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult)-> Data?  {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return nil }
        
        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true
        
        let timeScale = CMTimeScale(track.nominalFrameRate)
        let time = CMTimeMakeWithSeconds(Float64(truncating: position),preferredTimescale: timeScale)
        guard let img = try? assetImgGenerate.copyCGImage(at:time, actualTime: nil) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: img)
        let compressionQuality = CGFloat(0.01 * Double(truncating: quality))
        return thumbnail.jpegData(compressionQuality: compressionQuality)
    }
    
    private func getByteThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        if let bitmap = getBitMap(path,quality,position,result) {
            result(bitmap)
        }
    }
    
    private func getFileThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        let fileName = Utility.getFileName(path)
        let url = Utility.getPathUrl("\(Utility.basePath())/\(fileName).jpg")
        Utility.deleteFile(path)
        if let bitmap = getBitMap(path,quality,position,result) {
            guard (try? bitmap.write(to: url)) != nil else {
                return result(FlutterError(code: channelName,message: "getFileThumbnail error",details: "getFileThumbnail error"))
            }
            result(Utility.excludeFileProtocol(url.absoluteString))
        }
    }
    
    public func getMediaInfoJson(_ path: String)->[String : Any?] {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return [:] }
        
        let playerItem = AVPlayerItem(url: url)
        let metadataAsset = playerItem.asset
        
        let orientation = avController.getVideoOrientation(path)
        
        let title = avController.getMetaDataByTag(metadataAsset,key: "title")
        let author = avController.getMetaDataByTag(metadataAsset,key: "author")
        
        let duration = asset.duration.seconds * 1000
        let filesize = track.totalSampleDataLength
        
        let size = track.naturalSize.applying(track.preferredTransform)
        
        let width = abs(size.width)
        let height = abs(size.height)
        
        let dictionary = [
            "path":Utility.excludeFileProtocol(path),
            "title":title,
            "author":author,
            "width":width,
            "height":height,
            "duration":duration,
            "filesize":filesize,
            "orientation":orientation
            ] as [String : Any?]
        return dictionary
    }
    
    private func getMediaInfo(_ path: String,_ result: FlutterResult) {
        let json = getMediaInfoJson(path)
        let string = Utility.keyValueToJson(json)
        result(string)
    }
    
    
    @objc private func updateProgress(timer:Timer) {
        let asset = timer.userInfo as! AVAssetExportSession
        if(!stopCommand) {
            channel.invokeMethod("updateProgress", arguments: "\(String(describing: asset.progress * 100))")
        }
    }
    
    private func getExportPreset(_ quality: NSNumber)->String {
        switch(quality) {
        case 1:
            return AVAssetExportPresetLowQuality    
        case 2:
            return AVAssetExportPresetMediumQuality
        case 3:
            return AVAssetExportPresetHighestQuality
        case 4:
            return AVAssetExportPreset640x480
        case 5:
            return AVAssetExportPreset960x540
        case 6:
            return AVAssetExportPreset1280x720
        case 7:
            return AVAssetExportPreset1920x1080
        default:
            return AVAssetExportPresetMediumQuality
        }
    }
    
    private func getComposition(_ isIncludeAudio: Bool,_ timeRange: CMTimeRange, _ sourceVideoTrack: AVAssetTrack)->AVAsset {
        let composition = AVMutableComposition()
        if !isIncludeAudio {
            let compressionVideoTrack = composition.addMutableTrack(withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid)
            compressionVideoTrack!.preferredTransform = sourceVideoTrack.preferredTransform
            try? compressionVideoTrack!.insertTimeRange(timeRange, of: sourceVideoTrack, at: CMTime.zero)
        } else {
            return sourceVideoTrack.asset!
        }
        
        return composition    
    }
    
    private func cropVideo(path: String, quality: NSNumber,startTime:Double, endTime:Double,result: @escaping FlutterResult)
{
    let sourceURL1=Utility.getPathUrl(path)
    let manager = FileManager.default

    guard let documentDirectory = try? manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {return}
        let asset = AVAsset(url: sourceURL1 as URL)
        let length = Float(asset.duration.value) / Float(asset.duration.timescale)
        print("video length: \(length) seconds")

        let mediaType = "mp4"
        let start = startTime
        let end = endTime

        var compressionUrl = documentDirectory.appendingPathComponent("output")
        do {
            try manager.createDirectory(at: compressionUrl, withIntermediateDirectories: true, attributes: nil)
            compressionUrl = compressionUrl.appendingPathComponent("\(UUID().uuidString).\(mediaType)")
        }catch let error {
            print(error)
        }

        //Remove existing file
        _ = try? manager.removeItem(at: compressionUrl)


        let exportSession = AVAssetExportSession(asset: asset, presetName: getExportPreset(quality))!
        exportSession.outputURL = compressionUrl
        exportSession.outputFileType = AVFileType.mp4

        let startTime = CMTime(seconds: Double(start ), preferredTimescale: 1000)
        let endTime = CMTime(seconds: Double(end ), preferredTimescale: 1000)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        exportSession.timeRange = timeRange

        let timer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(self.updateProgress),userInfo: exportSession, repeats: true)

        exportSession.exportAsynchronously(completionHandler: {
            timer.invalidate()
            if(self.stopCommand) {
                self.stopCommand = false
                var json = self.getMediaInfoJson(path)
                json["isCancel"] = true
                let jsonString = Utility.keyValueToJson(json)
                return result(jsonString)
            }
            // if deleteOrigin {
            //     let fileManager = FileManager.default
            //     do {
            //         if fileManager.fileExists(atPath: path) {
            //             try fileManager.removeItem(atPath: path)
            //         }
            //         self.exporter = nil
            //         self.stopCommand = false
            //     }
            //     catch let error as NSError {
            //         print(error)
            //     }
            // }
            var json = self.getMediaInfoJson(Utility.excludeEncoding(compressionUrl.path))
            json["isCancel"] = false
            let jsonString = Utility.keyValueToJson(json)
            result(jsonString)
        })
        self.exporter = exportSession    
    }

    private func compressVideo(_ path: String,_ quality: NSNumber,_ deleteOrigin: Bool,_ startTime: Double?,
                               _ duration: Double?,_ includeAudio: Bool?,_ frameRate: Int?,
                               _ result: @escaping FlutterResult) {

        let start=startTime ?? 0
        let end = start + (duration ?? 0)
        cropVideo(path: path, quality: quality, startTime: start, endTime: end, result: result)
        
        // let sourceVideoUrl = Utility.getPathUrl(path)
        // let sourceVideoType = "mp4"
        
        // let sourceVideoAsset = avController.getVideoAsset(sourceVideoUrl)
        // let sourceVideoTrack = avController.getTrack(sourceVideoAsset)

        // let uuid = NSUUID()
        // let compressionUrl =
        // Utility.getPathUrl("\(Utility.basePath())/\(Utility.getFileName(path))\(uuid.uuidString).\(sourceVideoType)")

        // let timescale = sourceVideoAsset.duration.timescale
        // let minStartTime = Double(startTime ?? 0)
        
        // let videoDuration = sourceVideoAsset.duration.seconds
        // let minDuration = Double(duration ?? videoDuration)
        // let maxDurationTime = minStartTime + minDuration < videoDuration ? minDuration : videoDuration
        
        // let cmStartTime = CMTime(second: minStartTime, preferredTimescale: timescale)
        // let cmEndTime = CMTimeMakeWithSeconds(minStartTime+minDuration, preferredTimescale: timescale)
        // let timeRange: CMTimeRange = CMTimeRange(start: cmStartTime, end: cmDurationTime)
        
        // /*
        // let isIncludeAudio = includeAudio != nil ? includeAudio! : true
        
        // let session = getComposition(isIncludeAudio, timeRange, sourceVideoTrack!)
        
        // let exporter = AVAssetExportSession(asset: session, presetName: getExportPreset(quality))!
        
        // exporter.outputURL = compressionUrl
        // exporter.outputFileType = AVFileType.mp4
        // exporter.shouldOptimizeForNetworkUse = true
        
        // if frameRate != nil {
        //     let videoComposition = AVMutableVideoComposition(propertiesOf: sourceVideoAsset)
        //     videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(frameRate!))
        //     exporter.videoComposition = videoComposition
        // }
        
        // if !isIncludeAudio {
        //     exporter.timeRange = timeRange
        // }
        // */

        // Utility.deleteFile(compressionUrl.absoluteString)
        
        // guard let exportSession = AVAssetExportSession(asset: sourceVideoAsset, presetName: getExportPreset(quality)) else {return}
        // exportSession.outputURL = outputURL
        // exportSession.outputFileType = .mp4

        // let startTime = CMTime(seconds: Double(startTime), preferredTimescale: 1000)
        // let endTime = CMTime(seconds: Double(startTime + duration), preferredTimescale: 1000)
        // let timeRange = CMTimeRange(start: startTime, end: endTime)

        // exportSession.timeRange = timeRange
        
        
        // let timer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(self.updateProgress),
        //                                  userInfo: exporter, repeats: true)
        
        // exporter.exportAsynchronously(completionHandler: {
        //     timer.invalidate()
        //     if(self.stopCommand) {
        //         self.stopCommand = false
        //         var json = self.getMediaInfoJson(path)
        //         json["isCancel"] = true
        //         let jsonString = Utility.keyValueToJson(json)
        //         return result(jsonString)
        //     }
        //     if deleteOrigin {
        //         let fileManager = FileManager.default
        //         do {
        //             if fileManager.fileExists(atPath: path) {
        //                 try fileManager.removeItem(atPath: path)
        //             }
        //             self.exporter = nil
        //             self.stopCommand = false
        //         }
        //         catch let error as NSError {
        //             print(error)
        //         }
        //     }
        //     var json = self.getMediaInfoJson(Utility.excludeEncoding(compressionUrl.path))
        //     json["isCancel"] = false
        //     let jsonString = Utility.keyValueToJson(json)
        //     result(jsonString)
        // })
        // self.exporter = exporter
    }
    
    private func cancelCompression(_ result: FlutterResult) {
        stopCommand = true
        exporter?.cancelExport()
        result("")
    }
    
}
