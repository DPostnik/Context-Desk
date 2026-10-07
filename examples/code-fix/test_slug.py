import unittest

from slug import slugify


class SlugTests(unittest.TestCase):
    def test_words(self):
        self.assertEqual(slugify("Ship Small"), "ship-small")

    def test_outer_whitespace(self):
        self.assertEqual(slugify("  Context Desk  "), "context-desk")

    def test_repeated_whitespace(self):
        self.assertEqual(slugify("Ship   Small"), "ship-small")

    def test_tabs_and_newlines(self):
        self.assertEqual(slugify("Ship\tSmall\nOften"), "ship-small-often")

    def test_empty(self):
        self.assertEqual(slugify("   "), "")


if __name__ == "__main__":
    unittest.main()
