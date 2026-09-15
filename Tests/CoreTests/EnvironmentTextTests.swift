import Testing
@testable import BarbackCore

struct EnvironmentTextTests {
    @Test func preservesValuesAndAcceptsBlankLines() {
        let result = EnvironmentText.parse("\nTOKEN=a=b==  \nEMPTY=\n\nPATH=/opt/bin:/usr/bin\n")
        #expect(result.errors.isEmpty)
        #expect(result.variables["TOKEN"]?.value == "a=b==  ")
        #expect(result.variables["EMPTY"]?.value == "")
        #expect(result.variables["PATH"]?.value == "/opt/bin:/usr/bin")
        #expect(result.variables.count == 3)
    }

    @Test func preservesSensitiveFlagAndWindowsLineEndings() {
        let result = EnvironmentText.parse("*TOKEN=secret\r\nPORT=8080\r\n")
        #expect(result.errors.isEmpty)
        #expect(result.variables["TOKEN"] == EnvVar(value: "secret", sensitive: true))
        #expect(result.variables["PORT"] == EnvVar(value: "8080"))
    }

    @Test func unfinishedInputIsAnErrorInsteadOfBeingSilentlyDropped() {
        let result = EnvironmentText.parse("PORT=8080\n\nTOKEN")
        #expect(result.errors == ["第 3 行：请使用 KEY=VALUE 格式"])
        #expect(result.variables["PORT"]?.value == "8080")
    }

    @Test func reportsDuplicateKeysWithoutExposingValues() {
        let result = EnvironmentText.parse("*TOKEN=first-secret\nTOKEN=second-secret")
        #expect(result.errors == ["第 2 行：变量名重复，请合并为一行"])
        #expect(result.variables["TOKEN"]?.sensitive == true)
    }

    @Test func rejectsEmptyNamesWhitespaceAndNul() {
        let result = EnvironmentText.parse("=value\n*=secret\nBAD KEY=value\nKEY=bad\0value")
        #expect(result.errors.count == 4)
        #expect(result.variables.isEmpty)
    }

    @Test func formatsDeterministicallyAndRoundTrips() {
        let variables = ["Z": EnvVar(value: "a=b"), "A": EnvVar(value: "secret", sensitive: true)]
        let text = EnvironmentText.format(variables)
        #expect(text == "*A=secret\nZ=a=b")
        let result = EnvironmentText.parse(text)
        #expect(result.errors.isEmpty)
        #expect(result.variables == variables)
    }
}
