
import Foundation
import AVFoundation

public final class RTMPTextureResource: HKStreamOutput {
    var cvMetalTexture: CVMetalTexture?
    var textureCache: CVMetalTextureCache?
    var metalTexture: (any MTLTexture)?
    let device: (any MTLDevice)?
    var onUpdate:(any MTLTexture)->Void
    
    public init(onUpdate:@escaping (any MTLTexture)->Void) {
        self.device = MTLCreateSystemDefaultDevice()
        self.textureCache = nil
        self.onUpdate = onUpdate
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device!, nil, &textureCache)
    }
    
    nonisolated public func stream(_ stream: some HKStream, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
    }
    
    nonisolated public func stream(_ stream: some HKStream, didOutput video: CMSampleBuffer) {
        print("update texture")

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(video) else { return }
        guard let textureCache = textureCache else { return }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvMetalTexture)
        
        guard let cvMetalTexture = cvMetalTexture, let metalTexture = CVMetalTextureGetTexture(cvMetalTexture) else {
            return
        }
        self.metalTexture = metalTexture
        if self.metalTexture != nil {
            self.onUpdate(self.metalTexture!)
        }
    }
}
