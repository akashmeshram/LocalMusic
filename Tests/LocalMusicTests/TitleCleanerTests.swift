import Testing
import Foundation
@testable import LocalMusicCore

@Suite("TitleCleaner")
struct TitleCleanerTests {
    @Test func stripsBracketedNoise() {
        #expect(TitleCleaner.clean("Daft Punk - Get Lucky (Official Video)") == "Daft Punk - Get Lucky")
        #expect(TitleCleaner.clean("Song Title [Official Audio]") == "Song Title")
        #expect(TitleCleaner.clean("Song Title (Lyrics)") == "Song Title")
        #expect(TitleCleaner.clean("Song Title (Official Lyric Video) [HD]") == "Song Title")
        #expect(TitleCleaner.clean("Song Title (4K) (Visualizer)") == "Song Title")
        #expect(TitleCleaner.clean("Song Title (Remastered 2011)") == "Song Title")
        #expect(TitleCleaner.clean("Song Title (2011 Remaster)") == "Song Title")
    }

    @Test func keepsMeaningfulBrackets() {
        #expect(TitleCleaner.clean("Song (feat. Someone)") == "Song (feat. Someone)")
        #expect(TitleCleaner.clean("Song (Live at Wembley)") == "Song (Live at Wembley)")
        #expect(TitleCleaner.clean("Song (Radio Edit)") == "Song (Radio Edit)")
        #expect(TitleCleaner.clean("Song (Acoustic Version)") == "Song (Acoustic Version)")
    }

    @Test func stripsTrailingNoise() {
        #expect(TitleCleaner.clean("Artist - Song | Official Video") == "Artist - Song")
        #expect(TitleCleaner.clean("Artist - Song HD") == "Artist - Song")
        #expect(TitleCleaner.clean("Artist - Song - Official Audio") == "Artist - Song")
        #expect(TitleCleaner.clean("Artist - Song 4K") == "Artist - Song")
    }

    @Test func splitsArtistAndTitle() {
        let r = TitleCleaner.parse("Daft Punk - Get Lucky (Official Video)", uploader: "DaftPunkVEVO")
        #expect(r.artist == "Daft Punk")
        #expect(r.title == "Get Lucky")
        let r2 = TitleCleaner.parse("Björk – Jóga", uploader: nil)
        #expect(r2.artist == "Björk" && r2.title == "Jóga")
        let r3 = TitleCleaner.parse("Get Lucky - Daft Punk", uploader: "Daft Punk - Topic")
        #expect(r3.artist == "Daft Punk" && r3.title == "Get Lucky")
    }

    @Test func toleratesMissingSpaceAroundDash() {
        let r = TitleCleaner.parse("Vansire -Nice To See You", uploader: "Brian Yu")
        #expect(r.artist == "Vansire" && r.title == "Nice To See You")
        let r2 = TitleCleaner.parse("Vansire- Nice To See You")
        #expect(r2.artist == "Vansire" && r2.title == "Nice To See You")
        let hyphenated = TitleCleaner.parse("Jay-Z Song")
        #expect(hyphenated.artist == nil && hyphenated.title == "Jay-Z Song")
    }

    @Test func cleansEachSideAfterSplitting() {
        let r = TitleCleaner.parse("Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film", uploader: "Blender")
        #expect(r.title == "Big Buck Bunny")
        #expect(r.artist == "Official Blender Foundation Short Film")
    }

    @Test func extractsYearAndFeaturing() {
        let r = TitleCleaner.parse("Artist - Song feat. Guest (2019)")
        #expect(r.year == 2019 && r.title == "Song" && r.featuring == "Guest" && r.artist == "Artist")
        let r2 = TitleCleaner.parse("Artist ft. Other - Song")
        #expect(r2.artist == "Artist" && r2.featuring == "Other" && r2.title == "Song")
    }

    @Test func leavesPlainTitlesAlone() {
        let r = TitleCleaner.parse("Just A Title")
        #expect(r.artist == nil && r.title == "Just A Title" && r.year == nil)
        #expect(TitleCleaner.clean("(Official Video)") == "(Official Video)") // never returns empty
    }

    @Test func uploaderCleanup() {
        #expect(TitleCleaner.cleanUploader("Daft Punk - Topic") == "Daft Punk")
        #expect(TitleCleaner.cleanUploader("DaftPunkVEVO") == "DaftPunk")
        #expect(TitleCleaner.cleanUploader("") == nil)
    }
}
