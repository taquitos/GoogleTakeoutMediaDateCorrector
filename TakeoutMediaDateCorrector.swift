//
//  Copyright Joshua Liebowitz. All Rights Reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://opensource.org/licenses/MIT
//
//  TakeoutMediaDateCorrector.swift
//
//  Created by Joshua Liebowitz on 12/24/21.

import Foundation

let takeoutFolder: String
var sortIntoDateFolder = true
let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "MM"

let exampleLaunchCommand = "\(CommandLine.arguments[0]) <path_to_folder_containing_media> [--organize true|false]"
if CommandLine.argc == 1 {
  print("🤷‍♂️ missing path: \(exampleLaunchCommand)")
  exit(-1)
}

if CommandLine.argc == 2 || CommandLine.argc == 4 {
  takeoutFolder = CommandLine.arguments[1]
  if CommandLine.argc == 4 {
    if CommandLine.arguments[2] != "--organize" {
      print("🤷‍♂️ Unrecognized arg \(CommandLine.arguments[2])")
      exit(-1)
    }
    guard let organize = Bool(CommandLine.arguments[3]) else {
      print("🤷‍♂️ Unrecognized value for \(CommandLine.arguments[2]): \(CommandLine.arguments[3])")
      exit(-1)
    }
    sortIntoDateFolder = organize
  }
} else {
  print("🤷‍♂️ invalid launch args. Try again: \(exampleLaunchCommand)")
  exit(-1)
}

print(CommandLine.arguments)

guard FileManager.default.fileExists(atPath: takeoutFolder) else {
  print("❌ Folder \(takeoutFolder) doesn't exist")
  exit(-1)
}

print("📂 Folder set to \(takeoutFolder)")

extension FileManager {
  func moveItemCreatingIntermediaryDirectoriesIfNeeded(atURL : URL, toURL: URL) throws {
    let parentPath = toURL.deletingLastPathComponent()
    if !fileExists(atPath: parentPath.path) {
      try createDirectory(at: parentPath, withIntermediateDirectories: true, attributes: nil)
    }
    try moveItem(at: atURL, to: toURL)
  }
}

struct MediaBundle: Codable {
  let media: Media
  let mediaFileURL: URL
  let jsonURL: URL
  
  // Sometimes the title doesn't match the media file name due to some length restrictions 
  // (filename + extension can't be greater than 50 chars)
  // eg: "title": "62225750180__674A9E40-E82A-4F89-86AC-8DD52EBEBBCB.JPG" actually should be
  //     "title": "62225750180__674A9E40-E82A-4F89-86AC-8DD52EBEBB.JPG"
  // Also, duplicates are treated differently
  // eg: "title": "61585423862__BBC9F10B-72CB-4825-BF07-C9D52B3FE9E6.JPG" can
  //  be found in "61585423862__BBC9F10B-72CB-4825-BF07-C9D52B3FE(1).json"
  // but called:  "61585423862__BBC9F10B-72CB-4825-BF07-C9D52B3FE9(1).JPG" in the filesystem.
  func alternateMediaFileURL() -> URL {
    var absolutePath = jsonURL.absoluteString
    var parensAndNumber: String = ""
    if absolutePath.last! == ")" {
      while absolutePath.last != "(" {
        let removedChar = absolutePath.removeLast()
        parensAndNumber.append(removedChar)
      }
      parensAndNumber.append(absolutePath.removeLast())
      parensAndNumber = String(parensAndNumber.reversed())
    }
    
    let title = mediaFileURL.deletingPathExtension()
    var newTitle = mediaFileURL
    let extensionSize = mediaFileURL.pathExtension.count
    if title.lastPathComponent.count + extensionSize > 50 {
      let dropCount = title.lastPathComponent.count - (50 - extensionSize)
      let adjustedTitleNoExtension = (title.lastPathComponent.dropLast(dropCount)) + parensAndNumber
      newTitle = jsonURL.deletingLastPathComponent()
                        .appendingPathComponent(String(adjustedTitleNoExtension))
    }
    return newTitle.appendingPathExtension(mediaFileURL.pathExtension)
  }
  
  init(media: Media, mediaFileURL: URL, jsonURL: URL) {
    self.media = media
    self.mediaFileURL = mediaFileURL 
    self.jsonURL = jsonURL
  }
}

struct Media: Codable {
  let title: String
  let creationTime: Time?
  let photoTakenTime: Time?
  let photoLastModifiedTime: Time?
  
  enum CodingKeys: String, CodingKey {
    case title
    case creationTime
    case photoTakenTime
    case photoLastModifiedTime
  }
}

struct Time: Codable {
  let timestamp: String?
  let formatted: String
}

