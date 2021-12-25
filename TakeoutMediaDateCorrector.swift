import Foundation

struct MediaBundle: Codable {
  let media: Media
  let mediaFileURL: URL
}

struct Media: Codable {
  let title: String
  let creationTime: Time
  let photoLastModifiedTime: Time
  
  enum CodingKeys: String, CodingKey {
    case title
    case creationTime
    case photoLastModifiedTime
  }
}

struct Time: Codable {
  let timestamp: String
  let formatted: String
}

struct FailedMedia: Codable {
  let mediaBundle: MediaBundle
  let createdDate: Date
  let modifiedDate: Date
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
  if let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: takeoutFolder, isDirectory: true), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
    for case let fileURL as URL in enumerator {
      do {
        let fileAttributes = try fileURL.resourceValues(forKeys:[.isRegularFileKey])
        if fileAttributes.isRegularFile! && fileURL.pathExtension == "json" {
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
    return MediaBundle(media: mediaMetadata, mediaFileURL: mediaFileURL)
  }
  return mediaBundles
}

func setCreateAndModifiedDate(fromMediaBundles mediaBundles: [MediaBundle]) -> [FailedMedia] {
  var failed: [FailedMedia] = []
  for mediaBundle in mediaBundles {
    let createdDate = Date(timeIntervalSince1970: Double(mediaBundle.media.creationTime.timestamp)!)
    let modifiedDate = Date(timeIntervalSince1970: Double(mediaBundle.media.photoLastModifiedTime.timestamp)!)
    let attributes = [FileAttributeKey.creationDate: createdDate, FileAttributeKey.modificationDate: modifiedDate]
    do {
      try FileManager.default.setAttributes(attributes, ofItemAtPath: mediaBundle.mediaFileURL.relativePath)
    } 
    catch {
      failed.append(FailedMedia(mediaBundle: mediaBundle, createdDate: createdDate, modifiedDate: modifiedDate, failureReason: error.localizedDescription))
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

func recursivelyCorrectFileDates(startingInFolder folder: String) -> FailedMediaReport {
  let urls = allMediaMetadataJSONFileURLs(fromTakeoutFolder: folder)
  let mediaBundles = loadMediaBundles(fromJSONFileURLS: urls)

  print("Attempting to recursively correct: \(mediaBundles.count) media files starting in \(folder)")
  let failedMediaBundles = setCreateAndModifiedDate(fromMediaBundles: mediaBundles)
  let failedReport = FailedMediaReport(processed: mediaBundles.count, media: failedMediaBundles)
  return failedReport
}

func run() {
  let folder = "/Users/jliebowitz/Downloads/Takeout/Google Photos/"
  let report = recursivelyCorrectFileDates(startingInFolder: folder)
  
  let reportFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("failedMediaReport.json")
  save(failedMediaReport: report, reportFileURL: reportFileURL)
  
  print("Output saved to  : \(reportFileURL)")
  print("Processed items  : \(report.processed)")
  print("Failed items     : \(report.failedItems)")
  print("Successful items : \(report.successfulItems)")
}

let start = Date.now
print("\(start)")
run()
print("Took \(start.timeIntervalSinceNow * -1) seconds")