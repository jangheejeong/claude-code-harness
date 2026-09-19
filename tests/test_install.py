import hashlib
import importlib.util
import json
import shlex
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def installer():
    spec = importlib.util.spec_from_file_location("installer", ROOT / "scripts/install.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.global_root = Path(self.temporary.name) / "home with spaces" / ".claude"
        self.workspace = Path(self.temporary.name) / "workspace"
        self.workspace.mkdir(parents=True)

    def install(self, workspace=True):
        return installer().install(
            ROOT,
            self.global_root,
            self.workspace if workspace else None,
        )

    def test_global_install_is_idempotent_and_preserves_user_settings(self):
        self.global_root.mkdir(parents=True)
        custom = {
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": "custom-user-hook"}],
        }
        settings = {
            "other": "keep",
            "env": {
                "HARNESS_RUN_PHASE": str(ROOT / "scripts/harness/run_phase.py"),
                "KEEP_ME": "yes",
            },
            "hooks": {"PreToolUse": [custom]},
        }
        settings_path = self.global_root / "settings.json"
        settings_path.write_text(json.dumps(settings))

        first = self.install(workspace=False)
        first_settings = settings_path.read_bytes()
        second = self.install(workspace=False)

        self.assertEqual(first["links_updated"], 14)
        self.assertEqual(second["links_updated"], 0)
        self.assertEqual(second["settings_updated"], 0)
        self.assertEqual(first_settings, settings_path.read_bytes())
        installed = json.loads(settings_path.read_text())
        self.assertEqual(installed["other"], "keep")
        self.assertEqual(installed["env"], {"KEEP_ME": "yes"})
        self.assertIn(custom, installed["hooks"]["PreToolUse"])
        self.assertEqual(len(installed["hooks"]["PreToolUse"]), 3)
        self.assertEqual(
            (self.global_root / "agents/reviewer.md").resolve(),
            ROOT / ".claude/agents/reviewer.md",
        )
        self.assertEqual(
            (self.global_root / "skills/review").resolve(),
            ROOT / ".claude/skills/review",
        )

    def test_exact_workspace_duplicates_and_retired_state_are_backed_up(self):
        workspace_claude = self.workspace / ".claude"
        agent = workspace_claude / "agents/coder.md"
        skill = workspace_claude / "skills/review"
        hook = workspace_claude / "hooks/block-destructive.sh"
        state = workspace_claude / "notes/loop-state.json"
        agent.parent.mkdir(parents=True)
        skill.mkdir(parents=True)
        hook.parent.mkdir(parents=True)
        state.parent.mkdir(parents=True)
        shutil.copy2(ROOT / ".claude/agents/coder.md", agent)
        shutil.copy2(ROOT / ".claude/skills/review/SKILL.md", skill / "SKILL.md")
        shutil.copy2(ROOT / ".claude/hooks/block-destructive.sh", hook)
        state.write_text('{"attempt": 2}')

        result = self.install()

        self.assertFalse(agent.exists())
        self.assertFalse(skill.exists())
        self.assertFalse(hook.exists())
        self.assertFalse(state.exists())
        self.assertEqual(result["managed_duplicates_removed"], 4)
        self.assertEqual(len(result["backups"]), 4)
        self.assertTrue(all(Path(path).exists() for path in result["backups"]))

    def test_retired_hook_registration_is_removed_but_custom_hook_is_kept(self):
        self.global_root.mkdir(parents=True)
        hooks_dir = self.global_root / "hooks"
        custom = {"type": "command", "command": "custom-stop-hook"}
        retired = {
            "type": "command",
            "command": shlex.join([str(hooks_dir / "enforce-loop.sh")]),
        }
        settings_path = self.global_root / "settings.json"
        settings_path.write_text(
            json.dumps(
                {
                    "hooks": {
                        "Stop": [{"hooks": [retired, custom]}],
                    }
                }
            )
        )

        self.install(workspace=False)

        installed = json.loads(settings_path.read_text())["hooks"]
        self.assertEqual(installed["Stop"], [{"hooks": [custom]}])
        self.assertIn("PreToolUse", installed)

    def test_workspace_project_variable_hook_registration_is_removed(self):
        module = installer()
        workspace_claude = self.workspace / ".claude"
        hooks = workspace_claude / "hooks"
        hooks.mkdir(parents=True)
        retired = hooks / "enforce-loop.sh"
        retired.write_bytes(b"old managed loop hook")
        manifest = module.load_manifest(ROOT)
        manifest["hooks/enforce-loop.sh"] = [
            hashlib.sha256(retired.read_bytes()).hexdigest()
        ]
        settings = workspace_claude / "settings.json"
        settings.write_text(
            json.dumps(
                {
                    "hooks": {
                        "Stop": [
                            {
                                "hooks": [
                                    {
                                        "type": "command",
                                        "command": '"$CLAUDE_PROJECT_DIR"/.claude/hooks/enforce-loop.sh',
                                    },
                                    {
                                        "type": "command",
                                        "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/enforce-loop.sh",
                                    },
                                ]
                            }
                        ]
                    }
                }
            )
        )

        with mock.patch.object(module, "load_manifest", return_value=manifest):
            module.install(ROOT, self.global_root, self.workspace)

        self.assertFalse(retired.exists())
        self.assertEqual(json.loads(settings.read_text()).get("hooks"), {})

    def test_unknown_collision_is_refused_before_any_mutation(self):
        collision = self.global_root / "skills/review"
        collision.mkdir(parents=True)
        (collision / "SKILL.md").write_text("my custom review workflow")

        with self.assertRaises(ValueError):
            self.install(workspace=False)

        self.assertEqual(
            (collision / "SKILL.md").read_text(),
            "my custom review workflow",
        )
        self.assertFalse((self.global_root / "agents/planner.md").exists())

    def test_symlinked_workspace_claude_is_refused_before_mutation(self):
        self.global_root.mkdir(parents=True)
        sentinel = self.global_root / "sentinel.txt"
        sentinel.write_text("keep")
        (self.workspace / ".claude").symlink_to(
            self.global_root,
            target_is_directory=True,
        )

        with self.assertRaises(ValueError):
            self.install()

        self.assertEqual(sentinel.read_text(), "keep")
        self.assertFalse((self.global_root / "agents/planner.md").exists())

    def test_only_known_retired_files_or_exact_links_are_removed(self):
        module = installer()
        hooks = self.global_root / "hooks"
        hooks.mkdir(parents=True)
        unknown = hooks / "enforce-loop.sh"
        unknown.write_text("custom hook")
        settings = self.global_root / "settings.json"
        custom_registration = {
            "type": "command",
            "command": str(unknown),
        }
        settings.write_text(
            json.dumps({"hooks": {"Stop": [{"hooks": [custom_registration]}]}})
        )
        manifest = module.load_manifest(ROOT)
        manifest["hooks/record-verdict.sh"] = [
            hashlib.sha256(b"old managed hook").hexdigest()
        ]
        known = hooks / "record-verdict.sh"
        known.write_bytes(b"old managed hook")

        with mock.patch.object(module, "load_manifest", return_value=manifest):
            result = module.install(ROOT, self.global_root)

        self.assertEqual(unknown.read_text(), "custom hook")
        self.assertFalse(known.exists())
        self.assertEqual(result["managed_duplicates_removed"], 1)
        self.assertEqual(
            json.loads(settings.read_text())["hooks"]["Stop"],
            [{"hooks": [custom_registration]}],
        )

    def test_dry_run_reports_without_mutating(self):
        self.global_root.mkdir(parents=True)
        settings = self.global_root / "settings.json"
        original = '{"custom": true}\n'
        settings.write_text(original)

        result = installer().install(
            ROOT,
            self.global_root,
            self.workspace,
            dry_run=True,
        )

        self.assertTrue(result["dry_run"])
        self.assertEqual(result["links_updated"], 14)
        self.assertEqual(result["settings_updated"], 1)
        self.assertEqual(result["backups"], [])
        self.assertEqual(settings.read_text(), original)
        self.assertFalse((self.global_root / "agents/planner.md").exists())


if __name__ == "__main__":
    unittest.main()