struct FailedMedia: Codable {
  let mediaBundle: MediaBundle
  let mediaURL: URL
  let alternateMediaURL: URL
  let createdDate: Date?
  let modifiedDate: Date?
  let failureReason: String
  let duringMove: Bool
}

struct SetAttributeResult {
  let failedMedia: FailedMedia?
  let jsonFileURL: URL?
  let mediaFilePath: String?
}

struct FailedMediaReport: Codable {
  let processed: Int
  let failedItems: Int
  let successfulItems: Int
  let media: [FailedMedia]
  
  init(processed: Int, media: [FailedMedia]) {
    self.media = media
    self.failedItems = media.count
    self.processed = processed
    self.successfulItems = processed - media.count
  }
}

func allMediaMetadataJSONFileURLs(fromTakeoutFolder takeoutFolder: String) -> [URL] {
  var files = [URL]()
  let takeoutURL = URL(fileURLWithPath: takeoutFolder, isDirectory: true)
  if let enumerator = FileManager.default.enumerator(at: takeoutURL, 
                                                     includingPropertiesForKeys: [.isRegularFileKey], 
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
    for case let fileURL as URL in enumerator {
      do {
        let fileAttributes = try fileURL.resourceValues(forKeys:[.isRegularFileKey])
        if fileAttributes.isRegularFile! 
          && fileURL.pathExtension == "json"
          // Ignore `metadata.json` files, they aren't helpful for this.
          && fileURL.lastPathComponent != "metadata.json" {
          files.append(fileURL)
        }
      } catch { print(error, fileURL) }
    }
  }
  return files
}

func loadMediaBundles(fromJSONFileURLS urls: [URL]) -> [MediaBundle] {
  let mediaBundles: [MediaBundle] = urls.map { 
    let mediaMetadata = try! JSONDecoder().decode(Media.self, from: Data(contentsOf: $0))
    let mediaFileURL = $0.deletingLastPathComponent().appendingPathComponent(mediaMetadata.title)
    return MediaBundle(media: mediaMetadata, mediaFileURL: mediaFileURL, jsonURL: $0)
  }
  return mediaBundles
}

func failedMedia(mediaBundle: MediaBundle, 
                 createdDate: Date, 
                 modifiedDate: Date, 
                 error: Error,
                 duringMove: Bool = false) -> FailedMedia {
  return FailedMedia(mediaBundle: mediaBundle,
    mediaURL: mediaBundle.mediaFileURL,
    alternateMediaURL: mediaBundle.alternateMediaFileURL(),
    createdDate: createdDate,
    modifiedDate: modifiedDate, 
    failureReason: error.localizedDescription,
    duringMove: duringMove)
}

func setAttributes(createdDate: Date, modifiedDate: Date, mediaBundle: MediaBundle) -> SetAttributeResult {
  let attributes = [
    FileAttributeKey.creationDate: createdDate, 
    FileAttributeKey.modificationDate: modifiedDate
  ]
  var mediaPathInUse: String = mediaBundle.mediaFileURL.relativePath
  do {
    try FileManager.default.setAttributes(attributes, ofItemAtPath: mediaPathInUse)
  } catch {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
      do {
        mediaPathInUse = mediaBundle.alternateMediaFileURL().relativePath
        try FileManager.default.setAttributes(attributes, ofItemAtPath: mediaPathInUse)
      } catch {
        let failedMedia = failedMedia(mediaBundle: mediaBundle, 
                                      createdDate: createdDate, 
                                      modifiedDate: modifiedDate, 
                                      error: error)
        return SetAttributeResult(failedMedia: failedMedia, jsonFileURL: nil, mediaFilePath: nil)
      }
    } else {
      let failedMedia = failedMedia(mediaBundle: mediaBundle, 
                                    createdDate: createdDate, 
                                    modifiedDate: modifiedDate, 
                                    error: error)
      return SetAttributeResult(failedMedia: failedMedia, jsonFileURL: nil, mediaFilePath: nil)
    }
  }
  return SetAttributeResult(failedMedia: nil, jsonFileURL: mediaBundle.jsonURL, mediaFilePath: mediaPathInUse)
}

