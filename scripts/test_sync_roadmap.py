import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("sync", pathlib.Path(__file__).with_name("sync-roadmap.py"))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)

BODY = """# Roadmap

## Now
- [ ] #1
- [x] #2
- [x] #3 keeps its text
- [ ] #4

Some text with #5 and a list:
- not a task #6
- [ ] not a roadmap line
"""


class RewriteTests(unittest.TestCase):
    def test_a_box_is_ticked_only_when_its_issue_is_closed(self):
        new, changes = sync.rewrite(BODY, closed={1, 3})
        self.assertIn("- [x] #1", new)
        self.assertIn("- [ ] #2", new)
        self.assertIn("- [x] #3 keeps its text", new)
        self.assertIn("- [ ] #4", new)
        self.assertEqual(sorted(n for n, _, _ in changes), [1, 2])

    def test_wrongly_ticked_boxes_are_cleared(self):
        body = "".join(f"- [x] #{n}\n" for n in range(1, 6))
        new, changes = sync.rewrite(body, closed={1, 2})
        self.assertEqual(new.count("[x]"), 2)
        self.assertEqual(len(changes), 3)

    def test_nothing_changes_when_the_boxes_are_right(self):
        once, _ = sync.rewrite(BODY, closed={2, 3})
        again, changes = sync.rewrite(once, closed={2, 3})
        self.assertEqual(once, again)
        self.assertEqual(changes, [])

    def test_other_text_is_never_touched(self):
        new, _ = sync.rewrite(BODY, closed=set())
        for untouched in ["Some text with #5 and a list:", "- not a task #6", "- [ ] not a roadmap line", "## Now"]:
            self.assertIn(untouched, new)


if __name__ == "__main__":
    unittest.main()
