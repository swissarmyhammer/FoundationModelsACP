import Foundation
import Testing

import FoundationModelsACP

// MARK: - AbsolutePath (spec §4: all paths on the wire are absolute)

@Test func absolutePathAcceptsAbsolutePaths() throws {
    let decoded = try JSONDecoder().decode(AbsolutePath.self, from: Data("\"/abs/path\"".utf8))
    #expect(decoded.rawValue == "/abs/path")
    #expect(AbsolutePath(rawValue: "/")?.rawValue == "/")
}

@Test func absolutePathEncodesAsBareString() throws {
    let path = try #require(AbsolutePath(rawValue: "/abs/path"))
    let data = try JSONEncoder().encode(path)
    #expect(String(decoding: data, as: UTF8.self) == "\"\\/abs\\/path\"" || String(decoding: data, as: UTF8.self) == "\"/abs/path\"")
}

@Test func absolutePathRejectsRelativePathsAtDecode() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AbsolutePath.self, from: Data("\"relative/path\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AbsolutePath.self, from: Data("\"./dotted\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AbsolutePath.self, from: Data("\"\"".utf8))
    }
}

@Test func absolutePathRejectsRelativePathsAtInit() {
    #expect(AbsolutePath(rawValue: "relative/path") == nil)
    #expect(AbsolutePath(rawValue: "") == nil)
    #expect(AbsolutePath(rawValue: "~/home") == nil)
}

// MARK: - LineNumber (spec §4: line numbers are 1-based)

@Test func lineNumberAcceptsOneBasedValues() throws {
    let decoded = try JSONDecoder().decode(LineNumber.self, from: Data("1".utf8))
    #expect(decoded.rawValue == 1)
    #expect(LineNumber(rawValue: 42)?.rawValue == 42)
}

@Test func lineNumberEncodesAsBareInteger() throws {
    let line = try #require(LineNumber(rawValue: 7))
    let data = try JSONEncoder().encode(line)
    #expect(String(decoding: data, as: UTF8.self) == "7")
}

@Test func lineNumberRejectsZeroAndNegativesAtDecode() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(LineNumber.self, from: Data("0".utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(LineNumber.self, from: Data("-5".utf8))
    }
}

@Test func lineNumberRejectsZeroAndNegativesAtInit() {
    #expect(LineNumber(rawValue: 0) == nil)
    #expect(LineNumber(rawValue: -1) == nil)
}
