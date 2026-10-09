import os
import re
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import autostart
import cli_install
import server

import assets


class CmdQuotingTests(unittest.TestCase):
    def test_shim_arguments_escape_every_metacharacter(self):
        quoted = assets.cmd_quote('Sword & "Shield" 100%', shim=True)
        # Twice-escaped carets leave no bare metacharacter for either cmd.exe parse.
        once = re.sub(r"\^(.)", r"\1", quoted)
        self.assertEqual(re.sub(r"\^(.)", r"\1", once), r'"Sword & \"Shield\" 100%"')
        self.assertNotRegex(quoted, r"(?<!\^)[&%]")

    def test_command_is_a_string_with_an_escaped_shim_path(self):
        with patch.dict(os.environ, {"COMSPEC": r"C:\Windows\system32\cmd.exe"}):
            command = assets.cmd_shim_command(r"C:\Users\John Smith\AppData\Roaming\npm\raven.cmd", ["--json"])
        self.assertTrue(command.startswith(r'"C:\Windows\system32\cmd.exe" /d /s /c "'))
        self.assertIn(r"John^ Smith", command)
        self.assertTrue(command.endswith('^^^"--json^^^""'))

    def test_trailing_backslashes_are_doubled_before_the_closing_quote(self):
        self.assertEqual(re.sub(r"\^(.)", r"\1", assets.cmd_quote("C:\\out\\")), '"C:\\out\\\\"')


class FilenameTests(unittest.TestCase):
    def test_windows_reserved_names_are_prefixed(self):
        for name in ("CON", "con", "Aux", "nul.backup", "COM1", "lpt9"):
            self.assertTrue(server.safe_filename(name).startswith("_"), name)
        for name in ("Console", "Auxiliary", "COM", "Icon"):
            self.assertEqual(server.safe_filename(name), name)

    def test_truncation_never_ends_in_a_dot_or_space(self):
        self.assertEqual(server.safe_filename("a" * 99 + ". tail"), "a" * 99)


class StartupEntryTests(unittest.TestCase):
    def test_task_restart_count_fits_the_schema(self):
        source = Path(autostart.__file__).read_text(encoding="utf-8")
        count = int(re.search(r"<Count>(\d+)</Count>", source).group(1))
        # Task Scheduler types Count as xs:unsignedByte.
        self.assertTrue(1 <= count <= 255)

    def test_batch_launcher_escapes_percent_and_hides_profile_paths(self):
        with patch.dict(os.environ, {"LOCALAPPDATA": r"C:\Users\José\AppData\Local", "APPDATA": "", "USERPROFILE": ""}):
            line = cli_install.batch_line([r"C:\Blender\python.exe", r"C:\Users\José\AppData\Local\Prism\backend\100%\cli.py"])
        self.assertEqual(line, r"C:\Blender\python.exe %LOCALAPPDATA%\Prism\backend\100%%\cli.py")


if __name__ == "__main__":
    unittest.main()
