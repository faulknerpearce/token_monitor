@testable import TokenMon
import XCTest

final class JSONTests: XCTestCase {
    // MARK: number

    func testNumberFromVariousTypes() {
        XCTAssertEqual(JSON.number(42 as Int), 42)
        XCTAssertEqual(JSON.number(3.5 as Double) ?? -1, 3.5, accuracy: 0.0001)
        XCTAssertEqual(JSON.number(NSNumber(value: 7.25)) ?? -1, 7.25, accuracy: 0.0001)
        XCTAssertEqual(JSON.number("12.5") ?? -1, 12.5, accuracy: 0.0001)
        XCTAssertNil(JSON.number("not a number"))
        XCTAssertNil(JSON.number(nil))
        XCTAssertNil(JSON.number("abc"))
    }

    func testNumberRejectsBooleansAndNonFiniteValues() throws {
        XCTAssertNil(JSON.number(true))
        XCTAssertNil(JSON.number(false))
        XCTAssertNil(JSON.number(Double.nan))
        XCTAssertNil(JSON.number(Double.infinity))
        XCTAssertNil(JSON.number("NaN"))
        XCTAssertNil(JSON.number("inf"))
        XCTAssertNil(JSON.number("1e400"))
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"flag":true,"one":1}"#.utf8)) as? [String: Any]
        )
        XCTAssertNil(JSON.number(decoded["flag"]))
        XCTAssertEqual(JSON.number(decoded["one"]), 1)
        XCTAssertNil(JSON.firstDouble(decoded, keys: ["flag"]))
    }

    func testNumberDescendsIntoValAndValueDicts() {
        let val = ["val": 12.0] as [String: Any]
        let value = ["value": 88.5] as [String: Any]
        let nested = ["outer": ["val": 3.0]] as [String: Any]
        XCTAssertEqual(JSON.number(val) ?? -1, 12.0, accuracy: 0.0001)
        XCTAssertEqual(JSON.number(value) ?? -1, 88.5, accuracy: 0.0001)
        XCTAssertNil(JSON.number(nested["val"]))
        XCTAssertEqual(JSON.number(nested["outer"]) ?? -1, 3.0, accuracy: 0.0001)
    }

    // MARK: string

    func testString() {
        XCTAssertEqual(JSON.string("abc"), "abc")
        XCTAssertNil(JSON.string(5))
        XCTAssertNil(JSON.string(nil))
    }

    // MARK: nested

    func testNestedTraversesKeys() {
        let dict: [String: Any] = [
            "a": ["b": ["c": 1.0] as [String: Any]] as [String: Any]
        ]
        XCTAssertEqual(JSON.nested(dict, ["a", "b", "c"]) as? Double, 1.0)
        XCTAssertNil(JSON.nested(dict, ["a", "b", "missing"]))
        XCTAssertNil(JSON.nested(dict, ["nope", "b"]))
    }

    // MARK: first*

    func testFirstDoubleTriesKeysInOrder() {
        let dict: [String: Any] = ["percentOfPool": 25.0, "percent": 90.0]
        XCTAssertEqual(JSON.firstDouble(dict, keys: ["percentOfPool", "percent", "usagePercent", "value"]) ?? -1, 25.0, accuracy: 0.0001)

        let onlyPercent: [String: Any] = ["percent": 33.0]
        XCTAssertEqual(JSON.firstDouble(onlyPercent, keys: ["percentOfPool", "percent"]) ?? -1, 33.0, accuracy: 0.0001)

        let missing: [String: Any] = ["x": 1.0]
        XCTAssertNil(JSON.firstDouble(missing, keys: ["a", "b"]))
    }

    func testFirstString() {
        let dict: [String: Any] = ["id": "foo", "name": "bar"]
        XCTAssertEqual(JSON.firstString(dict, keys: ["id", "name"]), "foo")
        XCTAssertEqual(JSON.firstString(dict, keys: ["name"]), "bar")
        XCTAssertNil(JSON.firstString([:], keys: ["id"]))
    }

    func testFirstDecimal() {
        let dict: [String: Any] = ["value": 12.0, "val": 99.0]
        let result = JSON.firstDecimal(dict, keys: ["value", "val"])
        XCTAssertEqual(result, Decimal(12.0))
    }

    /// Money values keep their written digits instead of a binary-double expansion.
    func testFirstDecimalKeepsMoneyPrecision() throws {
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(#"{"n":19.99,"s":"1234567.89","b":true,"bad":"1.5abc","w":{"val":"0.1"}}"#.utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(JSON.firstDecimal(decoded, keys: ["n"]), Decimal(string: "19.99"))
        XCTAssertEqual(JSON.firstDecimal(decoded, keys: ["s"]), Decimal(string: "1234567.89"))
        XCTAssertEqual(JSON.firstDecimal(decoded, keys: ["w"]), Decimal(string: "0.1"))
        XCTAssertNil(JSON.firstDecimal(decoded, keys: ["b"]))
        XCTAssertNil(JSON.firstDecimal(decoded, keys: ["bad"]))
        XCTAssertNil(JSON.decimal("NaN"))
        XCTAssertEqual(JSON.firstDecimal(decoded, keys: ["missing", "n"]), Decimal(string: "19.99"))
    }

    func testFirstBool() {
        XCTAssertTrue(JSON.firstBool(["flag": true], keys: ["flag"]))
        XCTAssertFalse(JSON.firstBool(["flag": false], keys: ["flag"]))
        XCTAssertTrue(JSON.firstBool(["n": 1], keys: ["n"]))
        XCTAssertFalse(JSON.firstBool(["n": 0], keys: ["n"]))
        XCTAssertTrue(JSON.firstBool([:], keys: ["missing"], fallback: true))
        XCTAssertTrue(JSON.firstBool(["snake": true], keys: ["camel", "snake"]))
    }
}
