import Testing
@testable import Nobet

struct GlassKitTests {
    @Test func givenRangeWinsOverData() {
        #expect(AreaSpark.domain([20, 30], range: 0...100) == 0...100)
    }

    @Test func dataRangeIsUsedWithoutGivenRange() {
        #expect(AreaSpark.domain([5, 9, 7], range: nil) == 5...9)
    }

    @Test func flatSeriesGetsANonEmptyDomain() {
        let flat = AreaSpark.domain([4, 4, 4], range: nil)
        #expect(flat.lowerBound < flat.upperBound)
        #expect(flat.contains(4))
    }

    @Test func emptySeriesDoesNotCrash() {
        let none = AreaSpark.domain([], range: nil)
        #expect(none.lowerBound < none.upperBound)
    }

    @Test func severityColorsStayDistinct() {
        #expect(SeverityDonut.color(.high) != SeverityDonut.color(.medium))
        #expect(SeverityDonut.color(.medium) != SeverityDonut.color(.info))
    }
}
