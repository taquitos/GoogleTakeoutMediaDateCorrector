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

let takeoutFolder = "/Users/jliebowitz/Downloads/Google Backup/Takeout/Google Photos/"

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
                                  failureReason: "Created timestamp missing"))
        continue
    }
    guard let modifiedTimestamp = mediaBundle.media.photoLastModifiedTime?.timestamp else {
      failed.append(FailedMedia(mediaBundle: mediaBundle, 
                                mediaURL: mediaBundle.mediaFileURL,
                                alternateMediaURL: mediaBundle.alternateMediaFileURL(),
                                createdDate: nil, 
                                modifiedDate: nil, 
                                failureReason: "Modified timestamp missing"))
      continue
    }
    let createdDate = Date(timeIntervalSince1970: Double(createdTimestamp)!)
    let modifiedDate = Date(timeIntervalSince1970: Double(modifiedTimestamp)!)
    let attributes = [
      FileAttributeKey.creationDate: createdDate, 
      FileAttributeKey.modificationDate: modifiedDate
    ]
    do {
      try FileManager.default.setAttributes(attributes, ofItemAtPath: mediaBundle.mediaFileURL.relativePath)
    } catch {
      let nsError = error as NSError
      if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
        do {
          let alternateFileURL = mediaBundle.alternateMediaFileURL()
          try FileManager.default.setAttributes(attributes, ofItemAtPath: alternateFileURL.relativePath)
        } catch {
          failed.append(FailedMedia(mediaBundle: mediaBundle,
            mediaURL: mediaBundle.mediaFileURL,
            alternateMediaURL: mediaBundle.alternateMediaFileURL(),
            createdDate: createdDate,
            modifiedDate: modifiedDate, 
            failureReason: error.localizedDescription))
        }
      } else {
        failed.append(FailedMedia(mediaBundle: mediaBundle, 
          mediaURL: mediaBundle.mediaFileURL,
          alternateMediaURL: mediaBundle.alternateMediaFileURL(),
          createdDate: createdDate, 
          modifiedDate: modifiedDate, 
          failureReason: error.localizedDescription))
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
