#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import tempfile
import unittest
from pathlib import Path

from idb.common.file import get_last_n_lines


class FileTests(unittest.TestCase):
    def test_log_tail_preserves_line_separators(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "companion.log"
            for contents, count, expected in [
                ("first\nsecond\nthird\n", 2, "second\nthird\n"),
                ("first\nsecond\nthird", 2, "second\nthird"),
                ("first\nsecond\n", 30, "first\nsecond\n"),
                ("first\n\nlast\n", 3, "first\n\nlast\n"),
                ("first\nsecond\n", 1, "second\n"),
                ("", 30, ""),
            ]:
                with self.subTest(contents=contents, count=count):
                    path.write_text(contents, encoding="utf-8")
                    self.assertEqual(get_last_n_lines(str(path), count), expected)