func organizeMediaIntoMonths(atMediaFilePath mediaFilePath: String, jsonFileURL: URL, createdDate: Date) -> Error? {
  let monthString = dateFormatter.string(from: createdDate)
  let mediaFileURL = URL(fileURLWithPath: mediaFilePath)
  let newFileURL = mediaFileURL.deletingLastPathComponent()
                               .appendingPathComponent(monthString)
                               .appendingPathComponent(mediaFileURL.lastPathComponent)
  print("from: \(mediaFileURL.absoluteString)")
  print("to  : \(newFileURL.absoluteString)")
  do {
    try FileManager.default.moveItemCreatingIntermediaryDirectoriesIfNeeded(atURL: mediaFileURL, toURL: newFileURL)
    let newJSONFileURL = jsonFileURL.deletingLastPathComponent()
                                    .appendingPathComponent(monthString)
                                    .appendingPathComponent(jsonFileURL.lastPathComponent)
    try FileManager.default.moveItemCreatingIntermediaryDirectoriesIfNeeded(atURL: jsonFileURL, toURL: newJSONFileURL)
  } catch {
    return error
  }
  return nil
}

func setCreateAndModifiedDate(fromMediaBundles mediaBundles: [MediaBundle]) -> [FailedMedia] {
  var failed: [FailedMedia] = []
  for mediaBundle in mediaBundles {
    // Grab photoTakenTime if available, otherwise default to creationTime 
    // (probably creation time on Google's servers)
    let createdTimestamp = mediaBundle.media.photoTakenTime?.timestamp 
                           ?? (mediaBundle.media.creationTime?.timestamp ?? nil)
    guard let createdTimestamp = createdTimestamp else {
        failed.append(FailedMedia(mediaBundle: mediaBundle, 
                                  mediaURL: mediaBundle.mediaFileURL,
                                  alternateMediaURL: mediaBundle.alternateMediaFileURL(),
                                  createdDate: nil, 
                                  modifiedDate: nil, 
                                  failureReason: "Created timestamp missing",
                                  duringMove: false))
        continue
    }
    guard let modifiedTimestamp = mediaBundle.media.photoLastModifiedTime?.timestamp else {
      failed.append(FailedMedia(mediaBundle: mediaBundle, 
                                mediaURL: mediaBundle.mediaFileURL,
                                alternateMediaURL: mediaBundle.alternateMediaFileURL(),
                                createdDate: nil, 
                                modifiedDate: nil, 
                                failureReason: "Modified timestamp missing",
                                duringMove: false))
      continue
    }
    
    let createdDate = Date(timeIntervalSince1970: Double(createdTimestamp)!)
    let modifiedDate = Date(timeIntervalSince1970: Double(modifiedTimestamp)!)
    let result = setAttributes(createdDate: createdDate, modifiedDate: modifiedDate, mediaBundle: mediaBundle)
    if let failedMedia = result.failedMedia {
      failed.append(failedMedia)
      continue
    }
    if sortIntoDateFolder {
      if let error = organizeMediaIntoMonths(
        atMediaFilePath: result.mediaFilePath!, 
        jsonFileURL: result.jsonFileURL!, 
        createdDate: createdDate) {
          failed.append(failedMedia(mediaBundle: mediaBundle, 
                                    createdDate: createdDate, 
                                    modifiedDate: modifiedDate, 
                                    error: error, 
                                    duringMove: true))
      }
      
    }
    
  }
  return failed
}

func save(failedMediaReport: FailedMediaReport, reportFileURL: URL) {
  let jsonEncoder = JSONEncoder()
  jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let failedData = try! jsonEncoder.encode(failedMediaReport)
  try! failedData.write(to: reportFileURL)
}

func run() {
  let folder = takeoutFolder
  
  print("🔍 Finding all media metadata json starting in \(folder)")
  let urls = allMediaMetadataJSONFileURLs(fromTakeoutFolder: folder)
  print("🗣️ Found \(urls.count) json files")
  
  print("📚 Parsing all media metadata json")
  let mediaBundles = loadMediaBundles(fromJSONFileURLS: urls)
  print("🗣️ Loaded \(mediaBundles.count) MediaBundle objects")
  
  print("⛑️ Attempting to recursively correct: \(mediaBundles.count) media files starting in \(folder)")
  let failedMediaBundles = setCreateAndModifiedDate(fromMediaBundles: mediaBundles)
  let failedReport = FailedMediaReport(processed: mediaBundles.count, media: failedMediaBundles)
  
  print("🕵️‍♀️ Processed items  : \(failedReport.processed)")
  print("✅ Successful items : \(failedReport.successfulItems)")
  if failedReport.media.count > 0 {
    let reportFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("failedMediaReport.json")
    save(failedMediaReport: failedReport, reportFileURL: reportFileURL)
    
    print("📝 Output saved to  : \(reportFileURL)")
    print("🤦‍♂️ Failed items     : \(failedReport.failedItems)")
  } else {
    print("🎉 No failures")
  }
}

let start = Date.now
print("Starting at: \(start)")
run()
print("Took \(start.timeIntervalSinceNow * -1) seconds")
