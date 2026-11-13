#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import json
import os.path
import sys
from argparse import ArgumentParser, Namespace, REMAINDER
from pathlib import Path

from idb.cli import ClientCommand, print_upload_progress
from idb.common.command import CommandGroup
from idb.common.format import (
    human_format_installed_test_info,
    human_format_test_info,
    json_format_installed_test_info,
    json_format_test_info,
)
from idb.common.misc import get_env_with_idb_prefix
from idb.common.types import Client, CodeCoverageFormat, FileContainerType, IdbException

NO_SPECIFIED_PATH = "NO_SPECIFIED_PATH"


class XctestInstallCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "Install an xctest"

    @property
    def name(self) -> str:
        return "install"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "test_bundle_path", help="Bundle path of the test bundle", type=str
        )
        parser.add_argument(
            "--skip-signing-bundles",
            help="idb will skip signing the test and/or apps bundles",
            action="store_true",
            default=None,
            required=False,
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        async for install_response in client.install_xctest(
            args.test_bundle_path,
            args.skip_signing_bundles,
            on_upload_progress=print_upload_progress,
        ):
            if install_response.progress != 0.0 and not args.json:
                print(f"Installed {install_response.progress}%")
            elif args.json:
                print(
                    json.dumps(
                        {
                            "installedTestBundleId": install_response.name,
                            "uuid": install_response.uuid,
                        }
                    )
                )
            else:
                print(f"Installed: {install_response.name} {install_response.uuid}")


class XctestsListBundlesCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "List the installed test bundles"

    @property
    def name(self) -> str:
        return "list"

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        tests = await client.list_xctests()
        formatter = human_format_installed_test_info
        if args.json:
            formatter = json_format_installed_test_info
        for test in tests:
            print(formatter(test))


class XctestListTestsCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "List the tests inside an installed test bundle"

    @property
    def name(self) -> str:
        return "list-bundle"

    def add_parser_positional_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "test_bundle_id", help="Bundle id of the test bundle to list", type=str
        )

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        self.add_parser_positional_arguments(parser)
        parser.add_argument(
            "--app-path",
            default=None,
            type=str,
            help="Path of the app of the test (needed for app tests)",
        )
        parser.add_argument(
            "--install",
            help="When this option is provided bundle_ids are assumed "
            "to be paths instead. They are installed before listing.",
            action="store_true",
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        if args.install:
            await self.install_bundles(args, client)
        app_path = args.app_path and str(Path(args.app_path).resolve(strict=True))
        tests = await client.list_test_bundle(
            test_bundle_id=args.test_bundle_id, app_path=app_path
        )
        if args.json:
            print(json.dumps(tests))
        else:
            print("\n".join(tests))

    async def install_bundles(self, args: Namespace, client: Client) -> None:
        async for test in client.install_xctest(
            args.test_bundle_id, on_upload_progress=print_upload_progress
        ):
            args.test_bundle_id = test.name


class CommonRunXcTestCommand(ClientCommand):
    @property
    def description(self) -> str:
        return (
            f"Run an installed {self.name} test. Will pass through"
            " any environment\nvariables prefixed with IDB_"
        )

    def add_parser_positional_arguments(self, parser: ArgumentParser) -> None:
        parser.add_argument(
            "test_bundle_id", help="Bundle id of the test to launch", type=str
        )

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        self.add_parser_positional_arguments(parser)
        parser.add_argument(
            "--result-bundle-path",
            default=None,
            type=str,
            help="Path to save the result bundle",
        )
        parser.add_argument(
            "--timeout",
            help="The number of seconds to wait before the test times out. When the timeout is exceeded the test will exit and an attempt will be made to obtain a sample of the hung process",
            default=None,
            type=int,
        )
        parser.add_argument(
            "--report-activities",
            action="store_true",
            help="idb will report activity data emitted by your test bundle",
        )
        parser.add_argument(
            "--report-attachments",
            action="store_true",
            help="idb will report activity and attachment data emitted by your test bundle",
        )
        parser.add_argument(
            "--activities-output-path",
            help=(
                "When activity data is reported, "
                "data blobs will be saved to this location"
            ),
        )
        parser.add_argument(
            "--coverage-output-path",
            help="Outputs code coverage information. See --coverage-format option.",
        )
        parser.add_argument(
            "--enable-continuous-coverage-collection",
            action="store_true",
            help="Enable continuous coverage collection mode in llvm",
        )
        parser.add_argument(
            "--coverage-format",
            choices=[str(key) for (key, _) in CodeCoverageFormat.__members__.items()],
            default="EXPORTED",
            help="Format for code coverage information: "
            "EXPORTED (default value) a file in JSON format as exported by `llvm-cov export`; "
            "RAW a folder containing the .profraw files as generated by the Test Bundle, Host App and/or Target App",
        )
        parser.add_argument(
            "--log-directory-path",
            default=None,
            type=str,
            help="Path to save the test logs collected",
        )
        parser.add_argument(
            "--wait-for-debugger",
            action="store_true",
            help="Suspend test run process to wait for a debugger to be attached. (It is NOT supported by ui test).",
        )
        parser.add_argument(
            "--install",
            help="When this option is provided bundle_ids are assumed "
            "to be paths instead. They are installed before running.",
            action="store_true",
        )
        parser.add_argument(
            "--install-dsym-test-bundle",
            default=None,
            type=str,
            nargs="?",
            const=NO_SPECIFIED_PATH,
            help="Install debug symbols together with bundle. Specify path for debug symbols; otherwise, we'll try to infer it. (requires --install)",
        )
        parser.add_argument(
            "--skip-signing-bundles",
            help="idb will skip signing the test and/or apps bundles",
            action="store_true",
            default=None,
            required=False,
        )
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        # pyrefly: ignore [abstract-method-call, missing-attribute]
        await super().run_with_client(args, client)

        is_ui = args.run == "ui"
        is_logic = args.run == "logic"
        is_app = args.run == "app"

        if args.install:
            # Note for --install specified, test_bundle_id is a path initially, but
            # `install_bundles` will override it.
            test_bundle_location = args.test_bundle_id

            await self.install_bundles(args, client)
            if args.install_dsym_test_bundle:
                if is_ui or is_app:
                    print(
                        "--install-dsym-test-bundle is experimental for ui and app tests; this flag is only supported for logic tests.",
                        file=sys.stderr,
                    )
                await self.install_dsym_test_bundle(args, client, test_bundle_location)

        tests_to_run = self.get_tests_to_run(args)
        tests_to_skip = self.get_tests_to_skip(args)
        app_bundle_id = getattr(args, "app_bundle_id", None)
        test_host_app_bundle_id = (
            args.test_host_app_bundle_id
            if hasattr(args, "test_host_app_bundle_id")
            else None
        )
        arguments = getattr(args, "test_arguments", [])
        if args.wait_for_debugger and is_ui:
            print(
                "--wait_for_debugger flag is NOT supported for ui tests. It will default to False"
            )

        formatter = json_format_test_info if args.json else human_format_test_info
        coverage_format = CodeCoverageFormat[args.coverage_format]

        async for test_result in client.run_xctest(
            test_bundle_id=args.test_bundle_id,
            # pyrefly: ignore [bad-argument-type]
            app_bundle_id=app_bundle_id,
            test_host_app_bundle_id=test_host_app_bundle_id,
            is_ui_test=is_ui,
            is_logic_test=is_logic,
            tests_to_run=tests_to_run,
            tests_to_skip=tests_to_skip,
            timeout=args.timeout,
            env=get_env_with_idb_prefix(),
            args=arguments,
            result_bundle_path=args.result_bundle_path,
            report_activities=args.report_activities or args.report_attachments,
            report_attachments=args.report_attachments,
            activities_output_path=args.activities_output_path,
            coverage_output_path=args.coverage_output_path,
            enable_continuous_coverage_collection=args.enable_continuous_coverage_collection,
            coverage_format=coverage_format,
            log_directory_path=args.log_directory_path,
            wait_for_debugger=args.wait_for_debugger,
        ):
            print(formatter(test_result))

    async def install_bundles(self, args: Namespace, client: Client) -> None:
        async for test in client.install_xctest(
            args.test_bundle_id,
            args.skip_signing_bundles,
            on_upload_progress=print_upload_progress,
        ):
            args.test_bundle_id = test.name

    async def install_dsym_test_bundle(
        self, args: Namespace, client: Client, test_bundle_location: str
    ) -> str | None:
        dsym_name = None
        dsym_path_location = args.install_dsym_test_bundle
        if args.install_dsym_test_bundle == NO_SPECIFIED_PATH:
            dsym_path_location = test_bundle_location + ".dSYM"

        if not os.path.exists(dsym_path_location):
            raise IdbException(
                "XCTest run failed! Error: --install-dsym flag was used but there is no file at location {}.".format(
                    dsym_path_location
                )
            )

        async for install_response in client.install_dsym(
            dsym=dsym_path_location,
            bundle_id=args.test_bundle_id,
            bundle_type=FileContainerType.XCTEST,
            compression=None,
            on_upload_progress=print_upload_progress,
        ):
            if install_response.progress == 0.0:
                dsym_name = install_response.name
        return dsym_name

    def get_tests_to_run(self, args: Namespace) -> set[str] | None:
        return None

    def get_tests_to_skip(self, args: Namespace) -> set[str] | None:
        return None


class XctestRunAppCommand(CommonRunXcTestCommand):
    @property
    def name(self) -> str:
        return "app"

    def add_parser_positional_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_positional_arguments(parser)
        parser.add_argument(
            "app_bundle_id", help="Bundle id of the app to test", type=str
        )

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)
        parser.add_argument(
            "--tests-to-run",
            nargs="*",
            help="Run only these tests, \
            if not specified all tests are run. \
            Format: className/methodName",
        )
        parser.add_argument(
            "--tests-to-skip",
            nargs="*",
            help="Skip these tests, \
            has precedence over --tests-to-run. \
            Format: className/methodName",
        )
        parser.add_argument(
            "test_arguments",
            help="Arguments to start the test with",
            default=[],
            nargs=REMAINDER,
        )

    async def install_bundles(self, args: Namespace, client: Client) -> None:
        await super().install_bundles(args, client)
        async for app in client.install(
            args.app_bundle_id, on_upload_progress=print_upload_progress
        ):
            args.app_bundle_id = app.name

    def get_tests_to_run(self, args: Namespace) -> set[str] | None:
        return set(args.tests_to_run) if args.tests_to_run else None

    def get_tests_to_skip(self, args: Namespace) -> set[str] | None:
        return set(args.tests_to_skip) if args.tests_to_skip else None


