//
//  ClaudeService+WebTools.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

// MARK: - Web Tools (Search & Fetch)

extension ClaudeService {

    private func makeURLSession(for url: URL, settings: AppSettings) -> URLSession {
        ProxyURLSessionFactory.makeSession(for: url, proxyConfiguration: settings.proxyConfiguration)
    }

    // MARK: - Ollama web_search

    func executeOllamaWebSearchTool(
        input: MessageResponse.Content.Input,
        apiKey: String,
        settings: AppSettings
    ) async -> String {
        guard let query = input["query"]?.stringValue else {
            return "Error: missing 'query' parameter"
        }
        let maxResults = min(input["count"]?.intValue ?? 5, 10)

        guard let url = URL(string: "https://ollama.com/api/web_search") else {
            return "Error: failed to build Ollama search URL"
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["query": query, "max_results": maxResults]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return "Error: failed to encode request body"
        }
        request.httpBody = bodyData

        do {
            print("[ollama_web_search] Query: \(query)")
            let (data, response) = try await makeURLSession(for: url, settings: settings).data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[ollama_web_search] HTTP status: \(statusCode), data size: \(data.count) bytes")
            if !(200...299).contains(statusCode) {
                let body = String(data: data, encoding: .utf8)?.prefix(300) ?? "(unreadable)"
                return "Error: Ollama web search returned HTTP \(statusCode): \(body)"
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let results = json["results"] as? [[String: Any]]
            else {
                return "Error: unexpected response format from Ollama web search"
            }

            if results.isEmpty {
                return "No results found for: \"\(query)\""
            }

            var lines = ["Search results for: \"\(query)\"\n"]
            for (idx, result) in results.enumerated() {
                let title   = result["title"]   as? String ?? ""
                let url     = result["url"]     as? String ?? ""
                let content = result["content"] as? String ?? ""
                lines.append("\(idx + 1). \(title)")
                lines.append("   \(url)")
                if !content.isEmpty { lines.append("   \(content)") }
                lines.append("")
            }
            return lines.joined(separator: "\n")
        } catch {
            print("[ollama_web_search] Request error: \(error)")
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - web_search

    func executeWebSearchTool(input: MessageResponse.Content.Input, settings: AppSettings) async -> String {
        guard let query = input["query"]?.stringValue else {
            return "Error: missing 'query' parameter"
        }
        let count = min(input["count"]?.intValue ?? 5, 10)

        guard var components = URLComponents(string: "https://www.bing.com/search") else {
            return "Error: failed to build search URL"
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "\(count)")
        ]
        guard let url = components.url else {
            return "Error: could not construct search URL"
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        do {
            print("[web_search] Fetching URL: \(url.absoluteString)")
            let (data, response) = try await makeURLSession(for: url, settings: settings).data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[web_search] HTTP status: \(statusCode), data size: \(data.count) bytes")
            if !(200...299).contains(statusCode) {
                print("[web_search] Non-2xx response body: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "(unreadable)")")
                return "Error: Bing returned HTTP \(statusCode)"
            }
            let finalURL = (response as? HTTPURLResponse)?.url?.absoluteString ?? url.absoluteString
            if finalURL != url.absoluteString {
                print("[web_search] Redirected to: \(finalURL)")
            }
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            print("[web_search] HTML length: \(html.count) chars, starts with: \(html.prefix(200).replacingOccurrences(of: "\n", with: " "))")
            return await Task.detached(priority: .userInitiated) {
                Self.parseBingSearchResults(html: html, query: query, maxCount: count)
            }.value
        } catch {
            print("[web_search] Request error: \(error)")
            return "Error: \(error.localizedDescription)"
        }
    }

    nonisolated private static func parseBingSearchResults(html: String, query: String, maxCount: Int) -> String {
        var results: [(title: String, url: String, snippet: String)] = []

        // Each Bing organic result lives in <li class="b_algo ...">...</li>
        let blockPat   = #"<li\s[^>]*\bclass="b_algo[^"]*"[^>]*>([\s\S]*?)</li>"#
        // h2 may contain nested tags before <a>; <a> may have class/other attrs before href
        let titlePat   = ##"<h2[^>]*>[\s\S]*?<a\s[^>]*\bhref="(https?://[^"]*)"[^>]*>([\s\S]*?)</a>"##
        let snippetPat = #"<p\b[^>]*>([\s\S]*?)</p>"#

        guard
            let blockRx = try? NSRegularExpression(pattern: blockPat),
            let titleRx = try? NSRegularExpression(pattern: titlePat),
            let snippRx = try? NSRegularExpression(pattern: snippetPat)
        else { return "Error: regex compile failed" }

        let nsHtml = html as NSString
        let fullRange = NSRange(location: 0, length: nsHtml.length)

        let blockMatches = blockRx.matches(in: html, range: fullRange)
        print("[web_search] b_algo blocks found: \(blockMatches.count)")

        for (idx, match) in blockMatches.prefix(maxCount).enumerated() {
            let block = nsHtml.substring(with: match.range(at: 1))
            if idx == 0 {
                print("[web_search] First block content (first 500 chars): \(block.prefix(500))")
            }
            let nsBlock = block as NSString
            let blockRange = NSRange(location: 0, length: nsBlock.length)

            var title = ""
            var resultURL = ""
            if let tm = titleRx.firstMatch(in: block, range: blockRange) {
                resultURL = nsBlock.substring(with: tm.range(at: 1))
                title = stripHTMLTags(nsBlock.substring(with: tm.range(at: 2)))
            }

            var snippet = ""
            for sm in snippRx.matches(in: block, range: blockRange) {
                let candidate = stripHTMLTags(nsBlock.substring(with: sm.range(at: 1)))
                if candidate.count > 20 {
                    snippet = candidate
                    break
                }
            }

            if !title.isEmpty && !resultURL.isEmpty {
                print("[web_search] Result: \(title) | \(resultURL)")
                results.append((title: title, url: resultURL, snippet: snippet))
            } else {
                print("[web_search] Skipped block — title: '\(title)', url: '\(resultURL)'")
            }
        }

        print("[web_search] Total parsed results: \(results.count)")
        if results.isEmpty {
            return "No results found for: \"\(query)\". Bing may have blocked the request or changed its HTML layout."
        }

        var lines = ["Search results for: \"\(query)\"\n"]
        for (idx, r) in results.enumerated() {
            lines.append("\(idx + 1). \(r.title)")
            lines.append("   \(r.url)")
            if !r.snippet.isEmpty { lines.append("   \(r.snippet)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func stripHTMLTags(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")
        ]
        for (e, r) in entities { text = text.replacingOccurrences(of: e, with: r) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - web_fetch

    func executeWebFetchTool(input: MessageResponse.Content.Input, settings: AppSettings) async -> String {
        guard let urlString = input["url"]?.stringValue else {
            return "Error: missing 'url' parameter"
        }
        guard
            let url = URL(string: urlString),
            url.scheme == "https" || url.scheme == "http"
        else {
            return "Error: invalid or unsupported URL '\(urlString)'"
        }
        let maxChars = min(input["max_chars"]?.intValue ?? 8000, 32000)

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await makeURLSession(for: url, settings: settings).data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return "Error: HTTP \(http.statusCode) fetching '\(urlString)'"
            }
            // Detect encoding from Content-Type or fall back
            let mimeType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let raw: String
            if mimeType.contains("charset=utf-8") || mimeType.contains("charset=UTF-8") {
                raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            } else {
                raw = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
            }
            let finalURL = (response as? HTTPURLResponse)?.url?.absoluteString ?? urlString
            return await Task.detached(priority: .userInitiated) {
                Self.extractTextFromHTML(raw, maxChars: maxChars, url: finalURL)
            }.value
        } catch {
            return "Error fetching '\(urlString)': \(error.localizedDescription)"
        }
    }

    // MARK: - HTML → Plain Text

    nonisolated static func extractTextFromHTML(_ html: String, maxChars: Int, url: String) -> String {
        var text = html

        // Remove doctype / XML declarations
        text = text.replacingOccurrences(of: "<!\\s*[Dd][Oo][Cc][Tt][Yy][Pp][Ee][^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<\\?xml[^?]*\\?>", with: "", options: .regularExpression)

        // Remove script / style / noscript / template with content
        for tag in ["script", "style", "noscript", "template", "svg", "canvas"] {
            let pattern = "<" + tag + "(\\s[^>]*)?>([\\s\\S]*?)</" + tag + ">"
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        // Remove nav / header / footer / aside structural elements with content
        for tag in ["nav", "header", "footer", "aside", "menu", "dialog"] {
            let pattern = "<" + tag + "(\\s[^>]*)?>([\\s\\S]*?)</" + tag + ">"
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        // Replace block-level elements with newlines
        for tag in ["p", "div", "section", "article", "main", "blockquote",
                    "h1", "h2", "h3", "h4", "h5", "h6",
                    "li", "tr", "thead", "tbody", "tfoot", "br", "hr"] {
            text = text.replacingOccurrences(of: "<" + tag + "(\\s[^>]*)?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: "</" + tag + ">", with: "\n", options: [.regularExpression, .caseInsensitive])
        }

        // Strip all remaining HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Decode common HTML entities
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&laquo;", "«"), ("&raquo;", "»"), ("&hellip;", "…"),
            ("&copy;", "©"), ("&reg;", "®"), ("&trade;", "™")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric HTML entities &#NNNN; and &#xHHHH;
        text = text.replacingOccurrences(of: "&#x[0-9a-fA-F]+;|&#[0-9]+;", with: " ", options: .regularExpression)

        // Collapse horizontal whitespace
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        // Collapse excessive newlines
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        // Trim each line and drop blank lines clusters
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        text = lines.joined(separator: "\n")

        let truncated = text.count > maxChars
        let output = truncated ? String(text.prefix(maxChars)) : text
        let header = "Content from: \(url)\n" + String(repeating: "-", count: 60) + "\n"
        return header + output + (truncated ? "\n\n[Truncated at \(maxChars) characters]" : "")
    }
}
