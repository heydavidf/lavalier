"""Tests for .github/check-shell-blocks.sh (run: python3 -m unittest discover -s .github/tests -v).

It lives in .github/tests/ because Tests/ holds the Swift tests. Each test makes a
throwaway Git repository with one Markdown file and runs the repository's script in it. Skill guides often keep
commands in fenced blocks indented inside numbered lists, so the check must read those as well as blocks at the
start of a line.
"""

import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.environ.get("CHECK_SHELL_BLOCKS") or os.path.join(ROOT, ".github", "check-shell-blocks.sh")
FENCE = "`" * 3


def markdown(*lines):
    return "\n".join(lines) + "\n"


class ShellBlocks(unittest.TestCase):
    def run_check(self, text):
        repo = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, repo, True)
        env = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "TMPDIR": repo,
        }
        subprocess.run(["git", "init", "-q", repo], check=True, env=env)
        with open(os.path.join(repo, "GUIDE.md"), "w") as f:
            f.write(text)
        subprocess.run(["git", "-C", repo, "add", "GUIDE.md"], check=True, env=env)
        result = subprocess.run(
            ["bash", SCRIPT],
            cwd=repo,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        leftovers = [n for n in os.listdir(repo) if n.startswith("shell-blocks.")]
        self.assertEqual(leftovers, [], "the check removes its working folder")
        return result

    def test_a_comment_in_an_indented_block_inside_a_list_fails(self):
        result = self.run_check(
            markdown(
                "1. Set up:",
                f"   {FENCE}bash",
                "   mkdir -p motion/_engine",
                "   npm install # the engine's one dependency",
                f"   {FENCE}",
            )
        )
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Comment in a shell block", result.stdout)
        self.assertIn("GUIDE.md:4:", result.stdout)

    def test_an_indented_block_that_does_not_parse_fails(self):
        result = self.run_check(
            markdown("2. Then:", f"   {FENCE}sh", "   if then", f"   {FENCE}")
        )
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("GUIDE.md:3: shell block does not parse in bash", result.stdout)

    def test_clean_blocks_at_any_indent_pass_and_are_counted(self):
        result = self.run_check(
            markdown(
                f"{FENCE}sh",
                "echo first",
                FENCE,
                "",
                "1. Item:",
                f"   {FENCE}bash",
                '   echo "# not a comment, it is quoted"',
                "   cp -R a b",
                f"   {FENCE}",
                "",
                f"{FENCE}text",
                "# not a shell block, so not checked",
                FENCE,
            )
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("shell blocks: 2 block(s) checked", result.stdout)

    def test_a_comment_at_the_start_of_a_line_fails(self):
        result = self.run_check(markdown(f"{FENCE}zsh", "ls # list", FENCE))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("GUIDE.md:2: ls # list", result.stdout)

    def test_a_block_left_open_at_the_end_of_the_file_is_still_checked(self):
        result = self.run_check(
            markdown("Text.", f"  {FENCE}bash", "  echo hi # trailing")
        )
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("GUIDE.md:3:", result.stdout)


if __name__ == "__main__":
    unittest.main()
