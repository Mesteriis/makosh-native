import XCTest
import MakoshCodeHighlight
@testable import MakoshTelegram

final class TelegramCodeHighlightNativeTests: XCTestCase {
    func testPinnedSwiftGrammarEmitsSemanticLeafRanges() throws {
        let result = try parse("let answer = 42 // comment", language: "swift")
        XCTAssertEqual(result.status, MKCodeHighlightSuccess)
        XCTAssertTrue(result.spans.contains { $0.offset == 0 && $0.length == 3 && $0.role == 6 })
        XCTAssertTrue(result.spans.contains { $0.offset == 13 && $0.length == 2 && $0.role == 3 })
        XCTAssertTrue(result.spans.contains { $0.offset == 16 && $0.length == 10 && $0.role == 1 })
    }

    func testEveryPinnedCatalogAliasIsAcceptedWithoutGuessingLanguage() throws {
        let aliases = Self.catalog.split(separator: " ")
        XCTAssertEqual(aliases.count, 384)
        for alias in aliases {
            let result = try parse("x", language: String(alias))
            XCTAssertEqual(result.status, MKCodeHighlightSuccess, String(alias))
            guard result.status == MKCodeHighlightSuccess else { return }
        }
        for alias in ["", "unrecognized-language", "c++", "python\0x", "swift\n"] {
            let result = try parse("let x = 2", language: alias)
            XCTAssertNotEqual(result.status, MKCodeHighlightSuccess, alias)
            XCTAssertTrue(result.spans.isEmpty)
        }
    }

    func testNativeLengthDelimitedSourceContinuesAfterEmbeddedNUL() throws {
        let result = try parse("😀\0let x = 2\r\n", language: "swift")
        XCTAssertEqual(result.status, MKCodeHighlightSuccess)
        XCTAssertTrue(result.spans.contains { $0.offset == 5 && $0.length == 3 && $0.role == 6 })
        XCTAssertTrue(result.spans.contains { $0.offset == 13 && $0.length == 1 && $0.role == 3 })
    }

    func testPreCancelledRequestCannotPublishPartialSpans() throws {
        let result = try parse("let x = 2", language: "swift", cancelled: true)
        XCTAssertEqual(result.status, MKCodeHighlightAborted)
        XCTAssertTrue(result.spans.isEmpty)
    }

    func testMalformedUTF8AndExcessUTF16CannotEnterNativeGrammar() throws {
        for bytes: [UInt8] in [[255], [192, 128], [237, 160, 128], [244, 144, 128, 128], [240, 159, 152]] {
            let invalid = try parseBytes(bytes, language: "swift")
            XCTAssertEqual(invalid.status, MKCodeHighlightInvalid)
            XCTAssertTrue(invalid.spans.isEmpty)
        }
        let tooManyUnits = try parse(String(repeating: "😀", count: 32768), language: "swift")
        XCTAssertEqual(tooManyUnits.status, MKCodeHighlightInvalid)
        XCTAssertTrue(tooManyUnits.spans.isEmpty)
    }

    func testCapacityExhaustionAndOversizedInputCannotPublishPartialSpans() throws {
        let crowded = try parse("let a = 1; let b = 2", language: "swift", capacity: 1)
        XCTAssertEqual(crowded.status, MKCodeHighlightAborted)
        XCTAssertTrue(crowded.spans.isEmpty)
        let oversized = try parse(String(repeating: "x", count: 131073), language: "swift")
        XCTAssertEqual(oversized.status, MKCodeHighlightInvalid)
        XCTAssertTrue(oversized.spans.isEmpty)
    }

    func testNestedInputProducesSourceBoundRangesOrCleanAbort() throws {
        let nested = "let value = \"" + String(repeating: "\\(", count: 200) + "1" + String(repeating: ")", count: 200) + "\""
        let result = try parse(nested, language: "swift")
        if result.status == MKCodeHighlightSuccess {
            XCTAssertNotNil(TelegramCodeHighlight(source: nested, byteSpans: result.spans.map {
                .init(offset: $0.offset, length: $0.length, role: $0.role)
            }))
        } else {
            XCTAssertEqual(result.status, MKCodeHighlightAborted)
            XCTAssertTrue(result.spans.isEmpty)
        }
    }

    func testTokenFloodCannotPublishPartialOutput() throws {
        let flooded = try parse(String(repeating: "let x=1;", count: 4000), language: "swift")
        XCTAssertEqual(flooded.status, MKCodeHighlightAborted)
        XCTAssertTrue(flooded.spans.isEmpty)
    }

    func testAsyncWrapperPreservesUnicodeAndCaseInsensitiveReferenceAlias() async throws {
        let source = "😀\0let e\u{301} = 2\r\n"
        let parsed = await TelegramCodeHighlighter.highlight(source: source, language: "SwIfT")
        guard let result = parsed else { XCTFail("A supported bounded source must be highlighted"); return }
        XCTAssertTrue(result.matches(source))
        XCTAssertTrue(result.spans.contains { $0.range == NSRange(location: 3, length: 3) && $0.role == .blue })
        XCTAssertTrue(result.spans.contains { $0.range == NSRange(location: 12, length: 1) && $0.role == .green })
        let python = await TelegramCodeHighlighter.highlight(source: "def f():\n return True", language: "py")
        XCTAssertNotNil(python)
        XCTAssertTrue(python?.spans.contains { $0.range == NSRange(location: 0, length: 3) && $0.role == .blue } == true)
    }

