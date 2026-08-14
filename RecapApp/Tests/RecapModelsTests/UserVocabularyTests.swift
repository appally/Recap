import XCTest
@testable import RecapModels

/// plan 050 Wave A：全局常用词表表征测试（UserDefaults 污染：前后保存/恢复原值）。
final class UserVocabularyTests: XCTestCase {

    private var original: [String]?

    override func setUp() {
        super.setUp()
        original = UserVocabulary.words
        UserVocabulary.words = []
    }

    override func tearDown() {
        if let original { UserVocabulary.words = original }
        super.tearDown()
    }

    func testAddDedupsAndTrims() {
        XCTAssertTrue(UserVocabulary.add("  王工 "))
        XCTAssertFalse(UserVocabulary.add("王工"), "重复词不加")
        XCTAssertEqual(UserVocabulary.words, ["王工"])
    }

    func testAddRejectsOverlongAndEmpty() {
        XCTAssertFalse(UserVocabulary.add(String(repeating: "词", count: UserVocabulary.maxWordLength + 1)))
        XCTAssertFalse(UserVocabulary.add("   "))
        XCTAssertTrue(UserVocabulary.words.isEmpty)
    }

    func testAddRespectsMaxWords() {
        for i in 0..<UserVocabulary.maxWords {
            XCTAssertTrue(UserVocabulary.add("词\(i)"))
        }
        XCTAssertFalse(UserVocabulary.add("溢出词"), "超过 100 词上限拒绝")
        XCTAssertEqual(UserVocabulary.words.count, UserVocabulary.maxWords)
    }

    func testRemove() {
        UserVocabulary.add("王工")
        UserVocabulary.add("李总")
        XCTAssertTrue(UserVocabulary.remove("王工"))
        XCTAssertEqual(UserVocabulary.words, ["李总"])
        XCTAssertFalse(UserVocabulary.remove("不存在"))
    }

    func testWordsSetterSanitizes() {
        UserVocabulary.words = [" A ", "", "A", "B"]
        XCTAssertEqual(UserVocabulary.words, ["A", "B"], "去空白/空串/重复")
    }
}
