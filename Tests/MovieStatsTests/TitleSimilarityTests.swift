import Testing
@testable import MovieStats

@Suite("TitleSimilarity")
struct TitleSimilarityTests {
    @Test("normalize folds & to 'and' and strips punctuation")
    func normalizeFoldsAmpersand() {
        #expect(TitleSimilarity.normalize("Mr. & Mrs. Smith")
                == TitleSimilarity.normalize("Mr and Mrs Smith"))
        #expect(TitleSimilarity.normalize("Mr. & Mrs. Smith") == "mr and mrs smith")
    }

    @Test("normalize collapses separators and lowercases")
    func normalizeSeparators() {
        #expect(TitleSimilarity.normalize("Spider-Man: No_Way Home") == "spider man no way home")
    }

    @Test("Identical (post-normalization) titles score 1.0")
    func identicalRatio() {
        #expect(TitleSimilarity.ratio("The Matrix", "the matrix") == 1.0)
        #expect(TitleSimilarity.ratio("Mr & Mrs Smith", "Mr. and Mrs. Smith") == 1.0)
    }

    @Test("Near-identical titles clear the 0.80 fuzzy threshold")
    func fuzzyAboveThreshold() {
        // A single dropped separator/char — comfortably above 0.80.
        #expect(TitleSimilarity.ratio("Wall-E", "WallE") >= 0.80)
        #expect(TitleSimilarity.ratio("The Lord of the Rings", "Lord of the Rings") < 1.0)
    }

    @Test("Unrelated titles score well below the threshold")
    func unrelatedBelowThreshold() {
        #expect(TitleSimilarity.ratio("Cat", "Dog") < 0.80)
    }

    @Test("Empty input yields 0 unless both normalize identically")
    func emptyInput() {
        #expect(TitleSimilarity.ratio("", "Something") == 0.0)
    }
}
