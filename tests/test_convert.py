import io
import sys
import unittest
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import ud2dict  # noqa: E402

FIXTURE = ROOT / "tests" / "fixtures" / "sample.csv"
NS = {"d": "http://www.apple.com/DTDs/DictionaryService-1.0.rng",
      "h": "http://www.w3.org/1999/xhtml"}
D = "{%s}" % NS["d"]


def build(**kw):
    opts = dict(min_up=50, min_ratio=0.6, max_defs=3, max_words=None, max_word_len=60)
    opts.update(kw)
    stats = Counter()
    sel = ud2dict.select_entries(ud2dict.read_definitions([FIXTURE], stats), stats=stats, **opts)
    buf = io.StringIO()
    ud2dict.write_xml(sel, buf, show_author=True)
    return sel, stats, buf.getvalue()


class ConvertTests(unittest.TestCase):
    def test_filters_and_grouping(self):
        sel, stats, _ = build()
        self.assertEqual(sorted(sel), ["<script>", "skrrt", "yeet"])
        # case-insensitive merge, low-ratio def dropped, duplicate text deduped
        self.assertEqual([d.author for d in sel["yeet"]], ["alice", "bob"])
        self.assertEqual(stats["malformed"], 1)

    def test_xml_is_well_formed_with_unique_ids(self):
        _, _, xml = build()
        root = ET.fromstring(xml)
        ids = [e.get("id") for e in root.findall("d:entry", NS)]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertIn("front_back_matter", ids)

    def test_escaping_and_links(self):
        _, _, xml = build()
        self.assertNotIn("<tags>", xml)
        self.assertIn("&lt;tags&gt;", xml)
        root = ET.fromstring(xml)
        yeet = next(e for e in root.findall("d:entry", NS) if e.get(D + "title") == "yeet")
        hrefs = [a.get("href") for a in yeet.iter("{%s}a" % NS["h"])]
        self.assertIn("x-dictionary:r:ud_skrrt", hrefs)  # [skrrt] exists -> link
        self.assertNotIn("x-dictionary:r:ud_hyped", " ".join(hrefs))  # [hyped] missing -> text
        index = {i.get(D + "value") for i in yeet.findall("d:index", NS)}
        self.assertEqual(index, {"yeet", "Yeet"})

    def test_max_words_keeps_best(self):
        sel, _, _ = build(max_words=1)
        self.assertEqual(list(sel), ["yeet"])

    def test_cli_end_to_end(self):
        out = ROOT / "build" / "test_out.xml"
        rc = ud2dict.main([str(FIXTURE), "-o", str(out)])
        self.assertEqual(rc, 0)
        ET.parse(out)
        out.unlink()

    def test_saver_json(self):
        import json
        sel, _, _ = build()
        out = ROOT / "build" / "test_words.json"
        n = ud2dict.write_saver_json(sel, out, limit=2)
        words = json.loads(out.read_text(encoding="utf-8"))
        out.unlink()
        self.assertEqual(n, 2)
        self.assertEqual({w["w"] for w in words}, {"yeet", "skrrt"})  # top 2 by score
        yeet = next(w for w in words if w["w"] == "yeet")
        self.assertNotIn("[", yeet["d"])  # link brackets stripped
        self.assertEqual(yeet["u"], 900)

    def test_plain_truncates_on_word_boundary(self):
        s = ud2dict._plain("one two three four five", 12)
        self.assertEqual(s, "one two…")


if __name__ == "__main__":
    unittest.main()
