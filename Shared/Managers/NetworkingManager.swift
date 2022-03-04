//
//  NetworkingManager.swift
//  FinTune
//
//  Created by Jack Caulfield on 2/7/22.
//

import Foundation
import JellyfinAPI
import CoreData
import Combine
import UIKit

class NetworkingManager : ObservableObject {
    
    static let shared = NetworkingManager()
    
    var cancellables = Set<AnyCancellable>()
    
    let processingQueue = DispatchQueue(label: "JellifyProcessingQueue", attributes: .concurrent)
    
    let imageQueue = DispatchQueue(label: "JellifyImageQueue")
        
    let context : NSManagedObjectContext = PersistenceController.shared.container.viewContext
        
    let privateContext : NSManagedObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
	    
    let sessionId : UUID = UUID()
    
    @Published
    var loadingPhase : LoadingPhase? = nil {
        didSet {
            switch loadingPhase {
            case .artists:
                loadArtists(complete: {

                })
                
                case .albums:
                loadAlbums(complete: {
                    
                })
                    
            case .songs:
                loadSongs(complete: {
                    self.loadPlaylists(complete: {
                        let playlists = self.retrieveAllPlaylistsFromCore()

                        playlists.forEach({ playlist in

                            let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)

                            privateContext.parent = self.context

                            let privatePlaylist = privateContext.object(with: self.retrievePlaylistFromCore(playlistId: playlist.jellyfinId!)!) as! Playlist

                            self.loadPlaylistItems(playlist: privatePlaylist, context: privateContext, complete: {
                                
                                do {
                                    try privateContext.save()

                                    if playlist == playlists.last! {
                                            self.saveContext()
                                            print("Loading complete!")
                                        
                                        DispatchQueue.main.async {
                                            self.loadingPhase = nil
                                            self.libraryIsPopulated = true
                                        }
										self.processDownloadQueue()
                                    }
                                } catch {
									self.saveContext()
									print("Loading complete!")
                                    DispatchQueue.main.async {
                                        self.loadingPhase = nil
                                        self.libraryIsPopulated = true
                                    }
									self.processDownloadQueue()
                                }
                            })
                        })
                    })
                }, startIndex: 0, retrievedSongIds: [])
                    
//            case .playlists:
//                loadPlaylists(complete: {
//
//                })
            default:
                print("Sync finished")
            }
        }
    }
    
    @Published
    var libraryIsPopulated = false
    
    @Published
    var userIsLoggedIn = false
    
    init() {
        privateContext.parent = context
        
        JellyfinAPI.basePath = server
        
        if (userId != "") {
            setCustomHeaders()
            userIsLoggedIn = true
        }
        
        libraryIsPopulated = libraryIsPopulatedWithAtLeastSomething()
    }
    
    var user: User? {
        let userRequest: NSFetchRequest<User> = User.fetchRequest()
        
        return try! self.context.fetch(userRequest).first ?? nil
    }
    
    public var _server: String = ""
    
    public var server: String {
        if _server != ""{
            return _server
        }
        let userRequest: NSFetchRequest<User> = User.fetchRequest()
        do {
            let users = try self.context.fetch(userRequest)
            if users.isEmpty{
                return ""
            }else{
                _server = users[0].server!
                return users[0].server!
            }
        }catch{
            return ""
        }
    }
    
    public var _accessToken: String = ""
    
    public var accessToken: String {
        if _accessToken != ""{
            return _accessToken
        }
        let userRequest: NSFetchRequest<User> = User.fetchRequest()
        do {
            let users = try self.context.fetch(userRequest)
            if users.isEmpty{
                return ""
            }else{
                _accessToken = users[0].authToken!
                return users[0].authToken!
            }
        }catch{
            return ""
        }
    }
    
    public var _userId: String = ""
    public var userId: String {
        if _userId != "" {
            return _userId
        }
        let userRequest: NSFetchRequest<User> = User.fetchRequest()
        do {
            let users = try self.context.fetch(userRequest)
            if users.isEmpty{
                return ""
            }else{
                _userId = users[0].userId!
                return users[0].userId!
            }
        }catch{
            return ""
        }
    }
    
    public var _libraryId: String = ""
    public var libraryId:String {
        if _libraryId != "" {
            return _libraryId
        }
        let userRequest: NSFetchRequest<User> = User.fetchRequest()
        do {
            let users = try self.context.fetch(userRequest)
            if users.isEmpty{
                return ""
            }else{
                _libraryId = users[0].musicLibraryId ?? ""
                return users[0].musicLibraryId ?? ""
            }
        }catch{
            return ""
        }
    }
    
    public var _playlistId: String = ""
    public var playlistId: String {
        if _playlistId != ""{
            return _playlistId
        }
        let userRequest: NSFetchRequest<User> = User.fetchRequest()
        do {
            let users = try self.context.fetch(userRequest)
            if users.isEmpty{
                return ""
            }else{
                _playlistId = users[0].playlistLibraryId ?? ""
                return users[0].playlistLibraryId ?? ""
            }
        }catch{
            return ""
        }
    }
    
    public func syncing() -> Bool {
        return loadingPhase != nil
    }
    
    public func libraryIsPopulatedWithAtLeastSomething() -> Bool {
        self.retrieveAllSongsFromCore().count > 0
    }
    
    public func addToPlaylist(playlist: Playlist, song: Song, complete: @escaping () -> Void) -> Void {
        
        print("Adding \(song.name!) to playlist \(playlist.name!)")
        
        let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        
        privateContext.parent = self.context
        
        let privatePlaylist = privateContext.object(with: self.retrievePlaylistFromCore(playlistId: playlist.jellyfinId!)!) as! Playlist

        PlaylistsAPI.addToPlaylist(playlistId: playlist.jellyfinId!, ids: [song.jellyfinId!], userId: self.userId, apiResponseQueue: JellyfinAPI.apiResponseQueue)
            .sink(receiveCompletion: { completion in
                print("Call to add song to playlist complete: \(completion)")
            }, receiveValue: { response in
                print("Playlist addition response: \(response)")
                
                if playlist.songs != nil {

                    privatePlaylist.songs!.forEach({ playlistSong in
                        privateContext.delete(playlistSong as! NSManagedObject)
                        try! privateContext.save()
                    })

                }
				
                self.loadPlaylistItems(playlist: privatePlaylist, context: privateContext, complete: {
                    print("Playlist addition and refresh")

					if privatePlaylist.downloaded && !song.downloaded {
						DownloadManager.shared.download(song: song)
					}
					
                    try! privateContext.save()

                    self.saveContext()
					
                    complete()
                })
            })
            .store(in: &cancellables)
    }

    public func createPlaylist(name: String, songs: [Song], complete: @escaping () -> Void) -> Void {
                
        var dto = CreatePlaylistDto()
        
        dto.userId = self.userId
        dto.name = name
        dto.ids = songs.map { $0.jellyfinId! }
        dto.mediaType = "Audio"
        
        PlaylistsAPI.createPlaylist(createPlaylistDto: dto, apiResponseQueue: processingQueue)
            .sink(receiveCompletion: { completion in
                print("Creating playlist receive completion: \(completion)")
            }, receiveValue: { response in
                
                let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
                
                privateContext.parent = self.context
                
                let newPlaylist = Playlist(context: privateContext)
                
                newPlaylist.jellyfinId = response.id
                newPlaylist.name = name
                                
                self.loadPlaylistItems(playlist: newPlaylist, context: privateContext, complete: {
                    
                    try! privateContext.save()
                    
                    self.saveContext()
                    
                    complete()
                })
            })
            .store(in: &self.cancellables)
    }
    
    public func deletePlaylist(playlist: Playlist) -> Void {
        print("Deleting playlist \(playlist.name!)")
        
        LibraryAPI.deleteItem(itemId: playlist.jellyfinId!, apiResponseQueue: processingQueue)
            .sink(receiveCompletion: { completion in
                switch completion {
                case .finished :
                    
                    self.deletePlaylists(playlistsToDelete: [playlist])
                    
                    self.saveContext()
                case .failure:
                    print("Error deleting playlist: \(completion)")
                }

            }, receiveValue: { response in
                
            })
            .store(in: &cancellables)
    }
    
    public func deleteFromPlaylist(playlist: Playlist, indexSet: IndexSet) -> Void {
        
		// For some reason pulling the index out of the index set is always off by one
		let indexToRemove = playlist.songs?.count == indexSet.last! + 1 ? indexSet.last! : indexSet.last! + 1
        
        if var playlistSongs = playlist.songs?.allObjects as? [PlaylistSong]{
            let remainingPlaylistSongIds = playlistSongs.filter { indexToRemove != $0.indexNumber }.map { $0.jellyfinId! }
            
                                
            let playlistSongIdsToRemove = (playlist.songs!.allObjects as! [PlaylistSong]).map { $0.jellyfinId! }.filter { !remainingPlaylistSongIds.contains($0)}
			
			print("Removing songs \((playlist.songs!.allObjects as! [PlaylistSong]).filter({ playlistSongIdsToRemove.contains($0.jellyfinId!)}).map({ $0.song!.name!}).joined(separator: ", "))")
                    
            PlaylistsAPI.removeFromPlaylist(playlistId: playlist.jellyfinId!, entryIds: playlistSongIdsToRemove, apiResponseQueue: JellyfinAPI.apiResponseQueue)
                .sink(receiveCompletion: { completion in
                    print("Call to remove song from playlist complete: \(completion)")
                }, receiveValue: { response in

					playlistSongIdsToRemove.forEach({ playlistSongId in
						self.deletePlaylistSongByJellyfinId(playlistSongId: playlistSongId, context: self.context)
					})
					
					for case let playlistSong as PlaylistSong in playlist.songs! {
						if playlistSong.indexNumber > indexToRemove {
							playlistSong.indexNumber -= 1
						}
					}
                })
                .store(in: &cancellables)
        }
    }
    
    public func favoriteItem(jellyfinId: String, originalValue: Bool?, complete: @escaping (Bool) -> Void) -> Void {
        UserLibraryAPI.markFavoriteItem(userId: self.userId, itemId: jellyfinId)
            .sink(receiveCompletion: { complete in
                print("Favorite item: \(complete)")
            }, receiveValue: { response in
                complete(response.isFavorite ?? originalValue ?? false)
            })
            .store(in: &self.cancellables)
    }
    
    public func unfavorite(jellyfinId: String, originalValue: Bool?, complete: @escaping (Bool) -> Void) -> Void {
        UserLibraryAPI.unmarkFavoriteItem(userId: self.userId, itemId: jellyfinId)
            .sink(receiveCompletion: { complete in
                print("Unfavorite item: \(complete)")
            }, receiveValue: { response in
                complete(response.isFavorite ?? originalValue ?? false)
            })
            .store(in: &self.cancellables)
    }
    
    public func moveInPlaylist(playlist: Playlist, indexSet: IndexSet, newIndex: Int) {
    
        let oldIndex = indexSet.first!
        let updatedIndex = newIndex == 0 || newIndex <= oldIndex ? newIndex : newIndex - 1
                
        let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        
        privateContext.parent = self.context
        
        let privatePlaylist = privateContext.object(with: self.retrievePlaylistFromCore(playlistId: playlist.jellyfinId!)!) as! Playlist
        
        let playlistSong = playlist.songs?.sortedArray(using: [NSSortDescriptor(key: #keyPath(PlaylistSong.indexNumber), ascending: true)])[oldIndex] as? PlaylistSong
        
        for index in indexSet {
            print(index)
            print(updatedIndex)
        }
        
        print("Moving song \(playlistSong!.song!.name!) to index \(updatedIndex) from \(oldIndex)")
        
        if let playlistSongs : [PlaylistSong] = playlist.songs?.map({ $0 as! PlaylistSong }) {

            playlistSongs.forEach({ song in
                
                if song.jellyfinId! != playlistSong!.jellyfinId! {
                    
                    let songToShift = privateContext.object(with: self.retrievePlaylistSongFromCore(playlistSongId: song.jellyfinId!)!) as! PlaylistSong

                    // If moving song forward in playlist...
                    if updatedIndex < oldIndex {

                        // Bump the index number of each song that will come after the playlist song's new position,
                        // and fill up the gap to where the playlist song used to be
                        if songToShift.indexNumber >= updatedIndex && songToShift.indexNumber < oldIndex {
                            
                            songToShift.indexNumber += 1
                        }
                    }

                    // Else we're moving the song back...
                    else {
                        if songToShift.indexNumber <= updatedIndex && songToShift.indexNumber > oldIndex {
                            songToShift.indexNumber -= 1
                        }
                    }
                    
                    try! privateContext.save()
                } else {
                    playlistSong?.indexNumber = Int16(updatedIndex)
                }
            })
        }
        
        PlaylistsAPI.moveItem(playlistId: playlist.jellyfinId!, itemId: playlistSong!.jellyfinId!, newIndex: updatedIndex)
            .sink(receiveCompletion: { completion in
                switch completion {
                case .finished:
                    print("Playlist item moved")
                    self.saveContext()
                case .failure:
                    print("Playlist item move failed")
                }
            }, receiveValue: { response in
//                if playlist.songs != nil {
//
//                    privatePlaylist.songs!.forEach({ playlistSong in
//                        privateContext.delete(playlistSong as! NSManagedObject)
//                        try! privateContext.save()
//                    })
//
//                }
//                self.loadPlaylistItems(playlist: privatePlaylist, context: privateContext, complete: { playlistSongs in
//                    print("Playlist addition and refresh")
//
//                    playlistSongs.forEach({ playlistSong in
//                        privatePlaylist.addToSongs(playlistSong)
//                    })
//
//                    try! privateContext.save()
//
//                    self.saveContext()
//                })
            })
            .store(in: &self.cancellables)
    }
    
    public func retrieveArtistByJellyfinId(jellyfinId: String) -> Artist? {
        return self.context.object(with: self.retrieveArtistFromCoreById(jellyfinId: jellyfinId)!) as? Artist
    }
    
	public func retrieveArtistByName(name: String, context: NSManagedObjectContext) -> Artist? {
        return context.object(with: self.retrieveArtistFromCore(artistName: name)!) as? Artist
    }

    public func loadAlbumArtwork(album: Album) -> Void {
                
		ImageAPI.getItemImage(itemId: album.jellyfinId!, imageType: .primary, apiResponseQueue: DispatchQueue.global(qos: .utility))
            .sink(receiveCompletion: { completion in
                print("Image receive completion: \(completion)")
            }, receiveValue: { url in
                      
                do {

                    album.artwork = try Data(contentsOf: url)
                    album.thumbnail = try Data(contentsOf: url)
                                        
                    self.saveContext()
                } catch {
                    print("Error setting artwork for album: \(album.name!)")
                }                
            })
            .store(in: &self.cancellables)

    }
    
    public func loadArtistImage(artist: Artist) -> Void {
                
        ImageAPI.getItemImage(itemId: artist.jellyfinId!, imageType: .primary, apiResponseQueue: imageQueue)
            .sink(receiveCompletion: { completion in
                print("Artist image receive completion: \(completion)")
            }, receiveValue: { url in
                               
                do {
                    artist.thumbnail = try Data(contentsOf: url)
                    
                     self.saveContext()
                } catch {
                    print("Error setting thumbnail for artist: \(artist.name!)")
                    
                    artist.thumbnail = nil
                }
            })
            .store(in: &self.cancellables)
    }
    
    public func loadPlaylistImage(playlist: Playlist) -> Void {
        ImageAPI.getItemImage(itemId: playlist.jellyfinId!, imageType: .primary, apiResponseQueue: imageQueue)
            .sink(receiveCompletion: { completion in
                print("Artist image receive completion: \(completion)")
            }, receiveValue: { url in
                                
                let privateContext : NSManagedObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
                
                privateContext.parent = self.privateContext
                
                let privatePlaylist = privateContext.object(with: playlist.objectID) as! Playlist

                privatePlaylist.thumbnail = try! Data(contentsOf: url)
                
                try! privateContext.save()
                 
                self.saveContext()
            })
            .store(in: &self.cancellables)
    }
    
    // TODO: Hash password to SHA-1
    public func login(serverUrl: String, userId: String, password: String, complete: @escaping () -> Void) -> Void {
        
        print("logging in")
        JellyfinAPI.basePath = serverUrl
        setAuthHeaders()
        
        var dto = AuthenticateUserByName()
        
        dto.username = userId
        dto.pw = password
        
        UserAPI.authenticateUserByName(authenticateUserByName: dto, apiResponseQueue: processingQueue)
            .sink(receiveCompletion: { complete in
                print("Login completion: \(complete)")
            }, receiveValue: { response in
                let user : User = User(context: self.privateContext)
                
                user.userId = response.user!.id!
                user.server = serverUrl
                user.authToken = response.accessToken
                user.serverId = response.serverId
                
                self.saveContext()
                
                self.setCustomHeaders()
                
                self.userIsLoggedIn = true
                
                complete()
            })
            .store(in: &cancellables)
    }
    
    public func logOut() -> Void {
        
        SessionAPI.reportSessionEnded()
            .sink(receiveCompletion: { complete in
                print("Logout request: \(complete)")
            }, receiveValue: {
                
                DispatchQueue.main.async {
                    Player.shared.isPlaying = false
                    Player.shared.songs.removeAll()
                }
                
                self.cancellables.forEach({ cancellable in
                    cancellable.cancel()
                })
                
                self.loadingPhase = nil
                
                self.deleteAllOfEntity(entityName: "User")
                self.deleteAllOfEntity(entityName: "PlaylistSong")
                self.deleteAllOfEntity(entityName: "Song")
                self.deleteAllOfEntity(entityName: "Album")
                self.deleteAllOfEntity(entityName: "Artist")
                self.deleteAllOfEntity(entityName: "Playlist")
                self.deleteAllOfEntity(entityName: "Genre")
                self._server = ""
                self._userId = ""
                self._accessToken = ""
                self._playlistId = ""
                self._libraryId = ""
                                
                self.userIsLoggedIn = false
                
                self.saveContext()
            })
            .store(in: &self.cancellables)
    }
    
    public func openSession() -> Void {
                        
        SessionAPI.getSessions(controllableByUserId: self.userId, deviceId: UIDevice.current.identifierForVendor!.uuidString, apiResponseQueue: self.processingQueue)
            .sink(receiveCompletion: { complete in
                print("Session started: \(complete)")
            }, receiveValue: { response in
                print("Started session for user successfully")
            })
            .store(in: &self.cancellables)
    }
    
    public func processDownloadQueue() -> Void {
        
        self.retrievePlaylistsToDownload().forEach({ playlist in
			
			DownloadManager.shared.download(playlist: playlist)
            
        })
		
		self.retrieveAlbumsToDownload().forEach({ album in
			DownloadManager.shared.download(album: album)
		})
        
		DownloadManager.shared.download(songs: self.retrieveSongsToDownload())
    }

    public func syncLibrary() -> Void {
                
        print("Starting Sync")
        
        // By setting the loading phase to artists, this will cascade a sync of all items
        self.loadingPhase = .artists
    }
    
    private func deleteAllEntities() -> Void {
        
        deleteAllOfEntity(entityName: "PlaylistSong")
        deleteAllOfEntity(entityName: "Song")
        deleteAllOfEntity(entityName: "Album")
        deleteAllOfEntity(entityName: "Playlist")
        deleteAllOfEntity(entityName: "Artist")
        
        saveContext()
    }
    
    private func deleteAllOfEntity(entityName: String) -> Void {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: entityName)
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

        do {
            try self.privateContext.execute(deleteRequest)
        } catch let error as NSError {
            // TODO: handle the error
            print(error)
        }
    }
    
    private func deletePlaylists(playlistsToDelete: [Playlist]) -> Void {
        playlistsToDelete.forEach({ playlist in
            
            if let playlistSongs = playlist.songs?.allObjects as? [PlaylistSong] {

                playlistSongs.forEach({ playlistSong in
                    self.privateContext.delete(self.privateContext.object(with: self.retrievePlaylistSongFromCore(playlistSongId: playlistSong.jellyfinId!)!))
                })
            }
                        
            self.privateContext.delete(self.privateContext.object(with: self.retrievePlaylistFromCore(playlistId: playlist.jellyfinId!)!))
            self.saveContext()
        })
    }

    
    private func loadArtists(complete: @escaping () -> Void) -> Void {
		ArtistsAPI.getArtists(minCommunityRating: nil, startIndex: nil, limit: nil, searchTerm: nil, parentId: nil, fields: [ItemFields.primaryImageAspectRatio, ItemFields.sortName, ItemFields.basicSyncInfo], excludeItemTypes: nil, includeItemTypes: nil, filters: nil, isFavorite: nil, mediaTypes: nil, genres: nil, genreIds: nil, officialRatings: nil, tags: nil, years: nil, enableUserData: true, imageTypeLimit: nil, enableImageTypes: nil, person: nil, personIds: nil, personTypes: nil, studios: nil, studioIds: nil, userId: self.userId, nameStartsWithOrGreater: nil, nameStartsWith: nil, nameLessThan: nil, enableImages: true, enableTotalRecordCount: nil, apiResponseQueue: processingQueue)
            .sink(receiveCompletion: { error in
                switch error {
                case .finished :
                    
					self.saveContext()
					
                    DispatchQueue.main.sync {
                        self.loadingPhase = .albums
                    }
                case .failure:
                    print("Error retrieving artists: \(error)")
                    
                    DispatchQueue.main.sync {
                        self.loadingPhase = nil
                    }
                }
                
            }, receiveValue: { response in

                if response.items != nil {
                    
                    // Check if there are any artists we should remove
                    self.privateContext.perform {
                        
                        let retrievedArtistIds = response.items!.map({ $0.id! })
                        
                        self.deleteMissingArtists(retrievedArtistIds: retrievedArtistIds)
                        
                        response.items!.forEach({ artistResult in
                            
                            var artist : Artist? = nil
                            
                            if (self.retrieveArtistFromCore(artistName: artistResult.name!) != nil) {
                                artist = self.privateContext.object(with: self.retrieveArtistFromCore(artistName: artistResult.name!)!) as! Artist?
                            }
                                // Check if artist already exists in store
                            if artist == nil {
                                artist = Artist(context: self.privateContext)
                                
                                artist!.jellyfinId = artistResult.id!
                            }
                            
                            artist!.name = artistResult.name ?? "Unknown Artist"
                            artist!.dateCreated = artistResult.dateCreated?.formatted() ?? ""
                            artist!.overview = artistResult.overview
                            artist!.sortName = artistResult.sortName ?? artistResult.name!
                            artist!.favorite = artistResult.userData?.isFavorite ?? artist?.favorite ?? false
                        })
                    }
                }
            })
            .store(in: &cancellables)

    }
    
    private func loadAlbums(complete: @escaping () -> Void) -> Void {
        ItemsAPI.getItemsByUserId(userId: self.userId, maxOfficialRating: nil, hasThemeSong: nil, hasThemeVideo: nil, hasSubtitles: nil, hasSpecialFeature: nil, hasTrailer: nil, adjacentTo: nil, parentIndexNumber: nil, hasParentalRating: nil, isHd: nil, is4K: nil, locationTypes: nil, excludeLocationTypes: nil, isMissing: nil, isUnaired: nil, minCommunityRating: nil, minCriticRating: nil, minPremiereDate: nil, minDateLastSaved: nil, minDateLastSavedForUser: nil, maxPremiereDate: nil, hasOverview: nil, hasImdbId: nil, hasTmdbId: nil, hasTvdbId: nil, excludeItemIds: nil, startIndex: nil, limit: nil, recursive: true, searchTerm: nil, sortOrder: nil, parentId: nil, fields: [ItemFields.sortName], excludeItemTypes: nil, includeItemTypes: ["MusicAlbum"], filters: nil, isFavorite: nil, mediaTypes: nil, imageTypes: nil, sortBy: nil, isPlayed: nil, genres: nil, officialRatings: nil, tags: nil, years: nil, enableUserData: true, imageTypeLimit: nil, enableImageTypes: nil, person: nil, personIds: nil, personTypes: nil, studios: nil, artists: nil, excludeArtistIds: nil, artistIds: nil, albumArtistIds: nil, contributingArtistIds: nil, albums: nil, albumIds: nil, ids: nil, videoTypes: nil, minOfficialRating: nil, isLocked: nil, isPlaceHolder: nil, hasOfficialRating: nil, collapseBoxSetItems: nil, minWidth: nil, minHeight: nil, maxWidth: nil, maxHeight: nil, is3D: nil, seriesStatus: nil, nameStartsWithOrGreater: nil, nameStartsWith: nil, nameLessThan: nil, studioIds: nil, genreIds: nil, enableTotalRecordCount: nil, enableImages: nil, apiResponseQueue: processingQueue)
            .sink(receiveCompletion: { completion in
                switch completion {
                case .finished :
                    print("Finished album retrieval")
					self.saveContext()
                    DispatchQueue.main.sync {
                        self.loadingPhase = .songs
                    }
                case .failure:
                    print("Error retrieving artists: \(completion)")
                    
                    DispatchQueue.main.sync {
                        self.loadingPhase = nil
                    }
                }
            }, receiveValue: { response in
                if response.items != nil {
                    
                    let albumIds = response.items!.map { $0.id! }
                    
                    self.deleteMissingAlbums(retrievedAlbumIds: albumIds)
					
					self.saveContext()
                    
                    let existingAlbumIds = Set(self.retrieveAllAlbumsFromCore()).map({ $0.jellyfinId! })
                                        
                    var albumIdsSet = Set(response.items!.map { $0.id! })
                                                
                    albumIdsSet.subtract(existingAlbumIds)
                    
                    let newAlbums = response.items!.filter { albumIdsSet.contains($0.id! )}
                    
					DispatchQueue.concurrentPerform(iterations: response.items!.count) { index in

                        let privateContext : NSManagedObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
                        
                        privateContext.parent = self.privateContext

						let albumResult = response.items![index]
                        
                        print("Album \(index) of \(response.items!.count)")
                        
                        var album : Album?
                        
                        if (self.retrieveAlbumFromCore(albumId: albumResult.id!) == nil) {
                            
                            album = Album(context: privateContext)
                            
                            album!.jellyfinId = albumResult.id!
                        } else {
                            album = privateContext.object(with: self.retrieveAlbumFromCore(albumId: albumResult.id!)!) as? Album
                        }
                        
                        album!.name = albumResult.name!
                        album!.sortName = albumResult.sortName ?? albumResult.name!
                        album!.productionYear = Int16(albumResult.productionYear ?? 0)
                        album!.favorite = albumResult.userData?.isFavorite ?? album?.favorite ?? false
                        
                        // Run Time?
                        
                        var artist : Artist? = nil
                        
                        if (albumResult.albumArtist != nil) {
                            
                            if (self.retrieveArtistFromCore(artistName: albumResult.albumArtist!) != nil) {
                                artist = privateContext.object(with: self.retrieveArtistFromCore(artistName: albumResult.albumArtist!)!) as! Artist?
                            }
                        }
                        
                        if (artist != nil) {
							album!.albumArtistName = albumResult.albumArtist!
                            
                            self.retrieveArtistsFromCoreByJellyfinIds(jellyfinIds: albumResult.albumArtists!.map { $0.id! }).forEach({ artistObjectId in
                                album!.addToAlbumArtists(privateContext.object(with: artistObjectId) as! Artist)
                            })
                        }
                        
                        try! privateContext.save()
                    }
                    
                    self.saveContext()
                    complete()
                } else {
                    complete()
                }
            })
            .store(in: &self.cancellables)
        }
        
    private func loadSongs(complete: @escaping () -> Void, startIndex: Int?, retrievedSongIds: [String]?) -> Void {
        ItemsAPI.getItemsByUserId(userId: self.userId, maxOfficialRating: nil, hasThemeSong: nil, hasThemeVideo: nil, hasSubtitles: nil, hasSpecialFeature: nil, hasTrailer: nil, adjacentTo: nil, parentIndexNumber: nil, hasParentalRating: nil, isHd: nil, is4K: nil, locationTypes: nil, excludeLocationTypes: nil, isMissing: nil, isUnaired: nil, minCommunityRating: nil, minCriticRating: nil, minPremiereDate: nil, minDateLastSaved: nil, minDateLastSavedForUser: nil, maxPremiereDate: nil, hasOverview: nil, hasImdbId: nil, hasTmdbId: nil, hasTvdbId: nil, excludeItemIds: nil, startIndex: startIndex, limit: Globals.API_FETCH_PAGE_SIZE, recursive: true, searchTerm: nil, sortOrder: nil, parentId: nil, fields: [ItemFields.sortName, ItemFields.mediaSources], excludeItemTypes: nil, includeItemTypes: ["Audio"], filters: nil, isFavorite: nil, mediaTypes: nil, imageTypes: nil, sortBy: nil, isPlayed: nil, genres: nil, officialRatings: nil, tags: nil, years: nil, enableUserData: true, imageTypeLimit: nil, enableImageTypes: nil, person: nil, personIds: nil, personTypes: nil, studios: nil, artists: nil, excludeArtistIds: nil, artistIds: nil, albumArtistIds: nil, contributingArtistIds: nil, albums: nil, albumIds: nil, ids: nil, videoTypes: nil, minOfficialRating: nil, isLocked: nil, isPlaceHolder: nil, hasOfficialRating: nil, collapseBoxSetItems: nil, minWidth: nil, minHeight: nil, maxWidth: nil, maxHeight: nil, is3D: nil, seriesStatus: nil, nameStartsWithOrGreater: nil, nameStartsWith: nil, nameLessThan: nil, studioIds: nil, genreIds: nil, enableTotalRecordCount: nil, enableImages: false, apiResponseQueue: processingQueue)
                .sink(receiveCompletion: { completion in
                    switch completion {
                    case .finished :
                        print("Finished song retrieval at \(startIndex ?? 0)")
//                        self.saveContext()
                    case .failure:
                        print("Error retrieving artists: \(completion)")
                        
                        DispatchQueue.main.sync {
                            self.loadingPhase = nil
                        }
                    }
                    
                }, receiveValue: { response in

                    
                    if response.items != nil {
                        
                        var songIds = Set(response.items!.map { $0.id})
                        
                        songIds.subtract(Set(self.retrieveAllSongsFromCore().map { $0.jellyfinId}))
                                                    
                        let newSongs = response.items!.filter { songIds.contains($0.id)}
                        
                        if true {

							DispatchQueue.concurrentPerform(iterations: response.items!.count) { index in
                                                                
								let songResult = response.items![index]
                                
                                print("Song \(index) of \(newSongs.count)")
                                        
                                // TODO: Perform a more thorough comparison so that we update metadata if it's changed
                                if (self.retrieveSongFromCore(songId: songResult.id!) == nil) {
                                    
									let privateContext : NSManagedObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)

									privateContext.parent = self.privateContext
									
									let song = Song(context: privateContext)
									
									song.jellyfinId = songResult.id!
									song.name = songResult.name!
									song.sortName = songResult.sortName ?? songResult.name!
									song.container = songResult.mediaSources![0].container
									song.favorite = songResult.userData?.isFavorite ?? false
									
									// Run Time?
									song.runTimeTicks = songResult.runTimeTicks!
									
									// Check that index number exists so we can unwrap it's value safely
									if songResult.indexNumber != nil {
										song.indexNumber = Int16(songResult.indexNumber!)
									}
									
									// Check that the disk number exists so we can unwrap it's value safely
									if songResult.parentIndexNumber != nil {
										song.diskNumber = Int16(songResult.parentIndexNumber!)
									}
									
									if let albumId = songResult.albumId {
										song.album = privateContext.object(with: self.retrieveAlbumFromCore(albumId: albumId)!) as! Album
									}
									
									if let artistIds = songResult.artistItems?.map({ $0.name }) {
										artistIds.forEach({ artistName in
											song.addToArtists(self.retrieveArtistByName(name: artistName!, context: privateContext)!)
										})
									}
									
									try! privateContext.save()
                                } else {
                                    let privateContext : NSManagedObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)

                                    privateContext.parent = self.privateContext

                                    let song = privateContext.object(with: self.retrieveSongFromCore(songId: songResult.id!)!) as! Song
                                    
                                    song.name = songResult.name!
                                    song.sortName = songResult.sortName ?? songResult.name!
                                    song.container = songResult.mediaSources![0].container
                                    song.favorite = songResult.userData?.isFavorite ?? false
									
									if let albumId = songResult.albumId {
										song.album = privateContext.object(with: self.retrieveAlbumFromCore(albumId: albumId)!) as! Album
									}
									
									if let artistIds = songResult.artistItems?.map({ $0.name }) {
										artistIds.forEach({ artistName in
											song.addToArtists(self.retrieveArtistByName(name: artistName!, context: privateContext)!)
										})
									}
                                    
                                    try! privateContext.save()
                                }
                                
                                // Check if we've gone through everything the server has to offer
								if (songResult == response.items!.last!) {
                                    
                                    // If this response is less than the configured fetch amount, it means the server doesn't
                                    // have more to give and we should complete
                                    if (response.items!.count < Globals.API_FETCH_PAGE_SIZE) {
                                        
                                        self.saveContext()

                                        // Since we've got everything, remove songs that are no longer on the server
                                        self.deleteMissingSongs(retrievedSongIds: retrievedSongIds! + response.items!.map({ $0.id! }))

                                        self.saveContext()
                                        complete()
                                    }
                                    
                                    // Else it means there may be more songs on the server, let's go again!
                                    else {
                                        
                                        var index = Globals.API_FETCH_PAGE_SIZE
                                        
                                        if startIndex != nil {
                                            index += startIndex!
                                        }
                                        
                                        self.saveContext()
                                        
                                        self.loadSongs(complete: {
                                            self.saveContext()
                                            complete()
                                        }, startIndex: index, retrievedSongIds: retrievedSongIds == nil ? response.items!.map({ $0.id! }) : retrievedSongIds! + response.items!.map({ $0.id! }))
                                    }
                                }
                            }
                        } else {
							
							DispatchQueue.concurrentPerform(iterations: response.items!.count, execute: { index in
								let responseItem = response.items![index]
								
								let song = self.privateContext.object(with: self.retrieveSongFromCore(songId: responseItem.id!)!) as! Song
								
								song.name = responseItem.name!
								song.favorite = responseItem.userData?.isFavorite ?? song.favorite
								song.container = responseItem.mediaSources?[0].container ?? song.container
							})
                                
                            // If this response is less than the configured fetch amount, it means the server doesn't
                            // have more to give and we should complete
                            if (response.items!.count < Globals.API_FETCH_PAGE_SIZE) {
                                
                                self.saveContext()
                                
                                // Since we've got everything, remove songs that are no longer on the server
                                self.deleteMissingSongs(retrievedSongIds: retrievedSongIds! + response.items!.map({ $0.id! }))
                                                                
                                self.saveContext()
                                complete()
                            }
                            
                            // Else it means there may be more songs on the server, let's go again!
                            else {
                                
                                var index = Globals.API_FETCH_PAGE_SIZE
                                
                                if startIndex != nil {
                                    index += startIndex!
                                }
                                                                
                                self.loadSongs(complete: {
                                    complete()
                                }, startIndex: index, retrievedSongIds: retrievedSongIds == nil ? response.items!.map({ $0.id! }) : retrievedSongIds! + response.items!.map({ $0.id! }))
                            }
                        }
                        
//                        complete()

                    } else {
                        complete()
                    }
                })
                .store(in: &self.cancellables)
    }
    
    private func loadPlaylists(complete: @escaping () -> Void) -> Void {
        
        ItemsAPI.getItemsByUserId(userId: self.userId, maxOfficialRating: nil, hasThemeSong: nil, hasThemeVideo: nil, hasSubtitles: nil, hasSpecialFeature: nil, hasTrailer: nil, adjacentTo: nil, parentIndexNumber: nil, hasParentalRating: nil, isHd: nil, is4K: nil, locationTypes: nil, excludeLocationTypes: nil, isMissing: nil, isUnaired: nil, minCommunityRating: nil, minCriticRating: nil, minPremiereDate: nil, minDateLastSaved: nil, minDateLastSavedForUser: nil, maxPremiereDate: nil, hasOverview: nil, hasImdbId: nil, hasTmdbId: nil, hasTvdbId: nil, excludeItemIds: nil, startIndex: nil, limit: nil, recursive: true, searchTerm: nil, sortOrder: nil, parentId: self.playlistId, fields: [ItemFields.sortName], excludeItemTypes: nil, includeItemTypes: ["Playlist"], filters: nil, isFavorite: nil, mediaTypes: nil, imageTypes: nil, sortBy: ["SortName"], isPlayed: nil, genres: nil, officialRatings: nil, tags: nil, years: nil, enableUserData: true, imageTypeLimit: nil, enableImageTypes: nil, person: nil, personIds: nil, personTypes: nil, studios: nil, artists: nil, excludeArtistIds: nil, artistIds: nil, albumArtistIds: nil, contributingArtistIds: nil, albums: nil, albumIds: nil, ids: nil, videoTypes: nil, minOfficialRating: nil, isLocked: nil, isPlaceHolder: nil, hasOfficialRating: nil, collapseBoxSetItems: nil, minWidth: nil, minHeight: nil, maxWidth: nil, maxHeight: nil, is3D: nil, seriesStatus: nil, nameStartsWithOrGreater: nil, nameStartsWith: nil, nameLessThan: nil, studioIds: nil, genreIds: nil, enableTotalRecordCount: nil, enableImages: nil, apiResponseQueue: processingQueue)
            .sink(receiveCompletion: { completion in
                print("Playlist retrieval: \(completion)")
            }, receiveValue: { response in
                
                if response.items != nil {
                    
                    // Remove old items that don't exist on the server anymore
                    let jellyfinPlaylistIds = response.items!.map { $0.id! }
                    
                    let playlistsToDelete = self.retrieveAllPlaylistsFromCore().filter { !jellyfinPlaylistIds.contains($0.jellyfinId!) }
                    
                    self.deletePlaylists(playlistsToDelete: playlistsToDelete)
                    
                    DispatchQueue.concurrentPerform(iterations: response.items!.count, execute: { index in
                        
                        let playlistResult = response.items![index]
                        
                        let privateContext : NSManagedObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)

                        privateContext.parent = self.privateContext
                        
                        print("Processing playlist: \(playlistResult.name!)")
                                                
                        if (self.retrievePlaylistFromCore(playlistId: playlistResult.id!) == nil) {
                                
                            let playlist = Playlist(context: privateContext)
                            
                            playlist.jellyfinId = playlistResult.id!
                            playlist.name = playlistResult.name!
                            playlist.sortName = playlistResult.sortName ?? playlist.name!
                            playlist.favorite = playlistResult.userData?.isFavorite ?? false
                            
                            try! privateContext.save()
                        } else {
                            
                            let playlist = privateContext.object(with: self.retrievePlaylistFromCore(playlistId: playlistResult.id!)!) as! Playlist
                            
                            // Update the name if it's changed
                            playlist.name = playlistResult.name!
                            playlist.sortName = playlistResult.sortName ?? playlist.name!
                            playlist.favorite = playlistResult.userData?.isFavorite ?? playlist.favorite
                        }
                                                
                        try! privateContext.save()
                        
                        if playlistResult == response.items!.last {
                            print("Playlist import complete")
                            self.saveContext()
                            complete()
                        } else {
                            print("Preparing for next new playlist")
                        }
                    })
                } else {
                    complete()
                }
            })
            .store(in: &self.cancellables)
    }
    
    /**
     Loads a playlist's tracks from the API and associates them with the playlist, adding new tracks, removing old tracks, and updating index numbers
     */
    private func loadPlaylistItems(playlist: Playlist, context: NSManagedObjectContext, complete: @escaping () -> Void) -> Void {
        PlaylistsAPI.getPlaylistItems(playlistId: playlist.jellyfinId!, userId: self.userId, apiResponseQueue: self.processingQueue)
        .sink(receiveCompletion: { complete in
            print("Playlist song retrieval for playlist \(playlist.name): \(complete)")
        }, receiveValue: { playlistItems in
            if playlistItems.items != nil {
                
                // Build dictionary of playlist items and their index numbers
                // var playlistItemDictionary : [Int: String] = Dictionary(uniqueKeysWithValues: playlistItems.items!.map { ($0.indexNumber!, $0.id!) })
                
                
                                
                var index = 0
                
                // Clear out all songs to repopulate with new data
                if playlist.songs != nil {
                    
                    self.deleteAllPlaylistSongsFromPlaylist(playlist: playlist, context: context)
                }
                
                playlistItems.items!.forEach({ playlistItem in
                    
                    let playlistSong = PlaylistSong(context: context)
                    
                    playlistSong.jellyfinId = playlistItem.playlistItemId
                    
                    playlistSong.playlist = playlist
                    playlistSong.indexNumber = Int16(index)
                    
                    let song: Song = context.object(with: self.retrieveSongFromCore(songId: playlistItem.id!)!) as! Song
                    playlistSong.song = song
                    
                    playlist.addToSongs(playlistSong)
                    
                    index += 1
                })
                      
                try! context.save()
                complete()
            } else {
                complete()
            }
        })
        .store(in: &self.cancellables)

    }
    
    private func loadImages() -> Void {
        
    }
    
    private func deleteMissingAlbums(retrievedAlbumIds: [String]) -> Void {
        
        guard !retrievedAlbumIds.isEmpty else {
            return
        }
        
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Album")
        
        fetchRequest.predicate = NSPredicate(format: "NOT (jellyfinId IN %@)", retrievedAlbumIds)
                
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        do {
            let albumsToDelete = try self.privateContext.fetch(fetchRequest) as! [Album]
            
            self.deleteMissingSongs(albums: albumsToDelete)
                        
            try self.privateContext.execute(deleteRequest)
        } catch {
            print("Error deleting old albums: \(error)")
        }
    }
    
    private func deleteMissingAlbums(artists: [Artist]) -> Void {
        
        guard !artists.isEmpty else {
            return
        }
        
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Album")
        
        let predicates = artists.map {
            NSPredicate(format: "artists CONTAINS %@", $0)
        }
        
        fetchRequest.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
                
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        do {
            let albumsToDelete = try self.privateContext.fetch(fetchRequest) as! [Album]
            
            self.deleteMissingSongs(albums: albumsToDelete)
                        
            try self.privateContext.execute(deleteRequest)
        } catch {
            print("Error deleting old albums: \(error)")
        }
    }
    
    private func deleteMissingArtists(retrievedArtistIds: [String]) -> Void {
        
        guard !retrievedArtistIds.isEmpty else {
            return
        }
        
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Artist")
        
        fetchRequest.predicate = NSPredicate(format: "NOT (jellyfinId IN %@)", retrievedArtistIds)
                
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        do {
            let artistsToDelete = try self.privateContext.fetch(fetchRequest) as! [Artist]
            
//            self.deleteMissingAlbums(artists: artistsToDelete)
//            
//            self.deleteMissingSongs(artists: artistsToDelete)
                        
            try self.privateContext.execute(deleteRequest)
        } catch {
            print("Error deleting old artists: \(error)")
        }
    }
    
    private func deleteMissingSongs(artists: [Artist]) -> Void {
        
        guard !artists.isEmpty else {
            return
        }
        
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Song")

        let predicates = artists.map {
            NSPredicate(format: "artists CONTAINS %@", $0)
        }
        
        fetchRequest.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)

        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        do {
            let songsToDelete = try self.privateContext.fetch(fetchRequest) as! [Song]
			
			songsToDelete.filter({ $0.downloaded }).forEach({ song in
				DownloadManager.shared.delete(song: song)
			})
            
            self.deleteMissingPlaylistSongs(songs: songsToDelete)
            
            try self.privateContext.execute(deleteRequest)
        } catch {
            print("Error deleting old songs: \(error)")
        }
    }
    
    private func deleteMissingSongs(albums: [Album]) -> Void {
        
        guard !albums.isEmpty else {
            return
        }
        
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Song")
        
        fetchRequest.predicate = NSPredicate(format: "album in %@", albums)
        
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        do {
            let songsToDelete = try self.privateContext.fetch(fetchRequest) as! [Song]
			
			songsToDelete.filter({ $0.downloaded }).forEach({ song in
				DownloadManager.shared.delete(song: song)
			})
            
            self.deleteMissingPlaylistSongs(songs: songsToDelete)
            
            try self.privateContext.execute(deleteRequest)
        } catch {
            print("Error deleting old songs: \(error)")
        }
    }
    
    private func deleteMissingSongs(retrievedSongIds: [String]) -> Void {
        
        guard !retrievedSongIds.isEmpty else {
            return
        }
        
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Song")
        
        fetchRequest.predicate = NSPredicate(format: "NOT (jellyfinId IN %@)", retrievedSongIds)
                
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        do {
            let songsToDelete = try self.privateContext.fetch(fetchRequest) as! [Song]
			
			songsToDelete.filter({ $0.downloaded }).forEach({ song in
				DownloadManager.shared.delete(song: song)
			})
            
            self.deleteMissingPlaylistSongs(songs: songsToDelete)
                        
            try self.privateContext.execute(deleteRequest)
        } catch {
            print("Error deleting old songs: \(error)")
        }
    }
    
    private func deleteAllPlaylistSongsFromPlaylist(playlist: Playlist, context: NSManagedObjectContext) -> Void {
        (playlist.songs!.allObjects as! [PlaylistSong]).forEach({ song in
            self.deletePlaylistSongByJellyfinId(playlistSongId: song.jellyfinId!, context: context)
        })
    }
    
    private func deleteMissingPlaylistSongs(songs: [Song]) -> Void {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PlaylistSong")
        
        fetchRequest.predicate = NSPredicate(format: "song in %@", songs)
        
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        do {
            let songsToDelete = try self.privateContext.fetch(fetchRequest) as! [PlaylistSong]
            
            try self.privateContext.execute(deleteRequest)
        } catch {
            print("Error deleting old playlist songs: \(error)")
        }
    }
    
    private func deletePlaylistSongByJellyfinId(playlistSongId: String, context: NSManagedObjectContext) -> Void {
        do {
            let playlistSongObjectId = self.retrievePlaylistSongFromCore(playlistSongId: playlistSongId)
            
            let playlistSong = context.object(with: playlistSongObjectId!)
            
            context.delete(playlistSong)
        } catch {
            print("Error deleting playlist song by it's Jellyfin ID: \(error)")
        }
    }
    
    private func retrieveArtistFromCore(artistName: String) -> NSManagedObjectID? {
        let fetchRequest = Artist.fetchRequest()

        // TODO: Fix this since it isn't retrieving the artist
        fetchRequest.predicate = NSPredicate(format: "name ==[c] %@", artistName)
                
        do {
            return try self.context.fetch(fetchRequest).first?.objectID
        } catch {
            // TODO: handle the error
             print(error)
            
            return nil
        }
    }
    
    private func retrieveArtistFromCoreById(jellyfinId: String) -> NSManagedObjectID? {
        let fetchRequest = Artist.fetchRequest()
        
        fetchRequest.predicate = NSPredicate(format: "jellyfinId == %@", jellyfinId)
        
        do {
            return try self.context.fetch(fetchRequest).first?.objectID
        } catch {
            print("Error retrieving artist from CoreData: \(error)")
            
            return nil
        }
    }
    
    public func retrieveAllArtistsFromCore() -> [Artist] {
        let fetchRequest = Artist.fetchRequest()
        
        do {
            return try self.privateContext.fetch(fetchRequest)
        } catch {
            print("Error retrieving all artists from CoreData: \(error)")
            
            return []
        }
    }
    
    private func retrieveArtistsFromCoreByJellyfinIds(jellyfinIds: [String]) -> [NSManagedObjectID] {
        let fetchRequest = Artist.fetchRequest()

        let predicates = jellyfinIds.map {
            NSPredicate(format: "jellyfinId == %@", $0)
        }
        
        fetchRequest.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        
        let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        privateContext.parent = self.context
                
        do {
            return try privateContext.fetch(fetchRequest).map { $0.objectID }
        } catch {
            // TODO: handle the error
             print(error)
            
            return []
        }

    }
    
    private func retrieveArtistsFromCoreByNames(names: [String]) -> [Artist] {
        let fetchRequest = Artist.fetchRequest()

        let predicates = names.map {
            NSPredicate(format: "name ==[c] %@", $0)
        }
        
        fetchRequest.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
                
        do {
            return try self.context.fetch(fetchRequest)
        } catch {
            // TODO: handle the error
             print(error)
            
            return []
        }
    }
 
    private func retrieveAlbumFromCore(albumId: String) -> NSManagedObjectID? {
        let fetchRequest = Album.fetchRequest()
        
        fetchRequest.predicate = NSPredicate(format: "jellyfinId == %@", albumId)
        
        let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        privateContext.parent = self.context
        
        do {
            return try privateContext.fetch(fetchRequest).first?.objectID
        } catch {
            print("Error retrieving album from CoreData: \(error)")
            
            return nil
        }
    }
    
    public func retrieveAlbumsFromCore(albumArtistName: String) -> [NSManagedObjectID] {
        let fetchRequest = Album.fetchRequest()
        
        fetchRequest.predicate = NSPredicate(format: "albumArtistName == %@", albumArtistName)
        
        let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        
        privateContext.parent = self.context
        
        do {
            return try privateContext.fetch(fetchRequest).map({ $0.objectID })
        } catch let error as NSError {
            print("Error retrieving all albums from CoreData: \(error)")
            
            return []
        }
    }
	
	private func retrieveAlbumsToDownload() -> [Album] {
		let fetchRequest = Album.fetchRequest()
		
		fetchRequest.predicate = NSPredicate(format: "downloaded == true")
		
		do {
			return try self.context.fetch(fetchRequest)
		} catch let error as NSError {
			print("Error retrieving all albums marked for download. \(error)")
			
			return []
		}
	}
    
    private func retrieveAllAlbumsFromCore() -> [Album] {
        let fetchRequest = Album.fetchRequest()
        
        let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        
        privateContext.parent = self.context
        
        do {
            return try privateContext.fetch(fetchRequest)
        } catch let error as NSError {
            print("Error retrieving all albums from CoreData: \(error)")
            
            return []
        }
    }
    
    private func retrieveSongFromCore(songId: String) -> NSManagedObjectID? {
        let fetchRequest = Song.fetchRequest()
        
        fetchRequest.predicate = NSPredicate(format: "jellyfinId == %@", songId)
        
        let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        
        privateContext.parent = self.context
        
        do {
            return try privateContext.fetch(fetchRequest).first?.objectID
        } catch let error as NSError {
            print("Error retrieving song from CoreData: \(error)")
            
            return nil
        }
    }
    
    public func retrieveSongsFromCore(albumId: String) -> [NSManagedObjectID] {
        let fetchRequest = Song.fetchRequest()
        
        fetchRequest.predicate = NSPredicate(format: "album.jellyfinId == %@", albumId)
        
        let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        
        privateContext.parent = self.context
        
        do {
            return try privateContext.fetch(fetchRequest).map({ $0.objectID })
        } catch let error as NSError {
            print("Error retrieving songs from CoreData: \(error)")
            
            return []
        }
    }
    
    private func retrieveAllSongsFromCore() -> [Song] {
        let fetchRequest = Song.fetchRequest()
                
        let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        
        privateContext.parent = self.context
        
        do {
            return try privateContext.fetch(fetchRequest)
        } catch let error as NSError {
            print("Error retrieving all songs from CoreData: \(error)")
            
            return []
        }
    }
    
