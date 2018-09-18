/*
 * Copyright (c) 2016-present Razeware LLC
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

import UIKit
import RxSwift
import RxCocoa
import Kingfisher

func cachedFileURL(_ fileName: String) -> URL {
    return FileManager.default
        .urls(for: .cachesDirectory, in: .allDomainsMask)
        .first!
        .appendingPathComponent(fileName)
}

class ActivityController: UITableViewController {
    
    private let repo = "ReactiveX/RxSwift"
    private let modifiedFileURL = cachedFileURL("modified.txt")
    private let eventsFileURL = cachedFileURL("events.plist")
    private let events = Variable<[Event]>([])
    private let lastModified = Variable<NSString?>(nil)
    private let bag = DisposeBag()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = repo
        
        self.refreshControl = UIRefreshControl()
        let refreshControl = self.refreshControl!
        
        refreshControl.backgroundColor = UIColor(white: 0.98, alpha: 1.0)
        refreshControl.tintColor = UIColor.darkGray
        refreshControl.attributedTitle = NSAttributedString(string: "Pull to refresh")
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        
        let eventsArray = (NSArray(contentsOf: eventsFileURL) as? [[String: Any]]) ?? []
        events.value = eventsArray.compactMap(Event.init)
        
        lastModified.value = try? NSString(contentsOf: modifiedFileURL, usedEncoding: nil)
        
        refresh()
    }
    
    @objc func refresh() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.fetchEvents(repo: strongSelf.repo)
        }
    }
    
    func processEvents(_ newEvents: [Event]) {
        var updateEvents = newEvents + events.value
        if updateEvents.count > 50 {
            updateEvents = Array(updateEvents.prefix(upTo: 50))
        }
        events.value = updateEvents
        DispatchQueue.main.async {
            self.tableView.reloadData()
            self.refreshControl?.endRefreshing()
        }
        let eventsArray = updateEvents.map { $0.dictionary } as NSArray
        eventsArray.write(to: eventsFileURL, atomically: true)
    }
    
    func fetchEvents(repo: String) {
        let response = Observable.from(["https://api.github.com/search/repositories?q=language:swift&per_page=5"])
            .map { URL(string: $0)! }
            .flatMap { URLSession.shared.rx.json(url: $0) }
            .flatMap { r -> Observable<String> in
                guard let r = r as? [String: Any], let items = r["items"] as? [[String: Any]] else {
                    return Observable.empty()
                }
                return Observable.from(items.compactMap({ $0["full_name"] as? String }))
            }
            .map { URL(string: "https://api.github.com/repos/\($0)/events")! }
            .map { [weak self] in
                var request = URLRequest(url: $0)
                if let modifiedHeader = self?.lastModified.value {
                    request.addValue(modifiedHeader as String, forHTTPHeaderField: "Last-Modified")
                }
                return request
            }
            .flatMap { URLSession.shared.rx.response(request: $0) }
            .share(replay: 1, scope: .whileConnected)

        response
            .filter { r, _ in 200..<300 ~= r.statusCode }
            .map { _, d in (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] ?? [] }
            .filter { $0.count > 0 }
            .map { $0.compactMap(Event.init) }
            .subscribe(onNext: { [weak self] in self?.processEvents($0) })
            .disposed(by: bag)

        response
            .filter { r, _ in 200..<400 ~= r.statusCode }
            .flatMap { r, _ -> Observable<NSString> in
                guard let value = r.allHeaderFields["Last-Modified"] as? NSString else {
                    return Observable.empty()
                }
                return Observable.just(value)
            }
            .subscribe(onNext: { [weak self] modifiedHeader in
                guard let `self` = self else { return }
                self.lastModified.value = modifiedHeader
                try? modifiedHeader.write(to: self.modifiedFileURL, atomically: true, encoding: String.Encoding.utf8.rawValue)
            })
            .disposed(by: bag)
    }
    
    // MARK: - Table Data Source
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return events.value.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let event = events.value[indexPath.row]
        
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell")!
        cell.textLabel?.text = event.name
        cell.detailTextLabel?.text = event.repo + ", " + event.action.replacingOccurrences(of: "Event", with: "").lowercased()
        cell.imageView?.kf.setImage(with: event.imageUrl, placeholder: UIImage(named: "blank-avatar"))
        return cell
    }
}
