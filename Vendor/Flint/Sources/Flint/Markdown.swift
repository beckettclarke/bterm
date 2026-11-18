import Foundation

/// Just enough Markdown → HTML for release notes: headings, paragraphs, lists,
/// quotes, rules, fenced code, and inline code / bold / italic / links.
enum Markdown {
    static func html(_ markdown: String) -> String {
        var out = ""
        var paragraph: [String] = []
        var list: String?
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out += "<p>\(inline(paragraph.joined(separator: " ")))</p>\n"
            paragraph = []
        }
        func closeList() {
            if let tag = list { out += "</\(tag)>\n"; list = nil }
        }
        func block(_ html: String) {
            flushParagraph(); closeList(); out += html + "\n"
        }

        for line in markdown.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                block(inCode ? "</code></pre>" : "<pre><code>")
                inCode.toggle()
                continue
            }
            if inCode { out += escape(line) + "\n"; continue }

            if t.isEmpty { flushParagraph(); closeList(); continue }
            if let level = heading(t) {
                let text = t.dropFirst(level).trimmingCharacters(in: .whitespaces)
                block("<h\(level)>\(inline(text))</h\(level)>")
            } else if ["---", "***", "___"].contains(t) {
                block("<hr>")
            } else if t.hasPrefix(">") {
                block("<blockquote><p>\(inline(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)))</p></blockquote>")
            } else if let (tag, item) = listItem(t) {
                flushParagraph()
                if list != tag { closeList(); out += "<\(tag)>\n"; list = tag }
                out += "<li>\(inline(item))</li>\n"
            } else {
                if list != nil { closeList() }
                paragraph.append(t)
            }
        }
        flushParagraph(); closeList()
        if inCode { out += "</code></pre>\n" }
        return out
    }

    private static func heading(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> (String, String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return ("ul", String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: \.isNumber)
        let rest = line.dropFirst(digits.count)
        if !digits.isEmpty, rest.hasPrefix(". ") || rest.hasPrefix(") ") {
            return ("ol", String(rest.dropFirst(2)))
        }
        return nil
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let rules: [(NSRegularExpression, String)] = [
        (#"\[([^\]]+)\]\(([^)\s]+)\)"#, #"<a href="$2">$1</a>"#),
        (#"\*\*(.+?)\*\*"#, "<strong>$1</strong>"),
        (#"__(.+?)__"#, "<strong>$1</strong>"),
        (#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "<em>$1</em>"),
        (#"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, "<em>$1</em>"),
        (#"~~(.+?)~~"#, "<del>$1</del>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static func inline(_ text: String) -> String {
        // Pull out code spans first so their contents aren't formatted.
        var spans: [String] = []
        var s = ""
        let parts = text.components(separatedBy: "`")
        for (i, part) in parts.enumerated() {
            if i % 2 == 1, i < parts.count - 1 {
                s += "\u{1}\(spans.count)\u{1}"
                spans.append("<code>\(escape(part))</code>")
            } else {
                s += (i % 2 == 1 ? "`" : "") + escape(part)
            }
        }
        for (regex, template) in rules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        for (i, span) in spans.enumerated() {
            s = s.replacingOccurrences(of: "\u{1}\(i)\u{1}", with: span)
        }
        return s
    }
}
