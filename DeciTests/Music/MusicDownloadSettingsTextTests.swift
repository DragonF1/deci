// DeciTests/Music/MusicDownloadSettingsTextTests.swift
// The words and the rule of the Downloads section in Settings > General, as plain values: how a size and a count read
// (singular and plural, empty, still being measured), what the confirmation says it will delete, and when the Remove all
// button is enabled. No view, no disk, no clock.

import Foundation
import Testing
@testable import Deci

@Suite("MusicDownloadSettingsText")
struct MusicDownloadSettingsTextTests {
    private let english = Locale(identifier: "en_US")

    // MARK: - Sizes

    /// The size as the formatter writes it in this process's locale: the point of "1.5 MB" is the locale's own separator.
    private func localized(_ text: String) -> String {
        text.replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
    }

    @Test("a size reads in file units, as Finder counts them", arguments: [
        (Int64(1_000), "1 KB"),
        (Int64(4_096), "4 KB"),
        (Int64(999_000), "999 KB"),
        (Int64(1_500_000), "1.5 MB"),
        (Int64(250_000_000), "250 MB"),
        (Int64(2_300_000_000), "2.3 GB")
    ])
    func formatsSizes(bytes: Int64, expected: String) {
        #expect(MusicDownloadSettingsText.size(bytes) == localized(expected))
    }

    @Test("zero reads as a number, not a word")
    func zeroSize() {
        #expect(MusicDownloadSettingsText.size(0).contains("0"))
    }

    @Test("a size that is still being measured reads Calculating, and a measured one reads as its size")
    func sizeTextWhileMeasuring() {
        #expect(MusicDownloadSettingsText.sizeText(nil) == "Calculating")
        #expect(MusicDownloadSettingsText.sizeText(1_500_000) == localized("1.5 MB"))
        #expect(MusicDownloadSettingsText.sizeText(0) == MusicDownloadSettingsText.size(0))
    }

    @Test("a negative size, which no disk reports, reads as zero")
    func negativeSize() {
        #expect(MusicDownloadSettingsText.size(-5) == MusicDownloadSettingsText.size(0))
    }

    // MARK: - The count

    @Test("the summary names songs and playlists or albums, with the singular where it is one", arguments: [
        (0, 0, "Nothing downloaded"),
        (1, 0, "1 song"),
        (2, 0, "2 songs"),
        (0, 1, "1 playlist or album"),
        (0, 2, "2 playlists and albums"),
        (1, 1, "1 song, 1 playlist or album"),
        (1, 3, "1 song, 3 playlists and albums"),
        (12, 1, "12 songs, 1 playlist or album"),
        (12, 4, "12 songs, 4 playlists and albums"),
        (1_234, 0, "1,234 songs")
    ])
    func summary(songs: Int, collections: Int, expected: String) {
        #expect(MusicDownloadSettingsText.summary(songs: songs, collections: collections, locale: english) == expected)
    }

    @Test("a count that is not known yet reads Calculating, whichever half is missing")
    func summaryWhileCounting() {
        #expect(MusicDownloadSettingsText.summary(songs: nil, collections: nil, locale: english) == "Calculating")
        #expect(MusicDownloadSettingsText.summary(songs: 3, collections: nil, locale: english) == "Calculating")
        #expect(MusicDownloadSettingsText.summary(songs: nil, collections: 2, locale: english) == "Calculating")
    }

    @Test("a count below zero, which nothing reports, is read as none")
    func negativeCounts() {
        #expect(MusicDownloadSettingsText.summary(songs: -1, collections: -3, locale: english) == "Nothing downloaded")
        #expect(MusicDownloadSettingsText.summary(songs: -1, collections: 2, locale: english) == "2 playlists and albums")
    }

    // MARK: - The confirmation

