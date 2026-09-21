import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AGENTS = {
    "planner": ("opus", "high"),
    "reviewer": ("opus", "high"),
    "coder": ("sonnet", "high"),
    "tester": ("sonnet", "high"),
    "explorer": ("sonnet", "medium"),
    "documenter": ("sonnet", "low"),
}
SKILLS = ("plan", "work", "review", "release", "setup", "orchestrator")


def frontmatter(path):
    source = path.read_text()
    header = source.split("---", 2)[1]
    return {
        key: value.strip().strip('"')
        for key, value in re.findall(r"^([a-z-]+):\s*(.+)$", header, re.M)
    }


class ContractTests(unittest.TestCase):
    def test_agent_model_and_effort_routing(self):
        for name, expected in AGENTS.items():
            with self.subTest(agent=name):
                metadata = frontmatter(ROOT / ".claude/agents" / "{}.md".format(name))
                self.assertEqual((metadata["model"], metadata["effort"]), expected)

    def test_skills_have_clear_trigger_boundaries(self):
        for name in SKILLS:
            with self.subTest(skill=name):
                metadata = frontmatter(ROOT / ".claude/skills" / name / "SKILL.md")
                description = metadata["description"]
                self.assertIn("Use", description)
                self.assertIn("do not", description)
        release = frontmatter(ROOT / ".claude/skills/release/SKILL.md")
        self.assertEqual(release["disable-model-invocation"], "true")

    def test_review_has_four_lenses_and_one_retry_owner(self):
        reviewer = (ROOT / ".claude/agents/reviewer.md").read_text()
        for lens in (
            "Spec correctness",
            "Security",
            "Correctness and maintainability",
            "Performance and operability",
        ):
            self.assertIn(lens, reviewer)
        review = (ROOT / ".claude/skills/review/SKILL.md").read_text()
        orchestrator = (ROOT / ".claude/skills/orchestrator/SKILL.md").read_text()
        self.assertIn("one read-only pass", review)
        self.assertIn("Only `/orchestrator`", review)
        self.assertIn("at most three total attempts", orchestrator)

    def test_only_two_safety_hooks_remain(self):
        settings = json.loads((ROOT / ".claude/settings.json").read_text())
        self.assertEqual(set(settings["hooks"]), {"PreToolUse"})
        commands = [
            handler["command"]
            for entry in settings["hooks"]["PreToolUse"]
            for handler in entry["hooks"]
        ]
        self.assertEqual(
            commands,
            [
                '"$CLAUDE_PROJECT_DIR"/.claude/hooks/block-destructive.sh',
                '"$CLAUDE_PROJECT_DIR"/.claude/hooks/protect-secrets.sh',
            ],
        )
        for path in (
            ".claude/hooks/announce-agent.sh",
            ".claude/hooks/enforce-loop.sh",
            ".claude/hooks/post-edit-lint.sh",
            ".claude/hooks/record-verdict.sh",
            "scripts/harness/run_phase.py",
        ):
            self.assertFalse((ROOT / path).exists())

    def test_active_instructions_do_not_reference_retired_runtime(self):
        active = [ROOT / ".claude/settings.json"]
        active.extend(ROOT.glob(".claude/agents/*.md"))
        active.extend(ROOT.glob(".claude/skills/*/SKILL.md"))
        source = "\n".join(path.read_text() for path in active)
        for retired in (
            "record-verdict",
            "enforce-loop",
            "loop-state",
            "HARNESS_RUN_PHASE",
            "run_phase.py",
        ):
            self.assertNotIn(retired, source)

    def test_user_docs_are_lean_and_match_the_active_contract(self):
        docs = [ROOT / "README.md", ROOT / "README.en.md", ROOT / "HARNESS.md"]
        source = "\n".join(path.read_text() for path in docs)
        for stale in (
            "fable",
            "forced TDD",
            "always call the tester",
            "leaves experimental agent-team settings untouched",
        ):
            self.assertNotIn(stale, source)
        for expected in ("Opus", "Sonnet", "네 관점", "3"):
            self.assertIn(expected, source)
        self.assertLessEqual(len((ROOT / "README.md").read_text().splitlines()), 100)
        self.assertLessEqual(len((ROOT / "HARNESS.md").read_text().splitlines()), 150)
        english_readme = (ROOT / "README.en.md").read_text()
        self.assertIn("New main sessions | Sonnet | high", english_readme)
        self.assertIn("experimental Agent Teams value", english_readme)


if __name__ == "__main__":
    unittest.main()
