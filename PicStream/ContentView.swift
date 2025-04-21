import SwiftUI
import PhotosUI
import Photos
import AMSMB2
import UniformTypeIdentifiers

// Struktura reprezentująca element (folder lub plik)
struct FileSystemItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String // Pełna ścieżka SMB, np. "/Folder/plik.txt"
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?

    static func ==(lhs: FileSystemItem, rhs: FileSystemItem) -> Bool {
        return lhs.id == rhs.id // UUID powinno wystarczyć do porównania
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id) // UUID powinno wystarczyć do hashowania
    }
}

// Struktura do śledzenia postępu przesyłania
struct UploadProgress: Identifiable {
    let id = UUID()
    let filename: String
    var progress: Double
    var isCompleted: Bool = false
}

// Struktura do obsługi błędów w Alertach
struct ErrorInfo: Identifiable {
    let id = UUID()
    let message: String
}

struct ContentView: View {
    // MARK: - State Variables
    @State private var serverIP = "192.168.1.230"
    @State private var username = "transfer"
    @State private var password = "123"
    @State private var statusMessage = "" // Do informacji bieżących (nie alertów)
    @State private var smbClient: SMB2Manager?
    @State private var folderContents: [FileSystemItem] = []
    @State private var currentPath: String = "/" // Zawsze zaczyna się od roota "/"
    @State private var isConnected: Bool = false
    @State private var selectedMedia: [PhotosPickerItem] = []
    @State private var isUploading: Bool = false
    @State private var navigationPath = NavigationPath() // Do śledzenia ścieżki w NavigationStack

    // Stany do śledzenia postępu przesyłania
    @State private var uploadProgressItems: [UploadProgress] = []
    @State private var overallProgress: Double = 0.0
    @State private var showProgressView: Bool = false

    // Nowe stany
    @State private var selectedAssets: [PHAsset] = []
    @State private var showImagePicker = false
    @State private var isConnecting: Bool = false // Dla wskaźnika przycisku "Połącz"
    @State private var errorToShow: ErrorInfo? // Do wyświetlania alertów z błędami/ważnymi info

    // Stała nazwa folderu współdzielonego
    private let sharePath = "Zdjęcia z Iphona" // Zmień na nazwę Twojego udziału SMB

