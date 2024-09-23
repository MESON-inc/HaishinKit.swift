
import HaishinKit
import MetalKit

@MainActor var connection:RTMPConnection?
@MainActor var stream:RTMPStream?
@MainActor var texture:RTMPTexture?
@MainActor var texturePtr:UnsafeMutableRawPointer?
@MainActor var textureWidth: Int = 0
@MainActor var textureHeight: Int = 0


@MainActor
@_cdecl("rtmpTexture")
public func rtmpTexture() -> UnsafeMutableRawPointer? {
    return texturePtr
}

@MainActor
@_cdecl("rtmpTextureWidth")
public func rtmpTextureWidth() -> Int {
    return textureWidth
}

@MainActor
@_cdecl("rtmpTextureHeight")
public func rtmpTextureHeight() -> Int {
    return textureHeight
}

@_cdecl("rtmpConnect")
public func rtmpConnect(cUrl:UnsafePointer<CChar>, onUpdate:@convention(c)  (UnsafeMutableRawPointer)->Void) {
    let url = String(cString: cUrl)
    Task { @MainActor in
        
        if connection == nil {
            connection = .init()
        }
        if stream == nil {
            stream = .init(connection: connection!)
        }
        
        if texture == nil {
            texture = .init(device: MTLCreateSystemDefaultDevice()!, onUpdateMetal: { texture in
                if texturePtr == nil {
                    texturePtr = Unmanaged.passUnretained(texture).toOpaque()
                }
                onUpdate(texturePtr!)
            })
        }
        
        await stream!.addOutput(texture!)

        do {
            print("connect to \(url)...")
            let response = try await connection!.connect(url)
            print("stream play live")
            try await stream!.play("live")
        } catch RTMPConnection.Error.requestFailed(let response) {
            dump(response)
        } catch RTMPStream.Error.requestFailed(let response) {
            dump(response)
        } catch {
            print(error)
        }
    }
}
