//
//  ImageStore.swift
//  ImageStore
//
//  Created by miup on 2017/08/01.
//

import UIKit

public enum ImageStoreError: Error {
    case dataIsNotImage
    case cantGetDataFromURL(URL)
    case taskError(Error?)
    case cantGetStorageDownloadURL(Error?)
}

public struct ImageStoreConfig {

    /// default 20MB
    let maxDownloadSize: Int64

    /// default 200MB
    let cacheLimit: Int64

    public init(maxDownloadSize: Int64 = Int64(20e6), cacheLimit: Int64 = Int64(200e6)) {
        self.maxDownloadSize = maxDownloadSize
        self.cacheLimit = cacheLimit
    }
}

public final class ImageStore: NSObject {

    public typealias ImageStoreCompletionHandler = ((UIImage?, ImageStoreError?) -> Void)

    private(set) public static var shared: ImageStore = ImageStore(ImageStoreConfig())

    public class func reset(config: ImageStoreConfig = ImageStoreConfig()) {
        shared = ImageStore(config)
    }


    fileprivate let config: ImageStoreConfig
    fileprivate var completionsByURLString: [String: [ImageStoreCompletionHandler]] = [:]
    fileprivate var downloadTaskByURLString: [String: URLSessionDownloadTask] = [:]

    private(set) lazy var cache: NSCache<AnyObject, UIImage> = {
        let cache: NSCache<AnyObject, UIImage> = NSCache()
        cache.name = "ImageStore.ImageStore.cache"
        return cache
    }()

    private lazy var queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ImageStore.ImageStore.queue"
        return queue
    }()

    private lazy var session: URLSession = {
        let config: URLSessionConfiguration = .default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        let session =
            URLSession(
                configuration: config,
                delegate: self,
                delegateQueue: self.queue)
        return session
    }()

    private init(_ config: ImageStoreConfig) {
        self.config = config
        super.init()
        cache.totalCostLimit = Int(self.config.cacheLimit)
    }

    @discardableResult
    public func load(_ url: URL, completion: ImageStoreCompletionHandler? = nil) -> URLSessionDownloadTask? {
        if let cachedImage: UIImage = cache.object(forKey: url.absoluteString as AnyObject) {
            completion?(cachedImage, nil)
            return nil
        }

        if let completion = completion {
            if let completions: [ImageStoreCompletionHandler] = completionsByURLString[url.absoluteString] {
                completionsByURLString[url.absoluteString] = completions.appended(completion)
            } else {
                completionsByURLString[url.absoluteString] = [completion]
            }
        }

        let task: URLSessionDownloadTask
        if let _task = downloadTaskByURLString[url.absoluteString] {
            task = _task
            task.resume()
        } else {
            task = session.downloadTask(with: url)
            task.resume()
            downloadTaskByURLString[url.absoluteString] = task
        }

        return task
    }

    public func suspendIfResuming(url: URL) {
        if let task = downloadTaskByURLString[url.absoluteString] {
            task.suspend()
        }
    }

    public func cancel(url: URL) {
        if let task = downloadTaskByURLString[url.absoluteString] {
            task.cancel()
            downloadTaskByURLString.removeValue(forKey: url.absoluteString)
        }
    }

}

extension ImageStore: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let data = try Data(contentsOf: location)
            if let image = UIImage(data: data), let url = downloadTask.currentRequest?.url {
                cache.setObject(image, forKey: url.absoluteString as AnyObject, cost: data.count)
                if let _ = downloadTaskByURLString[url.absoluteString] {
                    downloadTaskByURLString.removeValue(forKey: url.absoluteString)
                }
                guard let completions: [ImageStoreCompletionHandler] = completionsByURLString[url.absoluteString] else {
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    completions.forEach { $0(image, nil) }
                    self?.completionsByURLString[url.absoluteString] = []
                }
            } else {
                print("[ImageStore] can't instantiate image from data.")
                guard let url = downloadTask.currentRequest?.url, let completions: [ImageStoreCompletionHandler] = completionsByURLString[url.absoluteString] else {
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    completions.forEach { $0(nil, .dataIsNotImage) }
                    self?.completionsByURLString[url.absoluteString] = []
                }
            }
        } catch {
            print("[ImageStore] can't get data from url.")
            guard let url = downloadTask.currentRequest?.url, let completions: [ImageStoreCompletionHandler] = completionsByURLString[url.absoluteString] else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                completions.forEach { $0(nil, .cantGetDataFromURL(url)) }
                self?.completionsByURLString[url.absoluteString] = []
            }
        }
    }

}

extension ImageStore: URLSessionDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // let progress: Double = (Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask else { return }
        guard let url: URL = downloadTask.currentRequest?.url else { return }
        guard let completions: [ImageStoreCompletionHandler] = completionsByURLString[url.absoluteString] else {
            return
        }
        if let _ = downloadTaskByURLString[url.absoluteString] {
            downloadTaskByURLString.removeValue(forKey: url.absoluteString)
        }
        DispatchQueue.main.async { [weak self] in
            completions.forEach { $0(nil, .taskError(error)) }
            self?.completionsByURLString[url.absoluteString] = []
        }
    }
}

extension ImageStore: NSCacheDelegate {
    public func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        if let image: UIImage = obj as? UIImage {
             print("[ImageStore] cache will evict image", image)
        }
    }
}