    func testAsyncWrapperRejectsInvalidLanguageOversizeAndCancelledTasks() async throws {
        for language in [nil, "", " swift", "swift\n", "swift\0x", "swıft", String(repeating: "x", count: 65)] as [String?] {
            let result = await TelegramCodeHighlighter.highlight(source: "let x = 2", language: language)
            XCTAssertNil(result)
        }
        let oversized = await TelegramCodeHighlighter.highlight(source: String(repeating: "x", count: 32769), language: "swift")
        XCTAssertNil(oversized)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TelegramCodeHighlighter.highlight(source: "let x = 2", language: "swift")
        }
        let cancelled = await task.value
        XCTAssertNil(cancelled)
    }

    func testParallelOwnedRequestsCannotExchangeSourceOrLanguage() async throws {
        async let swift = TelegramCodeHighlighter.highlight(source: "let one = 1", language: "swift")
        async let python = TelegramCodeHighlighter.highlight(source: "def two(): return 2", language: "python")
        let results = await (swift, python)
        guard let first = results.0, let second = results.1 else {
            XCTFail("Both independently owned local requests must finish"); return
        }
        XCTAssertTrue(first.matches("let one = 1"))
        XCTAssertTrue(second.matches("def two(): return 2"))
        XCTAssertFalse(results.0?.matches("def two(): return 2") ?? true)
    }

    private func parse(_ source: String, language: String, cancelled: Bool = false, capacity: Int = 8192) throws
        -> (status: MKCodeHighlightStatus, spans: [MKCodeHighlightSpan]) {
        try parseBytes(Array(source.utf8), language: language, cancelled: cancelled, capacity: capacity)
    }

    private func parseBytes(_ bytes: [UInt8], language: String, cancelled: Bool = false, capacity: Int = 8192) throws
        -> (status: MKCodeHighlightStatus, spans: [MKCodeHighlightSpan]) {
        guard let token = mk_code_highlight_cancellation_create() else {
            XCTFail("A bounded local request must allocate its cancellation token")
            return (MKCodeHighlightInvalid, [])
        }
        defer { mk_code_highlight_cancellation_destroy(token) }
        if cancelled { mk_code_highlight_cancellation_cancel(token) }
        let hint = Array(language.utf8)
        var spans = [MKCodeHighlightSpan](repeating: .init(offset: 0, length: 0, role: 0), count: capacity)
        var written = 12345
        let status = bytes.withUnsafeBufferPointer { source in
            hint.withUnsafeBufferPointer { language in
                spans.withUnsafeMutableBufferPointer { output in
                    mk_code_highlight(source.baseAddress, source.count, language.baseAddress, language.count,
                        token, output.baseAddress, output.count, &written)
                }
            }
        }
        XCTAssertLessThanOrEqual(written, capacity)
        guard (0...capacity).contains(written) else { return (status, []) }
        if status != MKCodeHighlightSuccess { XCTAssertEqual(written, 0) }
        return (status, Array(spans.prefix(written)))
    }

    // Catalog independently read from the selected 23b0d70 grammars.dat.
    private static let catalog = "markup html xml svg mathml ssml atom rss css clike regex javascript js abap abnf actionscript ada agda al antlr4 g4 apacheconf sql apex apl applescript aql c cpp arduino ino arff armasm arm-asm bash sh shell yaml yml markdown md arturo art asciidoc adoc csharp cs dotnet aspnet asm6502 asmatmel autohotkey autoit avisynth avs avro-idl avdl awk gawk basic batch bbcode shortcode bbj bicep birb bison bnf rbnf bqn brainfuck brightscript bro cfscript cfc chaiscript cil cilkc cilk-c cilkcpp cilk-cpp cilk clojure cmake cobol coffeescript coffee concurnas conc csp cooklang ruby rb crystal csv cue cypher d dart dataweave dax dhall diff markup-templating django jinja2 dns-zone-file dns-zone docker dockerfile dot gv ebnf editorconfig eiffel ejs eta elixir elm lua etlua erb erlang excel-formula xlsx xls fsharp factor false firestore-security-rules flow fortran ftl gml gamemakerlanguage gap gcode gdscript gedcom gettext po git glsl gn gni linker-script ld go go-module go-mod gradle graphql groovy less scss textile haml handlebars hbs mustache haskell hs haxe hcl hlsl hoon hpkp hsts json webmanifest uri url http ichigojam icon icu-message-format idris idr ignore gitignore hgignore npmignore inform7 ini io j java scala php javadoclike javadoc javastacktrace jolie jq typescript ts jsdoc n4js n4jsd json5 jsonp jsstacktrace julia keepalived keyman kotlin kt kts kusto latex tex context latte scheme lilypond ly liquid lisp emacs elisp emacs-lisp livescript llvm log lolcode magma makefile mata matlab maxscript mel mermaid metafont mizar mongodb monkey moonscript moon n1ql nand2tetris-hdl naniscript nani nasm neon nevod nginx nim nix nsis objectivec objc ocaml odin opencl openqasm qasm oz parigp parser pascal objectpascal pascaligo psl pcaxis px peoplecode pcode perl phpdoc plant-uml plantuml plsql powerquery pq mscript powershell processing prolog promql properties protobuf stylus twig pug puppet purebasic pbfasm python py qsharp qs q qml qore r racket rkt cshtml razor jsx tsx reason rego renpy rpy rescript res rest rip roboconf robotframework robot rust sas sass shell-session sh-session shellsession smali smalltalk smarty sml smlnj solidity sol solution-file sln soy splunk-spl sqf squirrel stan stata iecst supercollider sclang swift systemd t4-templating t4-cs t4 vbnet t4-vb tap tcl tt2 toml tremor trickle troy typoscript tsconfig unrealscript uscript uc uorazor v vala velocity verilog vhdl vim visual-basic vb vba warpscript wasm web-idl webidl wgsl wiki wolfram mathematica nb wl wren xeora xeoracube xojo xquery yang zig typelanguage tl"
}
