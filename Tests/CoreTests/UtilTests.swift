import Foundation
import Testing
@testable import BarbackCore

struct ShellLexerTests {
    @Test func splitsSimpleWords() throws {
        #expect(try ShellLexer.tokenize("foo bar baz") == ["foo", "bar", "baz"])
    }

    @Test func handlesQuotesAndEscapes() throws {
        #expect(try ShellLexer.tokenize("foo 'bar baz' \"qux quux\"") == ["foo", "bar baz", "qux quux"])
        #expect(try ShellLexer.tokenize(#"a\ b"#) == ["a b"])
    }

    @Test func unterminatedQuoteThrows() {
        #expect(throws: ShellLexerError.unterminatedQuote) {
            try ShellLexer.tokenize("foo 'bar")
        }
    }
}

struct SupervisorImporterTests {
    @Test func parsesBasicProgramSection() {
        let ini = """
        [program:nslocal]
        command=/usr/local/bin/nslocal -c /etc/nslocal.conf
        directory=/Users/oyasmi
        autostart=true
        autorestart=unexpected
        startsecs=5
        startretries=3
        stopsignal=TERM
        stopasgroup=true
        killasgroup=true
        stdout_logfile=/var/log/nslocal.log
        redirect_stderr=true
        """
        let previews = SupervisorImporter.parse(ini)
        #expect(previews.count == 1)
        let p = previews[0].program
        #expect(p.name == "nslocal")
        #expect(p.autostart == false) // always forced off on import
        #expect(p.autorestart == .unexpected)
        #expect(p.stopAsGroup == true)
        #expect(p.logMergeStderr == true)
    }

    @Test func shCPrefixEnablesUseShell() {
        let ini = """
        [program:job]
        command=sh -c 'foo ; bar'
        """
        let previews = SupervisorImporter.parse(ini)
        #expect(previews[0].program.useShell == true)
        #expect(previews[0].program.command == "foo ; bar")
    }

    @Test func unmappedFieldsAreReported() {
        let ini = """
        [program:job]
        command=/bin/true
        user=nobody
        numprocs=2
        """
        let previews = SupervisorImporter.parse(ini)
        let keys = Set(previews[0].unmapped.map(\.key))
        #expect(keys.contains("user"))
        #expect(keys.contains("numprocs"))
    }
}

struct ProgramValidatorTests {
    @Test func rejectsInvalidName() {
        let p = Program(name: "bad name!", kind: .service, command: "/bin/true")
        let errors = ProgramValidator.validate(p, existingNames: [])
        #expect(errors.contains(.invalidName))
    }

    @Test func rejectsDuplicateName() {
        let p = Program(name: "dup", kind: .service, command: "/bin/true")
        let errors = ProgramValidator.validate(p, existingNames: ["dup"])
        #expect(errors.contains(.duplicateName))
    }

    @Test func rejectsEmptyCommand() {
        let p = Program(name: "ok", kind: .service, command: "   ")
        let errors = ProgramValidator.validate(p, existingNames: [])
        #expect(errors.contains(.emptyCommand))
    }
}
