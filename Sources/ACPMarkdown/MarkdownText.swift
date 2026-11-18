/// The text helpers of the Markdown renderer.
///
/// Each helper gives `\n` line ends and no line end at the end.
enum MarkdownText {
    /// Changes `\r\n` and `\r` to `\n`.
    ///
    /// - Parameter text: The text.
    /// - Returns: The text with `\n` line ends.
    static func normalizedLineEnds(_ text: String) -> String {
        text.replacing("\r\n", with: "\n").replacing("\r", with: "\n")
    }

    /// Removes the empty lines and the white space at the start and at the
    /// end of a block of text. The indentation of the first line that has
    /// text stays.
    ///
    /// - Parameter text: The text.
    /// - Returns: The trimmed text.
    static func trimmed(_ text: String) -> String {
        let lines = normalizedLineEnds(text).split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.firstIndex(where: { !isBlank($0) }),
            let last = lines.lastIndex(where: { !isBlank($0) })
        else {
            return ""
        }
        return trimmedTrailing(lines[first...last].joined(separator: "\n"))
    }

    /// Removes the white space and the line ends at the end of the text.
    ///
    /// - Parameter text: The text.
    /// - Returns: The trimmed text.
    static func trimmedTrailing(_ text: String) -> String {
        var result = normalizedLineEnds(text)
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }

    /// Makes one line from a text: each line end becomes a space, and the
    /// white space at the two ends goes.
    ///
    /// - Parameter text: The text.
    /// - Returns: The line.
    static func singleLine(_ text: String) -> String {
        normalizedLineEnds(text)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingWhitespace() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Escapes the characters that would end strong emphasis or start HTML
    /// in a line.
    ///
    /// - Parameter text: The text of one line.
    /// - Returns: The escaped text.
    static func escapeInline(_ text: String) -> String {
        var result = ""
        for character in text {
            if character == "\\" || character == "*" || character == "<" || character == "`" {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    /// Escapes the characters that HTML gives a meaning to.
    ///
    /// - Parameter text: The text.
    /// - Returns: The escaped text.
    static func escapeHTML(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
    }

    /// Makes a line in italics.
    ///
    /// - Parameter text: The text.
    /// - Returns: The line.
    static func italic(_ text: String) -> String {
        "*" + escapeInline(singleLine(text)) + "*"
    }

    /// Makes an HTML comment. A `--` in the text becomes `- -`, because a
    /// comment cannot hold it.
    ///
    /// - Parameter text: The text of the comment.
    /// - Returns: The comment.
    static func comment(_ text: String) -> String {
        var body = singleLine(text)
        while body.contains("--") {
            body = body.replacing("--", with: "- -")
        }
        return "<!-- \(body) -->"
    }

    /// Makes a quote: `> ` before each line, and `>` for an empty line.
    ///
    /// - Parameter text: The text.
    /// - Returns: The quote.
    static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    /// Makes a `<details>` block.
    ///
    /// - Parameters:
    ///   - summary: The text of the summary. The function escapes it.
    ///   - body: The Markdown blocks in the block.
    /// - Returns: The block.
    static func details(summary: String, body: [String]) -> String {
        (["<details>\n<summary>\(escapeHTML(singleLine(summary)))</summary>"] + body + ["</details>"])
            .joined(separator: "\n\n")
    }

    /// Makes a fenced code block. The fence is one backtick longer than the
    /// longest run of backticks in the text, and at least three backticks.
    ///
    /// - Parameters:
    ///   - text: The text in the block.
    ///   - language: The language of the block, or `nil`.
    /// - Returns: The block.
    static func fenced(_ text: String, language: String?) -> String {
        let body = trimmedTrailingLineEnds(normalizedLineEnds(text))
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(body) + 1))
        if body.isEmpty {
            return fence + (language ?? "") + "\n" + fence
        }
        return fence + (language ?? "") + "\n" + body + "\n" + fence
    }

    /// Makes a code span. The delimiter is one backtick longer than the
    /// longest run of backticks in the text.
    ///
    /// - Parameter text: The text.
    /// - Returns: The code span.
    static func codeSpan(_ text: String) -> String {
        let line = singleLine(text)
        let delimiter = String(repeating: "`", count: longestBacktickRun(line) + 1)
        let pad = line.hasPrefix("`") || line.hasSuffix("`") ? " " : ""
        return delimiter + pad + line + pad + delimiter
    }

    /// Escapes the text of a link.
    ///
    /// - Parameter text: The text.
    /// - Returns: The escaped text.
    static func linkText(_ text: String) -> String {
        var result = ""
        for character in singleLine(text) {
            if character == "\\" || character == "[" || character == "]" {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    /// Makes the destination of a link. A destination with a space or a
    /// parenthesis goes in angle brackets.
    ///
    /// - Parameter uri: The URI.
    /// - Returns: The destination.
    static func linkDestination(_ uri: String) -> String {
        let line = singleLine(uri)
        guard line.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" || $0 == ">" }) else {
            return line
        }
        return "<" + line.replacing("<", with: "%3C").replacing(">", with: "%3E") + ">"
    }

    /// The length of the longest run of backticks in a text.
    ///
    /// - Parameter text: The text.
    /// - Returns: The length, or 0.
    static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    /// Removes the line ends at the end of the text. The white space on the
    /// last line stays.
    ///
    /// - Parameter text: The text.
    /// - Returns: The text.
    private static func trimmedTrailingLineEnds(_ text: String) -> String {
        var result = text
        while result.last == "\n" {
            result.removeLast()
        }
        return result
    }

    /// `true` when a line has only white space.
    ///
    /// - Parameter line: The line.
    /// - Returns: `true` for a blank line.
    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }
}

extension Substring {
    /// The text without the white space at the two ends.
    fileprivate func trimmingWhitespace() -> String {
        String(drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }
}
