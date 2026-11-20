#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import json
from unittest import TestCase

from idb.grpc.xctest_log_parser import XCTestLogParser


def _begin_test(class_name: str, method_name: str) -> str:
    return json.dumps(
        {"className": class_name, "methodName": method_name, "event": "begin-test"}
    )


def _end_test(class_name: str, method_name: str) -> str:
    return json.dumps(
        {"className": class_name, "methodName": method_name, "event": "end-test"}
    )


class XCTestLogParserTestCase(TestCase):
    def test_ignores_line_missing_class_name(self) -> None:
        parser = XCTestLogParser()
        for line in [
            "some line",
            '{"event": "begin-test", "methodName": "MyTestMethod"}',
            "abc",
            _end_test("MyTestClass", "MyTestMethod"),
        ]:
            parser.parse_streaming_log(line)
        self.assertCountEqual({}, parser._logs)

    def test_ignores_line_with_mismatched_types(self) -> None:
        parser = XCTestLogParser()
        for line in [
            "some line",
            '{"event": "begin-test", "className": "MyTestClass", "methodName": 42}',
            "abc",
            _end_test("MyTestClass", "MyTestMethod"),
        ]:
            parser.parse_streaming_log(line)
        self.assertCountEqual({}, parser._logs)

    def test_ignores_line_that_is_too_long(self) -> None:
        parser = XCTestLogParser()
        method_name = "a" * 10_001
        for line in [
            _begin_test("MyTestClass", method_name),
            "abc",
            "def",
            _end_test("MyTestClass", method_name),
        ]:
            parser.parse_streaming_log(line)
        self.assertCountEqual({}, parser._logs)

    def test_ignores_log_lines_outside_test(self) -> None:
        parser = XCTestLogParser()
        for line in ["some line", '{"this line": "has json"}']:
            parser.parse_streaming_log(line)
        self.assertCountEqual({}, parser._logs)

    def test_adds_lines_to_distinct_tests(self) -> None:
        parser = XCTestLogParser()
        for line in [
            _begin_test("MyTestClass", "MyTestMethod"),
            "abc",
            "def",
            _end_test("MyTestClass", "MyTestMethod"),
            _begin_test("MyTestClass", "OtherMethod"),
            "123",
            "456",
            _end_test("MyTestClass", "OtherMethod"),
        ]:
            parser.parse_streaming_log(line)
        self.assertListEqual(
            parser.get_logs_for_test("MyTestClass", "MyTestMethod"), ["abc", "def"]
        )
        self.assertListEqual(
            parser.get_logs_for_test("MyTestClass", "OtherMethod"), ["123", "456"]
        )

    def test_handles_mismatched_starts(self) -> None:
        parser = XCTestLogParser()
        for line in [
            _begin_test("MyTestClass", "MyTestMethod"),
            "abc",
            "def",
            _begin_test("MyTestClass", "OtherMethod"),
            "123",
            "456",
            _end_test("MyTestClass", "OtherMethod"),
        ]:
            parser.parse_streaming_log(line)
        self.assertListEqual(
            parser.get_logs_for_test("MyTestClass", "MyTestMethod"), ["abc", "def"]
        )
        self.assertListEqual(
            parser.get_logs_for_test("MyTestClass", "OtherMethod"), ["123", "456"]
        )