    @Test("the confirmation says how much will go and that it can be downloaded again")
    func confirmationMessage() {
        #expect(
            MusicDownloadSettingsText.confirmationMessage(bytes: 1_500_000)
                == localized("1.5 MB will be deleted from this Mac. You can download them again.")
        )
        #expect(
            MusicDownloadSettingsText.confirmationMessage(bytes: 2_300_000_000)
                == localized("2.3 GB will be deleted from this Mac. You can download them again.")
        )
    }

    @Test("without a size the confirmation still says what happens")
    func confirmationWithoutASize() {
        #expect(
            MusicDownloadSettingsText.confirmationMessage(bytes: nil)
                == "Everything downloaded will be deleted from this Mac. You can download it again."
        )
    }

    @Test("the fixed words are the ones the section shows")
    func fixedWords() {
        #expect(MusicDownloadSettingsText.sectionTitle == "Downloads")
        #expect(MusicDownloadSettingsText.storageTitle == "Storage used")
        #expect(MusicDownloadSettingsText.removeTitle == "Remove all downloads")
        #expect(MusicDownloadSettingsText.removeDescription == "Deletes every downloaded song, playlist and album from this Mac.")
        #expect(MusicDownloadSettingsText.removeButton == "Remove all")
        #expect(MusicDownloadSettingsText.confirmationTitle == "Remove all downloads?")
        #expect(MusicDownloadSettingsText.confirmButton == "Remove")
    }

    @Test("nothing the section says holds an em-dash")
    func noEmDashes() {
        let words = [
            MusicDownloadSettingsText.sectionTitle, MusicDownloadSettingsText.storageTitle,
            MusicDownloadSettingsText.removeTitle, MusicDownloadSettingsText.removeDescription,
            MusicDownloadSettingsText.removeButton, MusicDownloadSettingsText.confirmationTitle,
            MusicDownloadSettingsText.confirmButton, MusicDownloadSettingsText.calculating,
            MusicDownloadSettingsText.confirmationMessage(bytes: 1),
            MusicDownloadSettingsText.confirmationMessage(bytes: nil),
            MusicDownloadSettingsText.summary(songs: 1, collections: 1, locale: english)
        ]
        for text in words { #expect(!text.contains("\u{2014}"), "\(text)") }
    }

    // MARK: - When the button works

    @Test("the button is enabled when something is downloaded and no removal runs")
    func enabledWithDownloads() {
        #expect(MusicDownloadSettingsText.canRemoveAll(songs: 1, collections: 0, hasFiles: true, isRemoving: false))
        #expect(MusicDownloadSettingsText.canRemoveAll(songs: 0, collections: 1, hasFiles: true, isRemoving: false))
        #expect(MusicDownloadSettingsText.canRemoveAll(songs: 5, collections: 2, hasFiles: nil, isRemoving: false))
        #expect(MusicDownloadSettingsText.canRemoveAll(songs: 5, collections: nil, hasFiles: nil, isRemoving: false))
        #expect(MusicDownloadSettingsText.canRemoveAll(songs: nil, collections: 2, hasFiles: nil, isRemoving: false))
    }

    @Test("the button is disabled when nothing is downloaded and the folder holds nothing else")
    func disabledWhenEmpty() {
        #expect(!MusicDownloadSettingsText.canRemoveAll(songs: 0, collections: 0, hasFiles: false, isRemoving: false))
        #expect(!MusicDownloadSettingsText.canRemoveAll(songs: 0, collections: 0, hasFiles: nil, isRemoving: false))
    }

    @Test("the button is disabled while counting is still going on")
    func disabledWhileCounting() {
        #expect(!MusicDownloadSettingsText.canRemoveAll(songs: nil, collections: nil, hasFiles: nil, isRemoving: false))
        #expect(!MusicDownloadSettingsText.canRemoveAll(songs: nil, collections: nil, hasFiles: false, isRemoving: false))
    }

    @Test("the button is disabled while a removal runs, whatever there is to remove")
    func disabledWhileRemoving() {
        #expect(!MusicDownloadSettingsText.canRemoveAll(songs: 9, collections: 9, hasFiles: true, isRemoving: true))
        #expect(!MusicDownloadSettingsText.canRemoveAll(songs: 0, collections: 0, hasFiles: true, isRemoving: true))
    }

    @Test("files in the folder that no download owns still let the button work, so an unreadable index can be cleared")
    func enabledForLeftoverFiles() {
        #expect(MusicDownloadSettingsText.canRemoveAll(songs: 0, collections: 0, hasFiles: true, isRemoving: false))
    }

    // MARK: - What a removal says afterwards

    @Test("no removal yet, or one that deleted everything, says nothing")
    func cleanWipeIsSilent() {
        #expect(MusicDownloadSettingsText.caption(for: nil) == nil)
        #expect(MusicDownloadSettingsText.caption(for: MusicDownloadStore.Wipe()) == nil)
        #expect(MusicDownloadSettingsText.caption(for: MusicDownloadStore.Wipe(removed: 12)) == nil)
    }

    @Test("a refused removal says the folder is not where Deci expects it and that nothing was removed, without alarm")
    func refusedCaption() {
        let caption = MusicDownloadSettingsText.caption(for: MusicDownloadStore.Wipe(refused: true))
        #expect(caption?.text == "The Downloads folder is not where Deci expects it, so nothing was removed.")
        #expect(caption?.isFailure == false)
    }

    @Test("a partial removal counts the items it could not remove, in red")
    func partialCaption() {
        let many = MusicDownloadSettingsText.caption(for: MusicDownloadStore.Wipe(removed: 4, failed: 3))
        #expect(many?.text == "Could not remove 3 items.")
        #expect(many?.isFailure == true)
        let one = MusicDownloadSettingsText.caption(for: MusicDownloadStore.Wipe(removed: 4, failed: 1))
        #expect(one?.text == "Could not remove 1 item.")
    }

    @Test("a removal that failed before deleting anything, such as an index that could not be written, says nothing was removed")
    func nothingRemovedCaption() {
        let caption = MusicDownloadSettingsText.caption(for: MusicDownloadStore.Wipe(removed: 0, failed: 1))
        #expect(caption?.text == "Could not remove 1 item. Nothing was removed.")
        #expect(caption?.isFailure == true)
        let several = MusicDownloadSettingsText.caption(for: MusicDownloadStore.Wipe(removed: 0, failed: 5))
        #expect(several?.text == "Could not remove 5 items. Nothing was removed.")
    }

    @Test("a refusal wins over the counts it carries, and nothing in the captions uses a dash")
    func refusalWinsAndNoDashes() {
        let both = MusicDownloadSettingsText.caption(for: MusicDownloadStore.Wipe(refused: true, removed: 2, failed: 2))
        #expect(both?.isFailure == false)
        for text in [
            both?.text, MusicDownloadSettingsText.caption(for: MusicDownloadStore.Wipe(removed: 1, failed: 2))?.text,
            MusicDownloadSettingsText.removing
        ] {
            #expect(text?.contains("\u{2014}") == false)
        }
    }

    @Test("while a removal runs the row says Removing")
    func removingWord() {
        #expect(MusicDownloadSettingsText.removing == "Removing")
    }
}
