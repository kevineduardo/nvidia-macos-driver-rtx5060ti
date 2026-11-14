// SPDX-License-Identifier: MIT
// Copyright (c) 2026 kevineduardo
// avread.swift <file> <8|10> [raw-out]: AVAssetReader decode (NV12 or P010 asked for), fps, optional raw NV12 dump (8-bit)
import AVFoundation
import Metal
_ = MTLCreateSystemDefaultDevice()
let a = CommandLine.arguments
let url = URL(fileURLWithPath: a[1]); let ten = a[2] == "10"
let out: FileHandle? = a.count > 3 ? { FileManager.default.createFile(atPath: a[3], contents: nil); return FileHandle(forWritingAtPath: a[3]) }() : nil
let sem = DispatchSemaphore(value: 0)
Task {
    let asset = AVURLAsset(url: url)
    let track = try! await asset.loadTracks(withMediaType: .video).first!
    let r = try! AVAssetReader(asset: asset)
    let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: ten ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    o.alwaysCopiesSampleData = false; r.add(o); r.startReading()
    let t0 = Date(); var n = 0
    while let sb = o.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        n += 1
        if let out = out, !ten {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            for p in 0..<2 {
                let base = CVPixelBufferGetBaseAddressOfPlane(pb, p)!, bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, p)
                for y in 0..<(p == 0 ? h : (h + 1) / 2) { out.write(Data(bytes: base + y * bpr, count: p == 0 ? w : (w + 1) & ~1)) }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
    }
    let dt = Date().timeIntervalSince(t0)
    if let e = r.error { print("error: \(e)") }
    print("\(url.lastPathComponent) \(ten ? "10" : "8")-bit out: \(n) frames, status \(r.status.rawValue), \(String(format: "%.0f", Double(n) / dt)) fps")
    sem.signal()
}
sem.wait()