class XctestRunUICommand(XctestRunAppCommand):
    @property
    def name(self) -> str:
        return "ui"

    def add_parser_positional_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_positional_arguments(parser)
        parser.add_argument(
            "test_host_app_bundle_id",
            help="Bundle id of the app that hosts ui test",
            type=str,
        )

    async def install_bundles(self, args: Namespace, client: Client) -> None:
        await super().install_bundles(args, client)
        async for app in client.install(
            args.test_host_app_bundle_id, on_upload_progress=print_upload_progress
        ):
            args.test_host_app_bundle_id = app.name


class XctestRunLogicCommand(CommonRunXcTestCommand):
    @property
    def name(self) -> str:
        return "logic"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)
        parser.add_argument(
            "--test-to-run",
            nargs=1,
            help="Run only this test, \
            if not specified all tests are run. \
            Format: className/methodName",
        )
        parser.add_argument(
            "--tests-to-run",
            nargs="*",
            help="Run these tests only. \
            if not specified all tests are run. \
            Format: className/methodName",
        )

    def get_tests_to_run(self, args: Namespace) -> set[str] | None:
        if args.test_to_run:
            return set(args.test_to_run)
        if args.tests_to_run:
            tests = ""
            for test in args.tests_to_run:
                tests += test + ","
            tests = tests[:-1]
            # the companion is expecting a set of size one for the logic tests,
            # that is why we parse it here
            return {tests}
        return None


def build_xctest_run_command() -> CommandGroup:
    """A freshly constructed ``xctest run`` group.

    A group is mutable: adding it to a parser records that parser on it and
    memoises its subcommand lookup. One instance shared between two command
    graphs would therefore have the second graph's state overwrite the
    first's, so every graph builds its own.
    """
    return CommandGroup(
        name="run",
        description=(
            "Run an installed xctest. Any environment variables of the form IDB_X\n"
            " will be passed through with the IDB_ prefix removed."
        ),
        commands=[
            XctestRunAppCommand(),
            XctestRunUICommand(),
            XctestRunLogicCommand(),
        ],
    )


# Kept for callers that already import this name. The command graph builds its
# own group with the factory above rather than sharing this one.
XctestRunCommand: CommandGroup = build_xctest_run_command()