    // MARK: - Body
    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 15) { // Zmniejszony spacing
                // Nagłówek
                Text("PicStream")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                    .padding(.top)

                // --- Widok Połączenia ---
                if !isConnected {
                    connectionView
                }
                // --- Widok Przeglądarki Plików ---
                else {
                    fileBrowserView
                }

                // Wyświetlanie statusu (nieinwazyjne)
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.horizontal)
                        .transition(.opacity) // Delikatne pojawienie się/zniknięcie
                }

                Spacer() // Pcha wszystko do góry
            }
            .padding(.horizontal) // Główne paddingi dla VStack
            .background(Color(.systemBackground))
            .onAppear {
                // Inicjalizacja klienta przy starcie (bez łączenia)
                updateSMBClient()
                // Poproś o uprawnienia do biblioteki zdjęć
                requestPhotoLibraryAccess()
            }
            .alert(item: $errorToShow) { errorInfo in
                Alert(title: Text("Informacja"), message: Text(errorInfo.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    // MARK: - Subviews
    private var connectionView: some View {
        VStack(spacing: 15) {
            InputField(iconName: "network", placeholder: "Adres IP serwera", text: $serverIP)
            InputField(iconName: "person.fill", placeholder: "Nazwa użytkownika", text: $username)
            SecureInputField(iconName: "lock.fill", placeholder: "Hasło", text: $password)

            Button(action: {
                Task {
                    isConnecting = true // Pokaż wskaźnik
                    statusMessage = "Łączenie z serwerem..."
                    await connectAndListDirectory() // Użyj nowej funkcji async
                    isConnecting = false // Ukryj wskaźnik
                    // statusMessage zostanie ustawione w connectAndListDirectory
                }
            }) {
                HStack {
                    if isConnecting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .padding(.trailing, 5)
                    }
                    Text(isConnecting ? "Łączenie..." : "Połącz")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isConnecting ? Color.gray : Color.blue) // Zmiana koloru podczas łączenia
                        .cornerRadius(10)
                        .shadow(radius: 5)
                }
            }
            .disabled(isConnecting) // Deaktywuj przycisk podczas łączenia
        }
        .padding(.top) // Dodatkowy odstęp od góry
    }

    private var fileBrowserView: some View {
        VStack {
            // Przycisk "W górę" (jeśli nie jesteśmy w katalogu głównym)
            if currentPath != "/" {
                Button(action: goUpDirectory) { // Użyj ref do funkcji
                    HStack {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(.blue)
                        Text("W górę")
                            .foregroundColor(.blue)
                    }
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }
                .frame(maxWidth: .infinity, alignment: .leading) // Wyrównaj do lewej
                .padding(.bottom, 5)
            }

            // Wybór zdjęć i filmów + Przycisk Przesyłania
            HStack {
                // Przycisk do wyboru zdjęć i filmów
                Button(action: {
                    showImagePicker = true
                }) {
                    HStack {
                        Image(systemName: "photo.on.rectangle.angled")
                            .foregroundColor(.blue)
                        Text("Wybierz media (\(selectedAssets.count))")
                            .foregroundColor(.blue)
                    }
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }
                .disabled(isUploading)

                Spacer()

                if !selectedAssets.isEmpty {
                    Button(action: uploadMedia) {
                        Text(isUploading ? "Przesyłanie..." : "Prześlij")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(EdgeInsets(top: 8, leading: 15, bottom: 8, trailing: 15))
                            .background(isUploading ? Color.gray : Color.green)
                            .cornerRadius(10)
                            .shadow(radius: 3)
                    }
                    .disabled(isUploading)
                }
            }
            .padding(.vertical, 5)

            // Widok postępu przesyłania
            if showProgressView {
                uploadProgressSection
                    .padding(.bottom)
            }

            // Lista folderów i plików
            List(folderContents) { item in
                if item.isDirectory {
                    // Używamy Buttona, aby ręcznie zarządzać ścieżką i nawigacją
                    Button(action: {
                        navigateToFolder(item)
                    }) {
                        FileRow(item: item)
                    }
                } else {
                    FileRow(item: item) // Pliki nie są klikalne
                }
            }
            .listStyle(.plain)
            .navigationTitle(navigationTitle)
            .navigationBarBackButtonHidden(false) // Zawsze pokazuj standardowy przycisk Wstecz
            .refreshable { // Dodano możliwość odświeżania listy
                loadDirectoryContents()
            }
        }
        .sheet(isPresented: $showImagePicker) {
            MultiImagePicker(isPresented: $showImagePicker, selectedAssets: $selectedAssets)
        }
    }

    // Widok sekcji postępu przesyłania
    private var uploadProgressSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Ogólny postęp:")
                Spacer()
                Text("\(Int(overallProgress * 100))%")
            }
            ProgressView(value: overallProgress)
                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                .animation(.easeInOut, value: overallProgress)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(uploadProgressItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.filename)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if item.isCompleted {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else {
                                    Text("\(Int(item.progress * 100))%")
                                        .font(.caption)
                                }
                            }
                            ProgressView(value: item.progress)
                                .progressViewStyle(LinearProgressViewStyle(tint: item.isCompleted ? .green : .blue))
                                .animation(.easeInOut, value: item.progress)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal) // Dodaj padding wewnątrz ScrollView
            }
            .frame(maxHeight: 150) // Ogranicz wysokość
            .background(Color(.systemGray6))
            .cornerRadius(10)
        }
        .transition(.opacity.combined(with: .scale)) // Animacja pojawiania się/znikania
    }

    // Widok wiersza pliku/folderu
    private func FileRow(item: FileSystemItem) -> some View {
        HStack {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundColor(item.isDirectory ? .blue : .gray)
            Text(item.name)
                .foregroundColor(.primary)
            Spacer()
            if item.isDirectory {
                 Image(systemName: "chevron.right") // Wskaźnik dla folderów
                     .foregroundColor(.gray.opacity(0.5))
            } else if let size = item.size {
                Text(formatFileSize(size)) // Użyj funkcji formatującej
                    .foregroundColor(.gray)
                    .font(.caption)
            }
        }
        .padding(.vertical, 5)
    }

    // Komponent pola tekstowego
    private func InputField(iconName: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Image(systemName: iconName)
                .foregroundColor(.gray)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain) // Prostszy styl
                .autocapitalization(.none)
                .disableAutocorrection(true)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    // Komponent bezpiecznego pola tekstowego
    private func SecureInputField(iconName: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Image(systemName: iconName)
                .foregroundColor(.gray)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }


    // MARK: - Helper Properties
    private var navigationTitle: String {
        let lastComponent = currentPath.split(separator: "/").last.map(String.init) ?? sharePath
        return lastComponent == sharePath ? sharePath : lastComponent
    }

    // MARK: - Functions

    private func requestPhotoLibraryAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                if status != .authorized && status != .limited {
                    self.errorToShow = ErrorInfo(message: "Brak uprawnień do biblioteki zdjęć! Sprawdź ustawienia aplikacji.")
                }
            }
        }
    }

    private func updateSMBClient() {
        guard let newURL = URL(string: "smb://\(serverIP)") else {
            self.errorToShow = ErrorInfo(message: "Nieprawidłowy format adresu IP serwera!")
            return
        }
        let newCredential = URLCredential(user: username, password: password, persistence: .forSession)
        self.smbClient = SMB2Manager(url: newURL, credential: newCredential)
        print("SMB Client updated for URL: \(newURL)")
    }

    private func connect() async throws -> SMB2Manager {
        guard let client = smbClient else {
            // Spróbuj utworzyć klienta, jeśli go nie ma
            updateSMBClient()
            guard let newClient = smbClient else {
                 throw NSError(domain: "AppError", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Klient SMB nie mógł zostać zainicjalizowany!"])
            }
            print("Re-initialized SMB Client during connect function.")
            return try await connectShare(client: newClient)
        }

        // Sprawdź, czy połączenie jest aktywne (niestety, biblioteka nie ma łatwego sposobu na to)
        // Najprościej jest spróbować wykonać operację i obsłużyć błąd ponownym połączeniem.
        // Alternatywnie, zawsze łącz się ponownie przed operacją - mniej wydajne, ale bezpieczniejsze.
        // Tutaj wybieramy opcję ponownego połączenia dla pewności.
        print("Attempting to connect/reconnect share: \(sharePath)")
        return try await connectShare(client: client)
    }

    // Pomocnicza funkcja do łączenia z udziałem
    private func connectShare(client: SMB2Manager) async throws -> SMB2Manager {
        do {
            try await client.connectShare(name: sharePath)
            print("Successfully connected to share: \(sharePath)")
            return client
        } catch {
            print("Failed to connect share: \(sharePath). Error: \(error)")
            throw error // Przekaż błąd dalej
        }
    }


    // Prywatna funkcja do pobierania i przetwarzania zawartości
    private func fetchDirectoryContents(at path: String, client: SMB2Manager) async throws -> [FileSystemItem] {
        let contents = try await client.contentsOfDirectory(atPath: path)
        print("Fetched \(contents.count) items for path: \(path)")

        let items = contents.compactMap { item -> FileSystemItem? in
            guard let name = item[.nameKey] as? String,
                  let type = item[.fileResourceTypeKey] as? URLFileResourceType else {
                print("Failed to get name or type for item: \(item)")
                return nil
            }
            // Ignoruj ukryte pliki/foldery zaczynające się od "."
            guard !name.starts(with: ".") else { return nil }

            // Ścieżka jest zawsze względem roota udziału (zaczyna się od /)
            let itemPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            let isDirectory = type == .directory
            let size = item[.fileSizeKey] as? Int64
            let modified = item[.contentModificationDateKey] as? Date

            // print("Mapped item: \(name), path: \(itemPath), isDirectory: \(isDirectory)")
            return FileSystemItem(name: name, path: itemPath, isDirectory: isDirectory, size: size, modified: modified)
        }
        // Sortowanie: foldery najpierw, potem pliki, alfabetycznie
        return items.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory // Foldery pierwsze
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // Zaktualizowana funkcja do ładowania zawartości
    private func loadDirectoryContents() {
        Task {
            let path = self.currentPath // Zachowaj ścieżkę na czas zadania
            print("Starting loadDirectoryContents for path: \(path)")
            do {
                let client = try await connect() // Nawiąż/odśwież połączenie
                DispatchQueue.main.async { statusMessage = "Pobieram zawartość \(path)..." }

                let items = try await fetchDirectoryContents(at: path, client: client)

                DispatchQueue.main.async {
                    // Upewnij się, że aktualizujesz dla właściwej ścieżki (na wypadek szybkiej nawigacji)
                    if self.currentPath == path {
                         self.folderContents = items
                         print("Successfully loaded \(items.count) items into folderContents for \(path)")
                         self.statusMessage = "Pobrano \(items.count) elementów."
                         // Ukryj status po chwili
                         DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                             if self.statusMessage == "Pobrano \(items.count) elementów." {
                                 self.statusMessage = ""
                             }
                         }
                    } else {
                         print("Path changed during load, ignoring results for \(path)")
                    }
                }
            } catch {
                 print("Error loading directory contents for \(path): \(error)")
                 DispatchQueue.main.async {
                    // Upewnij się, że aktualizujesz dla właściwej ścieżki
                    if self.currentPath == path {
                         self.errorToShow = ErrorInfo(message: "Błąd ładowania folderu: \(error.localizedDescription)")
                         self.folderContents = [] // Wyczyść w razie błędu
                         self.statusMessage = "" // Wyczyść status
                    }
                 }
            }
        }
    }

    // Zaktualizowana funkcja do połączenia i wyświetlenia (pierwsze połączenie)
    private func connectAndListDirectory() async {
        // Najpierw zaktualizuj klienta SMB na podstawie pól tekstowych
        updateSMBClient()
        guard smbClient != nil else {
            // Błąd inicjalizacji został już obsłużony w updateSMBClient przez errorToShow
            return
        }

        let initialPath = "/" // Zawsze zaczynamy od roota
        print("Starting connectAndListDirectory for initial path: \(initialPath)")
        do {
            let client = try await connect() // Użyj connect, który obsługuje ponowne połączenie
            DispatchQueue.main.async { statusMessage = "Połączono. Pobieram zawartość..." }

            let items = try await fetchDirectoryContents(at: initialPath, client: client)

            DispatchQueue.main.async {
                self.currentPath = initialPath // Ustaw ścieżkę
                self.folderContents = items
                self.statusMessage = "Połączono i pobrano zawartość (\(items.count))."
                self.isConnected = true // Ustaw dopiero po pełnym sukcesie
                self.navigationPath = NavigationPath() // Zresetuj ścieżkę nawigacji
                print("Successfully connected and listed initial directory. isConnected = true")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.statusMessage == "Połączono i pobrano zawartość (\(items.count))." {
                        self.statusMessage = ""
                    }
                }
            }
        } catch {
            print("Error during connectAndListDirectory: \(error)")
            DispatchQueue.main.async {
                self.errorToShow = ErrorInfo(message: "Błąd połączenia: \(error.localizedDescription)")
                self.folderContents = []
                self.isConnected = false // Upewnij się, że jest false
                self.statusMessage = ""
            }
        }
    }

    // Funkcja do nawigacji do folderu
    private func navigateToFolder(_ folder: FileSystemItem) {
        guard folder.isDirectory else { return }
        currentPath = folder.path
        loadDirectoryContents()
        // Dodajemy ścieżkę do nawigacji TYLKO jeśli używamy ścieżek String
        navigationPath.append(folder.path) // Używamy pełnej ścieżki jako identyfikatora nawigacji
        print("Navigated into: \(folder.path), navigationPath count: \(navigationPath.count)")
    }


    // Funkcja do powrotu do folderu nadrzędnego
    private func goUpDirectory() {
        guard currentPath != "/" else { return }

        // Usuń ostatni element ze ścieżki nawigacji, jeśli istnieje
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
            print("Navigated up, removed last path. Current count: \(navigationPath.count)")
        } else {
             print("Warning: Navigated up but navigationPath was already empty.")
        }

        // Oblicz ścieżkę nadrzędną bezpośrednio z currentPath
        let components = currentPath.split(separator: "/").dropLast()
        currentPath = components.isEmpty ? "/" : "/" + components.joined(separator: "/")

        print("Current path after going up: \(currentPath)")
        loadDirectoryContents() // Załaduj zawartość nowego (nadrzędnego) folderu
    }

    // Funkcja do pobierania oryginalnej nazwy pliku z PHAsset
    private func getOriginalFilename(for asset: PHAsset) async -> String? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let resources = PHAssetResource.assetResources(for: asset)
                print("Found \(resources.count) resources for asset")

                if let resource = resources.first {
                    var filename = resource.originalFilename
                    print("Selected resource: type=\(resource.type.rawValue), filename=\(filename)")

                    // Zamień rozszerzenie .HEIC na .jpg
                    if filename.hasSuffix("HEIC") {
                        filename = filename.replacingOccurrences(of: "HEIC", with: "jpg")
                        print("Changed filename from HEIC to jpg: \(filename)")
                    }

                    continuation.resume(returning: filename)
                } else {
                    print("Error: No resources found for asset")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // Funkcja do przesyłania zdjęć i filmów z paskiem postępu
    private func uploadMedia() {
        guard !selectedAssets.isEmpty else {
            errorToShow = ErrorInfo(message: "Wybierz przynajmniej jeden plik do przesłania!")
            return
        }
        guard !isUploading else { return } // Zapobiegaj podwójnemu kliknięciu

        isUploading = true
        showProgressView = true
        uploadProgressItems = [] // Resetuj listę postępu
        overallProgress = 0.0
        statusMessage = "Przygotowuję przesyłanie..."

        Task {
            var uploadedCount = 0
            var mediaToUpload = [(asset: PHAsset, filename: String)]()

            // 1. Przygotuj listę plików i ich nazw
            for asset in selectedAssets {
                if let originalFilename = await getOriginalFilename(for: asset) {
                    mediaToUpload.append((asset, originalFilename))
                    uploadProgressItems.append(UploadProgress(filename: originalFilename, progress: 0.0))
                    print("Using original filename: \(originalFilename)")
                } else {
                    // Fallback: generuj nazwę z odpowiednim rozszerzeniem na podstawie typu mediów
                    var fileExtension = "dat" // Domyślne, rzadko używane
                    var filePrefix = "MEDIA"

                    if asset.mediaType == .image {
                        fileExtension = "jpg"
                        filePrefix = "IMG"
                    } else if asset.mediaType == .video {
                        fileExtension = asset.mediaSubtypes.contains(.videoHighFrameRate) ? "mov" : "mp4"
                        filePrefix = "VID"
                    }

                    let fallbackName = "\(filePrefix)_\(UUID().uuidString.prefix(8)).\(fileExtension)"
                    mediaToUpload.append((asset, fallbackName))
                    uploadProgressItems.append(UploadProgress(filename: fallbackName, progress: 0.0))
                    print("Warning: Could not get original filename. Using fallback: \(fallbackName)")
                }
            }
            print("Prepared \(mediaToUpload.count) items for upload.")

            // 2. Przesyłaj pliki
            do {
                let client = try await connect() // Upewnij się, że mamy połączenie

                for (index, mediaInfo) in mediaToUpload.enumerated() {
                    let (asset, filename) = mediaInfo
                    let targetPath = currentPath == "/" ? "/\(filename)" : "\(currentPath)/\(filename)"

                    print("Attempting to upload: \(filename) to \(targetPath)")

                    // Użyj PHImageManager do uzyskania danych zdjęcia/filmu
                    let manager = PHImageManager.default()
                    let options = PHImageRequestOptions()
                    options.isSynchronous = false
                    options.isNetworkAccessAllowed = true
                    options.deliveryMode = .highQualityFormat

                    if asset.mediaType == .image {
                        let result: Result<Data, Error> = await withCheckedContinuation { continuation in
                            manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                                if let data = data {
                                    continuation.resume(returning: .success(data))
                                } else {
                                    let error = info?[PHImageErrorKey] as? Error ?? NSError(domain: "ImageError", code: -1, userInfo: nil)
                                    continuation.resume(returning: .failure(error))
                                }
                            }
                        }

                        switch result {
                        case .success(let data):
                            print("Loaded data for \(filename), size: \(data.count) bytes.")
                            try await client.write(data: data, toPath: targetPath, progress: { progressValue in
                                // Normalizuj wartość postępu
                                let normalizedProgress = min(max(Double(progressValue) / 100.0, 0.0), 1.0)
                                print("Progress for \(filename): \(progressValue)% -> \(normalizedProgress)")

                                // Aktualizuj postęp dla tego pliku
                                DispatchQueue.main.async {
                                    if index < uploadProgressItems.count {
                                        uploadProgressItems[index].progress = normalizedProgress
                                        let totalProgress = uploadProgressItems.reduce(0.0) { $0 + $1.progress }
                                        overallProgress = totalProgress / Double(uploadProgressItems.count)
                                    }
                                }
                                return true
                            })

                            // Oznacz jako ukończony
                            DispatchQueue.main.async {
                                if index < uploadProgressItems.count {
                                    uploadProgressItems[index].progress = 1.0
                                    uploadProgressItems[index].isCompleted = true
                                    let totalProgress = uploadProgressItems.reduce(0.0) { $0 + $1.progress }
                                    overallProgress = totalProgress / Double(uploadProgressItems.count)
                                }
                            }
                            uploadedCount += 1
                            print("Successfully uploaded \(filename)")
                        case .failure(let error):
                            print("Failed to load data for \(filename): \(error). Skipping.")
                            DispatchQueue.main.async {
                                if index < uploadProgressItems.count {
                                    uploadProgressItems[index].progress = 0.0
                                }
                            }
                        }
                    } else if asset.mediaType == .video {
                        let result: Result<Data, Error> = await withCheckedContinuation { continuation in
                            manager.requestAVAsset(forVideo: asset, options: nil) { avAsset, _, info in
                                guard let avAsset = avAsset else {
                                    let error = info?[PHImageErrorKey] as? Error ?? NSError(domain: "VideoError", code: -1, userInfo: nil)
                                    continuation.resume(returning: .failure(error))
                                    return
                                }

                                // Eksportuj wideo do tymczasowego pliku
                                if let urlAsset = avAsset as? AVURLAsset {
                                    let url = urlAsset.url
                                    do {
                                        let data = try Data(contentsOf: url)
                                        continuation.resume(returning: .success(data))
                                    } catch {
                                        continuation.resume(returning: .failure(error))
                                    }
                                } else {
                                    let exporter = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality)
                                    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).mov")
                                    exporter?.outputURL = tempURL
                                    exporter?.outputFileType = .mov
                                    exporter?.exportAsynchronously {
                                        if exporter?.status == .completed, let data = try? Data(contentsOf: tempURL) {
                                            continuation.resume(returning: .success(data))
                                            try? FileManager.default.removeItem(at: tempURL)
                                        } else {
                                            let error = exporter?.error ?? NSError(domain: "VideoExportError", code: -1, userInfo: nil)
                                            continuation.resume(returning: .failure(error))
                                        }
                                    }
                                }
                            }
                        }

                        switch result {
                        case .success(let data):
                            print("Loaded data for \(filename), size: \(data.count) bytes.")
                            try await client.write(data: data, toPath: targetPath, progress: { progressValue in
                                // Normalizuj wartość postępu
                                let normalizedProgress = min(max(Double(progressValue) / 100.0, 0.0), 1.0)
                                print("Progress for \(filename): \(progressValue)% -> \(normalizedProgress)")

                                // Aktualizuj postęp dla tego pliku
                                DispatchQueue.main.async {
                                    if index < uploadProgressItems.count {
                                        uploadProgressItems[index].progress = normalizedProgress
                                        let totalProgress = uploadProgressItems.reduce(0.0) { $0 + $1.progress }
                                        overallProgress = totalProgress / Double(uploadProgressItems.count)
                                    }
                                }
                                return true
                            })

                            // Oznacz jako ukończony
                            DispatchQueue.main.async {
                                if index < uploadProgressItems.count {
                                    uploadProgressItems[index].progress = 1.0
                                    uploadProgressItems[index].isCompleted = true
                                    let totalProgress = uploadProgressItems.reduce(0.0) { $0 + $1.progress }
                                    overallProgress = totalProgress / Double(uploadProgressItems.count)
                                }
                            }
                            uploadedCount += 1
                            print("Successfully uploaded \(filename)")
                        case .failure(let error):
                            print("Failed to load data for \(filename): \(error). Skipping.")
                            DispatchQueue.main.async {
                                if index < uploadProgressItems.count {
                                    uploadProgressItems[index].progress = 0.0
                                }
                            }
                        }
                    }
                }

                // 3. Zakończenie sukcesem
                DispatchQueue.main.async {
                    overallProgress = 1.0
                    statusMessage = "Przesłano \(uploadedCount) z \(mediaToUpload.count) plików pomyślnie."
                    selectedAssets = []
                    isUploading = false

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        showProgressView = false
                        if statusMessage.starts(with: "Przesłano") {
                            statusMessage = ""
                        }
                    }
                    loadDirectoryContents()
                }
            } catch {
                // 4. Obsługa błędu
                print("Error during upload: \(error)")
                DispatchQueue.main.async {
                    errorToShow = ErrorInfo(message: "Błąd przesyłania pliku: \(error.localizedDescription)")
                    isUploading = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        showProgressView = false
                    }
                    statusMessage = ""
                }
            }
        }
    }
    // Funkcja formatująca rozmiar pliku
    private func formatFileSize(_ size: Int64) -> String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useKB, .useMB, .useGB]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: size)
    }

}

// MARK: - Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
