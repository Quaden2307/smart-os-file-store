import FileStoreCore
import Foundation
import Testing

/// What the app shows of a download source: the site in the tooltip, the file's address to copy.
@Suite("DownloadSource")
struct DownloadSourceTests {
    @Test func siteIsThePagesSite() throws {
        let source = try #require(
            DownloadSource(
                addresses: ["https://objects.githubusercontent.com/release/tool.zip", "https://github.com/owner/tool/releases"],
                downloadingApp: "Safari"
            )
        )
        #expect(source.site == "github.com")
        #expect(source.fileAddress == "https://objects.githubusercontent.com/release/tool.zip")
    }

    @Test func siteFallsBackToTheFilesSite() throws {
        let source = try #require(DownloadSource(addresses: ["https://WWW.Example.com/files/a.pdf"], downloadingApp: nil))
        #expect(source.site == "example.com")
        // A page that is not a web address does not hide the file's site.
        let mixed = try #require(DownloadSource(addresses: ["http://example.org/a.pdf", "about:blank"], downloadingApp: nil))
        #expect(mixed.site == "example.org")
    }

    /// Mail stores the sender, the subject and a message link: no site, but still a source to copy.
    @Test func mailEntriesHaveNoSite() throws {
        let source = try #require(
            DownloadSource(addresses: ["Jane Doe <jane@example.com>", "Your invoice", "message:%3C1234@example.com%3E"], downloadingApp: "Mail")
        )
        #expect(source.site == nil)
        #expect(source.fileAddress == "Jane Doe <jane@example.com>")
        #expect(source.downloadingApp == "Mail")
    }

    @Test func appOnlySource() throws {
        let source = try #require(DownloadSource(addresses: [], downloadingApp: "sharingd"))
        #expect(source.site == nil)
        #expect(source.fileAddress == nil)
    }

    @Test func nothingRecordedIsNoSource() {
        #expect(DownloadSource(addresses: [], downloadingApp: nil) == nil)
        #expect(DownloadSource(addresses: [""], downloadingApp: "") == nil)
    }

    @Test func onlyWebAddressesHaveSites() throws {
        for address in ["ftp://example.com/a.zip", "file:///Users/me/a.zip", "data:text/plain,hello", "not a url", "https://"] {
            let source = try #require(DownloadSource(addresses: [address], downloadingApp: nil))
            #expect(source.site == nil, "\(address) should have no site")
        }
    }
}