//    private func retrieveAllSongsIdsFromCore() -> [String] {
//        let fetchRequest = Song.fetchRequest()
//        
//        fetchRequest.propertiesToFetch = [#keyPath(Song.jellyfinId)]
//        
//        let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
//        
//        privateContext.parent = self.context
//        
//        do {
//            return try privateContext.fetch(fetchRequest)
//        } catch let error as NSError {
//            print("Error retrieving all songs from CoreData: \(error)")
//            
//            return []
//        }
//    }
    
    private func retrieveSongsToDownload() -> [Song] {
        
        let fetchRequest = Song.fetchRequest()
        
        fetchRequest.predicate = NSPredicate(format: "downloading == true")
        
        do {
            return try self.privateContext.fetch(fetchRequest)
        } catch let error as NSError {
            print("Error retrieving songs currently downloading from CoreData: \(error)")
            
            return []
        }
    }
    
    private func retrievePlaylistFromCore(playlistId: String) -> NSManagedObjectID? {
        let fetchRequest = Playlist.fetchRequest()
        
        fetchRequest.predicate = NSPredicate(format: "jellyfinId == %@", playlistId)
        
        do {
            return try self.context.fetch(fetchRequest).first?.objectID
        } catch let error as NSError {
            print("Error retrieving playlist from CoreData: \(error)")
            
            return nil
        }
    }
    
    public func retrieveAllPlaylistsFromCore() -> [Playlist] {
        let fetchRequest = Playlist.fetchRequest()
        
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: #keyPath(Playlist.sortName), ascending: true)]
        
        let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        
        privateContext.parent = self.context
        
        do {
            return try privateContext.fetch(fetchRequest)
        } catch let error as NSError {
            print("Error retrieving all playlists from CoreData: \(error)")
            
            return []
        }
    }
    
    private func retrievePlaylistsToDownload() -> [Playlist] {
        
        let fetchRequest = Playlist.fetchRequest()
        
        fetchRequest.predicate = NSPredicate(format: "downloaded == true")
        
        do {
            return try self.privateContext.fetch(fetchRequest)
        } catch let error as NSError {
            print("Error retrieving playlists queued to download from CoreData: \(error)")
            
            return []
        }
    }
    
    private func retrievePlaylistSongFromCore(playlistSongId: String) -> NSManagedObjectID? {
        let fetchRequest = PlaylistSong.fetchRequest()
        
        fetchRequest.predicate = NSPredicate(format: "jellyfinId == %@", playlistSongId)
        
        let privateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        
        privateContext.parent = self.context
        
        do {
            return try privateContext.fetch(fetchRequest).first?.objectID
        } catch let error as NSError {
            print("Error retrieving playlist song from CoreData: \(error)")
            
            return nil
        }
    }
    
    private func retrievePlaylistSongFromCore(indexNumber: Int) -> PlaylistSong? {
        let fetchRequest = PlaylistSong.fetchRequest()
        
        fetchRequest.predicate = NSPredicate(format: "indexNumber == %@", indexNumber)
        
        do {
            return try self.privateContext.fetch(fetchRequest).first
        } catch let error as NSError {
            print("Error retrieving playlist song by index number from CoreData: \(error)")
            
            return nil
        }
    }
    
    public func retrievePlaylistSongsFromCore(playlistId: String) -> [NSManagedObjectID]? {
        let fetchRequest = PlaylistSong.fetchRequest()
        
        fetchRequest.predicate = NSPredicate(format: "playlist.jellyfinId == %@", playlistId)
        
        do {
            return try self.context.fetch(fetchRequest).map({ $0.objectID })
        } catch let error as NSError {
            print("Error retrieving songs from playlist \(playlistId): \(error)")
            
            return nil
        }
    }
    
    public func saveContext() {
        
		self.privateContext.perform {
            do {
				try self.privateContext.save()
                self.context.performAndWait {
                    do {
                        try self.context.save()
                    } catch {
                        fatalError("Failure to save main context: \(error)")
                    }
                }
            } catch {
                fatalError("Error saving private context: \(error)")
            }
        }
    }
            
    private func setAuthHeaders() -> Void {
        
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as! String
        var deviceName = UIDevice.current.name
        deviceName = deviceName.folding(options: .diacriticInsensitive, locale: .current)
        deviceName = String(deviceName.unicodeScalars.filter { CharacterSet.urlQueryAllowed.contains($0) })
        
        let deviceId = UIDevice.current.identifierForVendor!.uuidString
        
        let header = "MediaBrowser Client=\"\(appName ?? "Jellify")\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(appVersion)\""
        
        JellyfinAPI.customHeaders["X-Emby-Authorization"] = header
    }
    
    private func setCustomHeaders() -> Void {
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as! String
        var deviceName = UIDevice.current.name
        deviceName = deviceName.folding(options: .diacriticInsensitive, locale: .current)
        deviceName = String(deviceName.unicodeScalars.filter { CharacterSet.urlQueryAllowed.contains($0) })
        
        let platform: String
        #if os(tvOS)
        platform = "tvOS"
        #else
        platform = "iOS"
        #endif
        
        var header = "MediaBrowser "
        header.append("Client=\"\(appName ?? "Jellify")\", ")
        header.append("Device=\"\(deviceName)\", ")
        header.append("DeviceId=\"\(UIDevice.current.identifierForVendor!)\", ")
        header.append("Version=\"\(appVersion)\", ")
        header.append("Token=\"\(accessToken)\"")
        
        JellyfinAPI.customHeaders["X-Emby-Authorization"] = header
    }
}

enum LoadingPhase {
    case artists
    case albums
    case songs
    case playlists
    case artwork
}
