# GoogleTakeoutMediaDateCorrector
Google Photos "takeout" doesn't retain created/modified dates of media. At least they do export this in a separate json file for each media item. 
This project recursively adjusts all media files create and modified date back to what is in the json. 

__Note:__ It does not adjust exif data, only the file's created and last modified times (filesystem metadata).
