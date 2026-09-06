#!/usr/bin/env python3
"""Run real Bash/JXA installers against temporary profiles on macOS."""

import copy
import errno
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[1]
INSTALLER = REPO / "install.sh"
IMPLEMENTATION = REPO / "src" / "configure-macos.js"
COUNTRY = "variations_permanent_overridden_country"
ORIGINAL = {
    COUNTRY: "cn",
    "browser": {
        "enabled_labs_experiments": ["other@1", "glic@2", "glic-share-image@1"],
        "keep": True,
    },
    "nested": {
        "text": "\u4e2d\u6587 \u00e9 \U0001f680",
        "date": "2026-09-06T12:34:56.1234567+08:00",
        "integer": 9223372036854775807,
        "unsafeInteger": 9007199254740993,
        "array": [None, False, {"keep": [1, 2]}],
    },
}


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS Bash and system osascript")
class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(INSTALLER.is_file(), "install.sh is missing")
        self.assertTrue(IMPLEMENTATION.is_file(), "configure-macos.js is missing")
        self.temp = tempfile.TemporaryDirectory(prefix="gemini-macos-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.mock_bin = self.root / "mock bin"
        self.mock_bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()
        self.env = dict(os.environ)
        self.env.update({
            "HOME": str(self.home),
            "TMPDIR": str(self.tmp) + "/",
            "PATH": str(self.mock_bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "GEMINI_TEST_PGREP_COUNT": str(self.root / "pgrep-count"),
            "GEMINI_TEST_CLOSED": str(self.root / "chrome-closed"),
            "GEMINI_TEST_HELPER": str(IMPLEMENTATION),
            "GEMINI_TEST_CURL_LOG": str(self.root / "curl-log"),
            "GEMINI_TEST_PROCESS_MODE": "stopped",
            "TERM": "xterm-256color",
        })
        self.env.pop("NO_COLOR", None)
        self.write_mock("pgrep", r'''count=0
if [ -f "$GEMINI_TEST_PGREP_COUNT" ]; then count=$(/bin/cat "$GEMINI_TEST_PGREP_COUNT"); fi
count=$((count + 1))
printf '%s' "$count" > "$GEMINI_TEST_PGREP_COUNT"
case "$GEMINI_TEST_PROCESS_MODE" in
  running) printf '12345\n'; exit 0 ;;
  close) if [ ! -f "$GEMINI_TEST_CLOSED" ]; then printf '12345\n'; exit 0; fi ;;
  race) if [ "$count" -gt 1 ]; then printf '12345\n'; exit 0; fi ;;
  edit) if [ "$count" -gt 1 ]; then printf '%s' "$GEMINI_TEST_CONCURRENT_JSON" > "$GEMINI_TEST_STATE"; fi ;;
esac
exit 1
''')
        self.write_mock("mv", r'''last="${!#}"
if [ "$last" = "$GEMINI_TEST_STATE" ] && [ "$GEMINI_TEST_MV_FAIL" = 1 ]; then
  printf 'Simulated rename failure\n' >&2
  exit 73
fi
exec /bin/mv "$@"
''')
        self.write_mock("curl", r'''output=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >> "$GEMINI_TEST_CURL_LOG"
if [ "$url" != 'https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/src/configure-macos.js' ]; then
  printf 'Unexpected network request blocked\n' >&2
  exit 88
fi
if [ "$GEMINI_TEST_CURL_FAIL" = 1 ]; then
  if [ -n "$output" ]; then printf 'partial download' > "$output"; fi
  exit 22
fi
if [ -n "$output" ]; then /bin/cp "$GEMINI_TEST_HELPER" "$output"; else /bin/cat "$GEMINI_TEST_HELPER"; fi
''')
        self.make_profile("Chrome \u6d4b\u8bd5/User Data", ORIGINAL)

    def write_mock(self, name, body):
        path = self.mock_bin / name
        path.write_text("#!/bin/bash\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def make_profile(self, name, value):
        self.user_data = self.root / name
        self.user_data.mkdir(parents=True)
        self.state_path = self.user_data / "Local State"
        self.state_path.write_bytes(json_bytes(value))
        self.state_path.chmod(0o600)
        self.backup_dir = self.user_data / "GeminiInChromeBackup"
        self.manifest_path = self.backup_dir / "restore.json"
        self.env["GEMINI_TEST_STATE"] = str(self.state_path)

    def run_installer(self, *args, success=True, pipe=False, default_profile=False):
        command = ["/bin/bash"]
        if pipe:
            command += ["-s", "--"]
        else:
            command.append(str(INSTALLER))
        if not default_profile:
            command += ["--user-data-dir", str(self.user_data)]
        command += list(args)
        result = subprocess.run(
            command, input=INSTALLER.read_bytes() if pipe else b"", capture_output=True,
            env=self.env, cwd=self.root, timeout=30, start_new_session=True,
        )
        try:
            output = result.stdout.decode("utf-8") + result.stderr.decode("utf-8")
        except UnicodeDecodeError as error:
            self.fail(
                "Installer emitted invalid UTF-8: " + str(error)
                + "; returncode=" + str(result.returncode)
                + "; stdout=" + repr(result.stdout)
                + "; stderr=" + repr(result.stderr)
            )
        self.assertNotIn("\x1b[", output, "Non-terminal output should not contain ANSI colors.")
        if success:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        return output

    def read_state(self):
        return json.loads(self.state_path.read_bytes())

    def read_manifest(self):
        return json.loads(self.manifest_path.read_bytes())

    def assert_original_backup(self, original_bytes):
        manifest = self.read_manifest()
        self.assertEqual(manifest["version"], 1)
        self.assertEqual(Path(manifest["backup_file"]).name, manifest["backup_file"])
        self.assertEqual((self.backup_dir / manifest["backup_file"]).read_bytes(), original_bytes)
        self.assertEqual(manifest["sha256"].lower(), hashlib.sha256(original_bytes).hexdigest())

    def test_install_reinstall_and_restore_preserve_other_data(self):
        original_bytes = self.state_path.read_bytes()
        output = self.run_installer()
        state = self.read_state()
        self.assertEqual(state[COUNTRY], "us")
        self.assertEqual(state["nested"], ORIGINAL["nested"])
        self.assertIsInstance(state["nested"]["integer"], int)
        self.assertEqual(state["browser"]["enabled_labs_experiments"], ["other@1", "glic-share-image@1", "glic@1"])
        self.assertIn("\u8bbe\u7f6e\u5df2\u5199\u5165", output)
        self.assertNotIn("\ufffd", output)
        self.assertEqual(self.state_path.stat().st_mode & 0o777, 0o600)
        self.assert_original_backup(original_bytes)
        manifest_bytes = self.manifest_path.read_bytes()
        self.run_installer("--country", "GB")
        self.assertEqual(self.read_state()[COUNTRY], "gb")
        self.assertEqual(self.manifest_path.read_bytes(), manifest_bytes)
        self.assert_original_backup(original_bytes)
        state = self.read_state()
        state["browser"]["enabled_labs_experiments"].append("later@2")
        state["later"] = {"keep": True}
        self.state_path.write_bytes(json_bytes(state))
        self.run_installer("--uninstall")
        restored = self.read_state()
        self.assertEqual(restored[COUNTRY], "cn")
        self.assertCountEqual(restored["browser"]["enabled_labs_experiments"], ["other@1", "glic-share-image@1", "later@2", "glic@2"])
        self.assertEqual(restored["later"], {"keep": True})
        self.assertEqual(restored["nested"], ORIGINAL["nested"])
        self.assertFalse(self.manifest_path.exists())
        self.assertEqual(len(list(self.backup_dir.glob("restored-*.json"))), 1)
        restored_bytes = self.state_path.read_bytes()
        self.run_installer("--uninstall")
        self.assertEqual(self.state_path.read_bytes(), restored_bytes)

    def test_absent_null_and_empty_fields_round_trip(self):
        documents = [
            {"keep": 1}, {"browser": {"keep": 1}},
            {COUNTRY: None, "browser": {"enabled_labs_experiments": []}},
            {COUNTRY: "", "browser": {"enabled_labs_experiments": ["glic", "glic@0", "Glic@2"]}},
        ]
        for index, original in enumerate(documents):
            with self.subTest(original=original):
                self.make_profile("optional-" + str(index), original)
                self.run_installer()
                self.assertIn("glic@1", self.read_state()["browser"]["enabled_labs_experiments"])
                self.run_installer("--uninstall")
                restored = self.read_state()
                if COUNTRY in original:
                    self.assertEqual(restored[COUNTRY], original[COUNTRY])
                else:
                    self.assertNotIn(COUNTRY, restored)
                original_flags = original.get("browser", {}).get("enabled_labs_experiments")
                restored_flags = restored.get("browser", {}).get("enabled_labs_experiments")
                if original_flags is None:
                    self.assertIsNone(restored_flags)
                else:
                    self.assertCountEqual(restored_flags, original_flags)

    def test_utf8_bom_input_and_original_backup(self):
        original_bytes = b"\xef\xbb\xbf" + json_bytes(ORIGINAL)
        self.state_path.write_bytes(original_bytes)
        self.run_installer()
        self.assertEqual(self.read_state()["nested"], ORIGINAL["nested"])
        self.assert_original_backup(original_bytes)
        self.run_installer("--uninstall")
        self.assertEqual(self.read_state()[COUNTRY], ORIGINAL[COUNTRY])
        self.assertEqual(self.read_state()["nested"], ORIGINAL["nested"])

    def test_what_if_does_not_write_wait_or_download(self):
        self.env["GEMINI_TEST_PROCESS_MODE"] = "running"
        before = self.state_path.read_bytes()
        self.run_installer("--what-if", pipe=True)
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertFalse(self.backup_dir.exists())
        self.assertFalse(Path(self.env["GEMINI_TEST_PGREP_COUNT"]).exists())
        self.assertFalse(Path(self.env["GEMINI_TEST_CURL_LOG"]).exists())
        self.assertEqual(list(self.tmp.iterdir()), [])
        self.env["GEMINI_TEST_PROCESS_MODE"] = "stopped"
        self.run_installer()
        installed = self.state_path.read_bytes()
        manifest = self.manifest_path.read_bytes()
        self.run_installer("--uninstall", "--what-if")
        self.assertEqual(self.state_path.read_bytes(), installed)
        self.assertEqual(self.manifest_path.read_bytes(), manifest)

    def test_invalid_json_and_shapes_do_not_write(self):
        values = [b"{broken", b"[]", b"[{}]", b"null", b'{"browser":[]}', b'{"browser":null}',
                  b'{"browser":{"enabled_labs_experiments":7}}',
                  b'{"browser":{"enabled_labs_experiments":[1]}}']
        for index, value in enumerate(values):
            with self.subTest(value=value):
                self.make_profile("invalid-" + str(index), {})
                self.state_path.write_bytes(value)
                self.run_installer(success=False)
                self.assertEqual(self.state_path.read_bytes(), value)
                self.assertFalse(self.manifest_path.exists())

    def test_missing_state_and_uninstall_without_backup(self):
        self.state_path.unlink()
        self.run_installer(success=False)
        self.assertEqual(list(self.user_data.iterdir()), [])
        self.run_installer("--uninstall")
        self.assertEqual(list(self.user_data.iterdir()), [])

    def test_corrupted_backup_blocks_install_and_uninstall(self):
        for damage in ("version", "boolean-version", "string-version", "missing", "hash", "traversal", "malformed", "backup"):
            with self.subTest(damage=damage):
                self.make_profile("damage-" + damage, ORIGINAL)
                self.run_installer()
                installed = self.state_path.read_bytes()
                manifest = self.read_manifest()
                if damage == "version":
                    manifest["version"] = 999
                elif damage == "boolean-version":
                    manifest["version"] = True
                elif damage == "string-version":
                    manifest["version"] = "1"
                elif damage == "missing":
                    manifest["backup_file"] = "Local State." + "0" * 32 + ".bak"
                elif damage == "hash":
                    manifest["sha256"] = "0" * 64
                elif damage == "traversal":
                    manifest["backup_file"] = "../Local State"
                elif damage == "backup":
                    (self.backup_dir / manifest["backup_file"]).write_bytes(b"{}")
                self.manifest_path.write_bytes(b"{broken" if damage == "malformed" else json_bytes(manifest))
                for args in ((), ("--uninstall",)):
                    self.run_installer(*args, success=False)
                    self.assertEqual(self.state_path.read_bytes(), installed)
                    self.assertTrue(self.manifest_path.exists())

    def test_missing_state_with_active_backup_is_not_recreated(self):
        self.run_installer()
        self.state_path.unlink()
        self.run_installer("--uninstall", success=False)
        self.assertFalse(self.state_path.exists())
        self.assertTrue(self.manifest_path.exists())

    def test_failed_replace_keeps_original_and_recoverable_backup(self):
        original_bytes = self.state_path.read_bytes()
        self.env["GEMINI_TEST_MV_FAIL"] = "1"
        self.run_installer(success=False)
        self.assertEqual(self.state_path.read_bytes(), original_bytes)
        self.assert_original_backup(original_bytes)
        self.assertEqual({path.name for path in self.user_data.iterdir()}, {"Local State", "GeminiInChromeBackup"})
        self.env.pop("GEMINI_TEST_MV_FAIL")
        self.run_installer()
        self.assertEqual(self.read_state()[COUNTRY], "us")
        self.assert_original_backup(original_bytes)

    def test_running_chrome_without_terminal_fails_promptly(self):
        self.env["GEMINI_TEST_PROCESS_MODE"] = "running"
        before = self.state_path.read_bytes()
        self.run_installer(success=False)
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertFalse(self.manifest_path.exists())

    def test_chrome_starting_before_replace_prevents_write(self):
        self.env["GEMINI_TEST_PROCESS_MODE"] = "race"
        before = self.state_path.read_bytes()
        self.run_installer(success=False)
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertGreaterEqual(int(Path(self.env["GEMINI_TEST_PGREP_COUNT"]).read_text()), 2)

    def test_configuration_changed_before_replace_is_preserved(self):
        self.env["GEMINI_TEST_PROCESS_MODE"] = "edit"
        concurrent = copy.deepcopy(ORIGINAL)
        concurrent["concurrent"] = True
        self.env["GEMINI_TEST_CONCURRENT_JSON"] = json_bytes(concurrent).decode("utf-8")
        self.run_installer(success=False)
        self.assertEqual(self.read_state(), concurrent)

    def test_invalid_arguments_and_unsupported_os_do_not_write(self):
        before = self.state_path.read_bytes()
        for country in ("", "u", "usa", "u1", "us --test", "us\n"):
            with self.subTest(country=country):
                self.run_installer("--country", country, success=False)
        self.run_installer("--country", success=False)
        self.run_installer("--unknown", success=False)
        self.write_mock("uname", "printf 'Linux\\n'\n")
        self.run_installer(success=False)
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertFalse(self.backup_dir.exists())

    def test_help_does_not_touch_configuration(self):
        before = self.state_path.read_bytes()
        output = self.run_installer("--help", pipe=True)
        self.assertIn("--country", output)
        self.assertIn("--uninstall", output)
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertFalse(self.backup_dir.exists())
        self.assertFalse(Path(self.env["GEMINI_TEST_CURL_LOG"]).exists())

    def test_pipeline_installs_twice_and_cleans_download_directory(self):
        self.user_data = self.home / "Library/Application Support/Google/Chrome"
        self.user_data.mkdir(parents=True)
        self.state_path = self.user_data / "Local State"
        self.state_path.write_bytes(json_bytes(ORIGINAL))
        self.backup_dir = self.user_data / "GeminiInChromeBackup"
        self.manifest_path = self.backup_dir / "restore.json"
        self.env["GEMINI_TEST_STATE"] = str(self.state_path)
        for _ in range(2):
            output = self.run_installer(pipe=True, default_profile=True)
            state = self.read_state()
            self.assertEqual(state[COUNTRY], "us")
            self.assertEqual(state["nested"], ORIGINAL["nested"])
            self.assertIn("glic@1", state["browser"]["enabled_labs_experiments"])
            self.assertIn("\u8bbe\u7f6e\u5df2\u5199\u5165", output)
            self.assertNotIn("\ufffd", output)
            self.assert_original_backup(json_bytes(ORIGINAL))
            self.assertEqual(list(self.tmp.iterdir()), [])
        self.assertEqual(len(Path(self.env["GEMINI_TEST_CURL_LOG"]).read_text().splitlines()), 2)

    def test_failed_download_does_not_execute_partial_helper(self):
        self.env["GEMINI_TEST_CURL_FAIL"] = "1"
        before = self.state_path.read_bytes()
        self.run_installer(pipe=True, success=False)
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertFalse(self.backup_dir.exists())
        self.assertEqual(list(self.tmp.iterdir()), [])

    @unittest.skipUnless(
        os.environ.get("GITHUB_ACTIONS") == "true"
        and os.environ.get("GITHUB_REF") == "refs/heads/main"
        and os.environ.get("GITHUB_REPOSITORY") == "HangMine/gemini-in-chrome",
        "Published remote command is verified only in this repository's main CI",
    )
    def test_published_main_remote_command(self):
        (self.mock_bin / "curl").unlink()
        base_url = "https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/"
        for relative_path in ("install.sh", "src/configure-macos.js"):
            url = base_url + relative_path
            downloaded = subprocess.run(
                ["/usr/bin/curl", "--connect-timeout", "15", "--max-time", "60", "-fsSL", url],
                capture_output=True, env=self.env, timeout=70,
            )
            self.assertEqual(downloaded.returncode, 0, "Remote download failed: " + url + "; stderr=" + repr(downloaded.stderr))
            expected = (REPO / relative_path).read_bytes()
            if downloaded.stdout != expected:
                self.fail(
                    "Published main content differs from this CI checkout: " + url
                    + "; checkout_sha256=" + hashlib.sha256(expected).hexdigest()
                    + "; remote_sha256=" + hashlib.sha256(downloaded.stdout).hexdigest()
                )
        result = subprocess.run(
            [
                "/bin/bash", "-o", "pipefail", "-c",
                '/usr/bin/curl --connect-timeout 15 --max-time 60 -fsSL "$1" | /bin/bash -s -- --user-data-dir "$2"',
                "gemini-published-command", base_url + "install.sh", str(self.user_data),
            ],
            input=b"", capture_output=True, env=self.env, cwd=self.root,
            timeout=190, start_new_session=True,
        )
        try:
            output = result.stdout.decode("utf-8") + result.stderr.decode("utf-8")
        except UnicodeDecodeError as error:
            self.fail(
                "Published installer emitted invalid UTF-8: " + str(error)
                + "; returncode=" + str(result.returncode)
                + "; stdout=" + repr(result.stdout) + "; stderr=" + repr(result.stderr)
            )
        self.assertEqual(result.returncode, 0, output)
        self.assertNotIn("\x1b[", output)
        self.assertIn("\u8bbe\u7f6e\u5df2\u5199\u5165", output)
        state = self.read_state()
        self.assertEqual(state[COUNTRY], "us")
        self.assertIn("glic@1", state["browser"]["enabled_labs_experiments"])
        self.assertEqual(state["nested"], ORIGINAL["nested"])
        self.assert_original_backup(json_bytes(ORIGINAL))
        self.assertEqual(list(self.tmp.iterdir()), [])

    def run_with_terminal(self, close_chrome):
        import pty

        pid, master = pty.fork()
        if pid == 0:
            os.chdir(self.root)
            os.execve("/bin/bash", [
                "/bin/bash", "-c",
                '/bin/cat "$1" | /bin/bash -s -- --user-data-dir "$2"',
                "gemini-terminal-test", str(INSTALLER), str(self.user_data),
            ], self.env)
        output = bytearray()
        entered = False
        status = None
        deadline = time.monotonic() + 30
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        chunk = b""
                    output.extend(chunk)
                if not entered and "\u56de\u8f66".encode("utf-8") in output:
                    if close_chrome:
                        Path(self.env["GEMINI_TEST_CLOSED"]).touch()
                    os.write(master, b"\n")
                    entered = True
                finished, status_value = os.waitpid(pid, os.WNOHANG)
                if finished:
                    status = os.waitstatus_to_exitcode(status_value)
                    break
            if status is None:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                self.fail("Installer terminal interaction timed out; output=" + repr(bytes(output)))
        finally:
            os.close(master)
        try:
            decoded_output = output.decode("utf-8")
        except UnicodeDecodeError as error:
            self.fail(
                "Terminal installer emitted invalid UTF-8: " + str(error)
                + "; returncode=" + str(status) + "; output=" + repr(bytes(output))
            )
        self.assertTrue(entered, "Installer did not request Enter before checking Chrome again: " + decoded_output)
        return status, decoded_output

    def test_terminal_enter_rechecks_chrome_then_installs(self):
        self.env["GEMINI_TEST_PROCESS_MODE"] = "close"
        status, output = self.run_with_terminal(close_chrome=True)
        self.assertEqual(status, 0, output)
        self.assertEqual(self.read_state()[COUNTRY], "us")
        self.assertIn("\x1b[", output)
        self.assertTrue(Path(self.env["GEMINI_TEST_CURL_LOG"]).exists())

    def test_terminal_enter_fails_if_chrome_remains_running(self):
        self.env["GEMINI_TEST_PROCESS_MODE"] = "running"
        before = self.state_path.read_bytes()
        status, output = self.run_with_terminal(close_chrome=False)
        self.assertNotEqual(status, 0, output)
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(int(Path(self.env["GEMINI_TEST_PGREP_COUNT"]).read_text()), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
