//
//  MultiImagePicker.swift
//  PicStream
//
//  Created by Michał on 21/04/2025.
//

import SwiftUI
import PhotosUI

struct MultiImagePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var selectedAssets: [PHAsset]

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = 0 // 0 oznacza brak limitu (pozwala wybrać wiele zdjęć/filmów)
        configuration.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: PHPickerViewControllerDelegate {
        let parent: MultiImagePicker

        init(_ parent: MultiImagePicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.isPresented = false
            let identifiers = results.compactMap { $0.assetIdentifier }
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            fetchResult.enumerateObjects { (asset, _, _) in
                self.parent.selectedAssets.append(asset)
            }
            print("Selected assets: \(parent.selectedAssets)")
        }
    }
}
