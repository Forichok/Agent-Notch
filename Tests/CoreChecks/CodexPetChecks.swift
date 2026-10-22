import Foundation

struct CodexPetChecks {
    private let fm = FileManager.default

    private func pet(_ root: URL, _ id: String, sheet: String = "spritesheet.webp", manifest: String? = nil, age: TimeInterval) throws {
        let dir = root.appendingPathComponent(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = manifest ?? "{\"id\":\"\(id)\",\"displayName\":\"Pet \(id)\",\"spritesheetPath\":\"\(sheet)\"}"
        try json.write(to: dir.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent(sheet).standardizedFileURL
        try Data([0]).write(to: file)
        let date = Date(timeIntervalSince1970: 1_800_000_000 - age)
        for p in [dir.appendingPathComponent("pet.json"), file] where fm.fileExists(atPath: p.path) {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: p.path)
        }
    }

    func newestWins() throws {
        let home = fm.temporaryDirectory.appendingPathComponent("notch-pets-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let root = home.appendingPathComponent(".codex/pets")
        XCTAssertNil(CodexPet.find(home: home, environment: [:]))
        try pet(root, "old", age: 500)
        try pet(root, "fresh", sheet: "sheet.png", age: 10)
        try pet(root, "escape", sheet: "../../secret.png", age: 1)        // a sheet outside its folder is ignored
        try pet(root, "broken", manifest: "not json", age: 0)
        let found = CodexPet.find(home: home, environment: [:])
        XCTAssertEqual(found?.id, "fresh")
        XCTAssertEqual(found?.name, "Pet fresh")
        XCTAssertEqual(found?.sheet.lastPathComponent, "sheet.png")
    }

    func codexHome() throws {
        let home = fm.temporaryDirectory.appendingPathComponent("notch-pets-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        try pet(home.appendingPathComponent("elsewhere/pets"), "moved", age: 5)
        XCTAssertEqual(CodexPet.find(home: home, environment: ["CODEX_HOME": "~/elsewhere"])?.id, "moved")
        XCTAssertNil(CodexPet.find(home: home, environment: [:]))
    }
}
