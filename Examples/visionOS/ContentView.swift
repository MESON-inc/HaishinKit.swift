import SwiftUI
import RealityKit
import HaishinKit

struct ContentView: View {
    @ObservedObject var viewModel = ViewModel()
    @State var texture: RTMPTexture?
    @State var model: ModelEntity?
    @State var image: UIImage?
    private var lfView: PiPHKSwiftUiView!
    
    init() {
        viewModel.config()
        lfView = PiPHKSwiftUiView(rtmpStream: $viewModel.stream)
    }

    var body: some View {
//        VStack {
//            lfView
//                .ignoresSafeArea()
//                .onAppear() {
//                    self.viewModel.startPlaying()
//                }
//                Text("Hello, world!")
//        }

        RealityView { content in
            self.model = ModelEntity(mesh: .generateBox(size: 0.5), materials: [UnlitMaterial(color: .white)])
            content.add(self.model!)
        }
        
//        VStack {
//            if let image = self.image {
//                Image(uiImage: image)
//                    .resizable()
//                    .scaledToFit()
//            }
//        }.frame(width: 500, height: 500)
//        
        .onAppear() {
            Task { @MainActor in
                self.texture = .init(onUpdateTextureResource:onUpdateTextureResource)
                //self.texture = .init(onUpdateImage: onUpdateImage)
                await self.viewModel.stream.addOutput(texture!)
                self.viewModel.startPlaying()
            }
        }
    }
    
    func onUpdateTextureResource(texture: TextureResource) {
        guard let model = self.model else { return }
        guard var modelComponent = self.model?.components[ModelComponent.self] else { return }
        guard var material = modelComponent.materials[0] as? UnlitMaterial else { return }
        material.color = .init(texture: .init(texture))
        modelComponent.materials = [material]
        model.components.set(modelComponent)
    }
    
    func onUpdateImage(image: CGImage) {
        self.image = .init(cgImage: image)
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
}
