import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import generate_catalog

class CatalogGeneratorTests(unittest.TestCase):
    def test_normalizes_formula_and_cask(self):
        formula = generate_catalog.normalize_formula({"name": "git", "versions": {"stable": "2.51.0"}})
        cask = generate_catalog.normalize_cask({"token": "firefox", "version": "141.0"})
        self.assertEqual(formula["id"], "formula:git")
        self.assertEqual(formula["latestVersion"], "2.51.0")
        self.assertEqual(cask["id"], "cask:firefox")

    def test_snapshot_is_deterministic_and_schema_versioned(self):
        snapshot = generate_catalog.build_snapshot([{"name": "z"}, {"name": "a"}], [{"token": "b"}], "2026-08-16T00:00:00Z")
        self.assertEqual(snapshot["schemaVersion"], 1)
        self.assertEqual([item["id"] for item in snapshot["packages"]], ["formula:a", "formula:z", "cask:b"])

if __name__ == "__main__":
    unittest.main()
