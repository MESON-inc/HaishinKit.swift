
import Foundation
import AVFoundation
import SwiftUI
import RealityKit
import Metal
import MetalKit
import Spatial

public final class RTMPTexture: HKStreamOutput {
    private var cvMetalTexture: CVMetalTexture?
    private var textureCache: CVMetalTextureCache?
    public let device: (any MTLDevice)?
    private var commandQueue: (any MTLCommandQueue)?
    private var onUpdateMetal:((any MTLTexture)->Void)?
    private var onUpdateImage:((CGImage)->Void)?
    private var onUpdateTextureResource:((TextureResource)->Void)?
    private var isUpdating: Bool = false
    public var currentTexture: (any MTLTexture)?
    public var textureResource: TextureResource?

    public var texture: (any MTLTexture)? {
        return currentTexture
    }
    
    public init() {
        self.device = MTLCreateSystemDefaultDevice()
        self.textureCache = nil
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device!, nil, &textureCache)
    }
    
    public convenience init(onUpdateTextureResource:@escaping (TextureResource)->Void) {
        self.init()
        self.onUpdateTextureResource = onUpdateTextureResource
    }
    
    public convenience init(onUpdateImage:@escaping (CGImage)->Void) {
        self.init()
        self.onUpdateImage = onUpdateImage
    }
    
    public convenience init(onUpdateMetal:@escaping (any MTLTexture)->Void) {
        self.init()
        self.onUpdateMetal = onUpdateMetal
    }
    
    nonisolated public func stream(_ stream: some HKStream, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
    }
    
    nonisolated public func stream(_ stream: some HKStream, didOutput video: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(video) else { return }
        guard let textureCache = textureCache else { return }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvMetalTexture)
        
        guard let cvMetalTexture = cvMetalTexture, let metalTexture = CVMetalTextureGetTexture(cvMetalTexture) else {
            return
        }
                
        if self.currentTexture == nil {
            let textureDescriptor = MTLTextureDescriptor
                .texture2DDescriptor(pixelFormat: metalTexture.pixelFormat,
                                     width: metalTexture.width,
                                     height: metalTexture.height,
                                     mipmapped: false)
            textureDescriptor.usage = .unknown
            self.currentTexture = device!.makeTexture(descriptor: textureDescriptor)
        }
 
        self.currentTexture = metalTexture
        
        if self.commandQueue == nil {
            self.commandQueue = device!.makeCommandQueue()
        }
        
        guard let commandQueue = self.commandQueue else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        guard let currentTexture = self.currentTexture else { return }
        
        blitEncoder.copy(from: metalTexture,
                         sourceSlice: 0, sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: MTLSizeMake(metalTexture.width, metalTexture.height, metalTexture.depth),
                         to: currentTexture, destinationSlice: 0, destinationLevel: 0,
                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))

        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
//        if self.currentTexture != nil {
//            self.onUpdateMetal?(self.currentTexture!)
//            
//            if self.onUpdateTextureResource != nil && !isUpdating {
//                Task { @MainActor in
//                    makeTextureResource(mtlTexture: self.currentTexture!)
//                }
//            }
//            
//            if self.onUpdateImage != nil {
//                Task { @MainActor in
//                    if let image = makeImage(for: self.currentTexture!) {
//                        onUpdateImage?(image)
//                    }
//                }
//            }
//        }
    }
    
    @MainActor
    public func makeTextureResource(mtlTexture:any MTLTexture) {
        
        isUpdating = true
        defer {
            isUpdating = false
        }
        
        if textureResource == nil {
            let data = Data([0xFF, 0xFF, 0x00, 0xFF])
            let cgImage = createOnePixelCGImage()
            textureResource = try? .generate(from: cgImage!, options: .init(semantic: .color))
            self.onUpdateTextureResource?(textureResource!)
        }
        
        guard let textureResource = textureResource else { return }
        guard let device = device else { return }
        guard let commandQueue = commandQueue else { return }
        
        autoreleasepool {
            
            print("texture: \(mtlTexture.width) \(mtlTexture.height )")
            var drawableQueue: TextureResource.DrawableQueue
            drawableQueue = try! TextureResource.DrawableQueue(.init(pixelFormat: .rgba8Unorm, width: mtlTexture.width, height: mtlTexture.height, usage: [.renderTarget, .shaderRead, .shaderWrite], mipmapsMode: .none))
            drawableQueue.allowsNextDrawableTimeout = true
            textureResource.replace(withDrawables: drawableQueue)

            var drawable: TextureResource.Drawable? = nil
            do {
                drawable = try drawableQueue.nextDrawable()
            } catch {
                print(error)
                return
            }
            
            print("drawable update")
            
            let commandBuffer = commandQueue.makeCommandBuffer()!
            let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder()!
            
            blitCommandEncoder.copy(from: mtlTexture, to: drawable!.texture)
            blitCommandEncoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            
            drawable!.present()
        }
    }
    
    func createOnePixelCGImage() -> CGImage? {
        // ピクセルデータ: RGBの1ピクセルを指定 (例えば赤色のピクセル)
        let pixelData: [UInt8] = [255, 0, 0, 255] // R, G, B, A (RGBAで赤色)

        // 1ピクセルの幅と高さ
        let width = 1
        let height = 1

        // 色空間
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 各コンポーネントのビット数 (RGBAは8ビット)
        let bitsPerComponent = 8
        let bytesPerRow = 4 * width

        // ビットマップコンテキストを作成
        if let context = CGContext(
            data: UnsafeMutableRawPointer(mutating: pixelData),
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue // RGBAの順番
        ) {
            // CGImageをコンテキストから作成
            return context.makeImage()
        }

        return nil
    }
    
    func makeImage(for texture: any MTLTexture) -> CGImage? {
        assert(texture.pixelFormat == .bgra8Unorm)

        let width = texture.width
        let height = texture.height
        let pixelByteCount = 4 * MemoryLayout<UInt8>.size
        let imageBytesPerRow = width * pixelByteCount
        let imageByteCount = imageBytesPerRow * height
        let imageBytes = UnsafeMutableRawPointer.allocate(byteCount: imageByteCount, alignment: pixelByteCount)
        defer {
            imageBytes.deallocate()
        }

        texture.getBytes(imageBytes,
                         bytesPerRow: imageBytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let bitmapContext = CGContext(data: nil,
                                            width: width,
                                            height: height,
                                            bitsPerComponent: 8,
                                            bytesPerRow: imageBytesPerRow,
                                            space: colorSpace,
                                            bitmapInfo: bitmapInfo) else { return nil }
        bitmapContext.data?.copyMemory(from: imageBytes, byteCount: imageByteCount)
        let image = bitmapContext.makeImage()
        return image
    }
}
