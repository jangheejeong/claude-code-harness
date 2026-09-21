#!/usr/bin/env python3
"""Install one global Claude harness while preserving unmanaged user assets."""

import argparse
import copy
import hashlib
import json
import os
from datetime import datetime
from pathlib import Path
import shlex
import tempfile
from typing import Dict, Iterable, List, Optional, Tuple, Union


AGENTS = ("explorer", "planner", "coder", "tester", "reviewer", "documenter")
SKILLS = ("plan", "work", "review", "release", "setup", "orchestrator")
SAFETY_HOOKS = ("block-destructive", "protect-secrets")
RETIRED_HOOKS = (
    "announce-agent",
    "post-edit-lint",
    "record-verdict",
    "enforce-loop",
)
RETIRED_AGENT_TEAMS_ENV = "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_manifest(root: Path) -> Dict[str, List[str]]:
    return json.loads((root / "scripts/legacy_manifest.json").read_text())


def validate_parent(path: Path) -> None:
    for parent in (path.parent,) + tuple(path.parents):
        if parent.is_symlink() and parent not in (
            Path("/var"),
            Path("/tmp"),
            Path("/etc"),
        ):
            raise ValueError("refusing symlinked installation directory: {}".format(parent))
        if parent.exists() and not parent.is_dir():
            raise ValueError("installation parent is not a directory: {}".format(parent))


def known_file(
    path: Path,
    manifest_key: str,
    source: Optional[Path],
    manifest: Dict[str, List[str]],
) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    allowed = set(manifest.get(manifest_key, []))
    if source is not None:
        allowed.add(digest(source))
    return digest(path) in allowed


def known_skill_dir(
    path: Path,
    name: str,
    source: Path,
    manifest: Dict[str, List[str]],
) -> bool:
    if not path.is_dir() or path.is_symlink():
        return False
    children = list(path.iterdir())
    skill_file = path / "SKILL.md"
    return (
        children == [skill_file]
        and known_file(
            skill_file,
            "skills/{}/SKILL.md".format(name),
            source / "SKILL.md",
            manifest,
        )
    )


def managed_destination(
    destination: Path,
    source: Path,
    manifest_key: str,
    kind: str,
    manifest: Dict[str, List[str]],
) -> bool:
    if destination.is_symlink():
        return destination.resolve(strict=False) == source.resolve(strict=False)
    if kind == "skill":
        return known_skill_dir(
            destination,
            source.name,
            source,
            manifest,
        )
    return known_file(destination, manifest_key, source, manifest)


def command_targets(handler: object, paths: Iterable[Union[Path, str]]) -> bool:
    if not isinstance(handler, dict):
        return False
    if set(handler) - {"type", "command", "timeout"}:
        return False
    if handler.get("type") != "command" or not isinstance(handler.get("command"), str):
        return False
    try:
        argv = shlex.split(handler["command"])
    except ValueError:
        return False
    expected = {str(path) for path in paths}
    return len(argv) == 1 and argv[0] in expected


def clean_hook_entries(
    entries: object,
    managed_paths: Iterable[Union[Path, str]],
) -> List[dict]:
    if not isinstance(entries, list):
        raise ValueError("hook event entries must be lists")
    cleaned = []
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
            raise ValueError("hook entries must contain a hooks list")
        remaining = [
            handler
            for handler in entry["hooks"]
            if not command_targets(handler, managed_paths)
        ]
        if remaining:
            item = copy.deepcopy(entry)
            item["hooks"] = remaining
            cleaned.append(item)
    return cleaned


def rendered_settings(
    existing: dict,
    managed_paths: Iterable[Union[Path, str]],
    safety_paths: Optional[Dict[str, Path]],
    retired_runner: Path,
    remove_retired_agent_teams: bool = False,
) -> str:
    if not isinstance(existing, dict):
        raise ValueError("settings.json must be an object")
    result = copy.deepcopy(existing)
    hooks = result.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("settings.json hooks must be an object")
    for event, entries in list(hooks.items()):
        cleaned = clean_hook_entries(entries, managed_paths)
        if cleaned:
            hooks[event] = cleaned
        else:
            hooks.pop(event)

    if safety_paths is not None:
        hooks.setdefault("PreToolUse", []).extend(
            [
                {
                    "matcher": "Bash",
                    "hooks": [
                        {
                            "type": "command",
                            "command": shlex.join(
                                [str(safety_paths["block-destructive"])]
                            ),
                        }
                    ],
                },
                {
                    "matcher": "Edit|Write",
                    "hooks": [
                        {
                            "type": "command",
                            "command": shlex.join(
                                [str(safety_paths["protect-secrets"])]
                            ),
                        }
                    ],
                },
            ]
        )

    env = result.get("env")
    if isinstance(env, dict):
        if env.get("HARNESS_RUN_PHASE") == str(retired_runner):
            env.pop("HARNESS_RUN_PHASE")
        if remove_retired_agent_teams and env.get(RETIRED_AGENT_TEAMS_ENV) == "1":
            env.pop(RETIRED_AGENT_TEAMS_ENV)
        if not env:
            result.pop("env")
    return json.dumps(result, indent=2, ensure_ascii=False) + "\n"


def without_duplicate_hooks(existing: dict, inherited: dict) -> dict:
    result = copy.deepcopy(existing)
    hooks = result.get("hooks")
    inherited_hooks = inherited.get("hooks", {})
    if hooks is None:
        return result
    if not isinstance(hooks, dict) or not isinstance(inherited_hooks, dict):
        raise ValueError("settings.json hooks must be an object")

    for event, entries in list(hooks.items()):
        if not isinstance(entries, list):
            raise ValueError("hook event entries must be lists")
        inherited_entries = inherited_hooks.get(event, [])
        if not isinstance(inherited_entries, list):
            raise ValueError("inherited hook event entries must be lists")

        cleaned = []
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
                raise ValueError("hook entries must contain a hooks list")
            entry_scope = {key: value for key, value in entry.items() if key != "hooks"}
            inherited_handlers = []
            for inherited_entry in inherited_entries:
                if not isinstance(inherited_entry, dict):
                    raise ValueError("inherited hook entries must be objects")
                inherited_scope = {
                    key: value
                    for key, value in inherited_entry.items()
                    if key != "hooks"
                }
                if inherited_scope == entry_scope:
                    inherited_handlers.extend(inherited_entry.get("hooks", []))

            remaining = [
                handler
                for handler in entry["hooks"]
                if handler not in inherited_handlers
            ]
            if remaining:
                item = copy.deepcopy(entry)
                item["hooks"] = remaining
                cleaned.append(item)
        if cleaned:
            hooks[event] = cleaned
        else:
            hooks.pop(event)

    if not hooks:
        result.pop("hooks")
    return result


def atomic_write(path: Path, content: str) -> bool:
    if path.exists() and path.read_text() == content:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".harness-", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(content)
        os.replace(temporary, str(path))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def content_would_change(path: Path, content: str) -> bool:
    return not path.exists() or path.read_text() != content


def install(
    root: Path,
    global_root: Path,
    workspace: Optional[Path] = None,
    dry_run: bool = False,
) -> dict:
    root = root.resolve(strict=True)
    global_root = global_root.absolute()
    workspace = workspace.resolve(strict=True) if workspace is not None else None
    manifest = load_manifest(root)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    global_backup = global_root / "harness-backups" / stamp
    workspace_backup = (
        workspace / ".claude/harness-backups" / stamp if workspace else None
    )

    link_actions: List[Tuple[Path, Path, Optional[Path]]] = []
    remove_actions: List[Tuple[Path, Path]] = []
    backups: List[str] = []

    targets = []
    for name in AGENTS:
        targets.append(
            (
                root / ".claude/agents" / "{}.md".format(name),
                global_root / "agents" / "{}.md".format(name),
                "agents/{}.md".format(name),
                "file",
            )
        )
    for name in SKILLS:
        targets.append(
            (
                root / ".claude/skills" / name,
                global_root / "skills" / name,
                "skills/{}/SKILL.md".format(name),
                "skill",
            )
        )
    for name in SAFETY_HOOKS:
        targets.append(
            (
                root / ".claude/hooks" / "{}.sh".format(name),
                global_root / "hooks" / "{}.sh".format(name),
                "hooks/{}.sh".format(name),
                "file",
            )
        )

    for source, destination, manifest_key, kind in targets:
        if not source.exists():
            raise ValueError("missing source asset: {}".format(source))
        validate_parent(destination)
        if destination.is_symlink() and destination.resolve(strict=False) == source:
            continue
        backup = None
        if destination.exists() or destination.is_symlink():
            if not managed_destination(
                destination,
                source,
                manifest_key,
                kind,
                manifest,
            ):
                raise ValueError("unmanaged collision (not overwritten): {}".format(destination))
            backup = global_backup / destination.relative_to(global_root)
        link_actions.append((source, destination, backup))

    managed_global_retired_paths = []
    for name in RETIRED_HOOKS:
        path = global_root / "hooks" / "{}.sh".format(name)
        if not (path.exists() or path.is_symlink()):
            managed_global_retired_paths.append(path)
            continue
        key = "hooks/{}.sh".format(name)
        retired_source = root / ".claude/hooks" / "{}.sh".format(name)
        managed_link = (
            path.is_symlink()
            and path.resolve(strict=False) == retired_source.resolve(strict=False)
        )
        if managed_link or known_file(path, key, None, manifest):
            remove_actions.append((path, global_backup / path.relative_to(global_root)))
            managed_global_retired_paths.append(path)

    workspace_settings = None
    workspace_rendered = None
    workspace_local_settings = None
    workspace_local_rendered = None
    if workspace is not None:
        workspace_claude = workspace / ".claude"
        cleanup = []
        for name in AGENTS:
            cleanup.append(
                (
                    workspace_claude / "agents" / "{}.md".format(name),
                    root / ".claude/agents" / "{}.md".format(name),
                    "agents/{}.md".format(name),
                    "file",
                )
            )
        for name in SKILLS:
            cleanup.append(
                (
                    workspace_claude / "skills" / name,
                    root / ".claude/skills" / name,
                    "skills/{}/SKILL.md".format(name),
                    "skill",
                )
            )
        for name in SAFETY_HOOKS + RETIRED_HOOKS:
            cleanup.append(
                (
                    workspace_claude / "hooks" / "{}.sh".format(name),
                    root / ".claude/hooks" / "{}.sh".format(name),
                    "hooks/{}.sh".format(name),
                    "file",
                )
            )

        for destination, source, manifest_key, kind in cleanup:
            validate_parent(destination)
            if not (destination.exists() or destination.is_symlink()):
                continue
            if source.exists():
                managed = managed_destination(
                    destination,
                    source,
                    manifest_key,
                    kind,
                    manifest,
                )
            else:
                managed = (
                    destination.is_symlink()
                    and destination.resolve(strict=False)
                    == source.resolve(strict=False)
                ) or known_file(
                    destination, manifest_key, None, manifest
                )
            if managed and destination.resolve(strict=False) != source.resolve(strict=False):
                remove_actions.append(
                    (
                        destination,
                        workspace_backup / destination.relative_to(workspace_claude),
                    )
                )

        for state_name in ("loop-state.json", "loop-state.json.done"):
            state = workspace_claude / "notes" / state_name
            validate_parent(state)
            if state.exists() and not state.is_symlink():
                remove_actions.append(
                    (
                        state,
                        workspace_backup / "notes" / state_name,
                    )
                )

        scheduled_removals = {destination for destination, _ in remove_actions}
        workspace_paths = []
        for name in SAFETY_HOOKS + RETIRED_HOOKS:
            path = workspace_claude / "hooks" / "{}.sh".format(name)
            if not (path.exists() or path.is_symlink()) or path in scheduled_removals:
                workspace_paths.append(path)
        workspace_commands = list(workspace_paths)
        workspace_commands.extend(
            "$CLAUDE_PROJECT_DIR/.claude/hooks/{}.sh".format(path.stem)
            for path in workspace_paths
        )
        workspace_commands.extend(
            "${{CLAUDE_PROJECT_DIR}}/.claude/hooks/{}.sh".format(path.stem)
            for path in workspace_paths
        )

        workspace_settings = workspace_claude / "settings.json"
        validate_parent(workspace_settings)
        workspace_settings_data = {}
        if workspace_settings.exists():
            if workspace_settings.is_symlink():
                raise ValueError("refusing symlinked settings file: {}".format(workspace_settings))
            workspace_settings_data = json.loads(workspace_settings.read_text())
            workspace_rendered = rendered_settings(
                workspace_settings_data,
                workspace_commands,
                None,
                root / "scripts/harness/run_phase.py",
            )
            workspace_settings_data = json.loads(workspace_rendered)

        workspace_local_settings = workspace_claude / "settings.local.json"
        validate_parent(workspace_local_settings)
        if workspace_local_settings.exists():
            if workspace_local_settings.is_symlink():
                raise ValueError(
                    "refusing symlinked settings file: {}".format(
                        workspace_local_settings
                    )
                )
            local_cleaned = json.loads(
                rendered_settings(
                    json.loads(workspace_local_settings.read_text()),
                    workspace_commands,
                    None,
                    root / "scripts/harness/run_phase.py",
                )
            )
            local_cleaned = without_duplicate_hooks(
                local_cleaned,
                workspace_settings_data,
            )
            workspace_local_rendered = (
                json.dumps(local_cleaned, indent=2, ensure_ascii=False) + "\n"
            )

    global_settings = global_root / "settings.json"
    validate_parent(global_settings)
    if global_settings.is_symlink():
        raise ValueError("refusing symlinked settings file: {}".format(global_settings))
    existing_global = (
        json.loads(global_settings.read_text()) if global_settings.exists() else {}
    )
    global_safety_paths = [
        global_root / "hooks" / "{}.sh".format(name)
        for name in SAFETY_HOOKS
    ]
    safety_paths = {
        name: global_root / "hooks" / "{}.sh".format(name)
        for name in SAFETY_HOOKS
    }
    global_rendered = rendered_settings(
        existing_global,
        global_safety_paths + managed_global_retired_paths,
        safety_paths,
        root / "scripts/harness/run_phase.py",
        remove_retired_agent_teams=True,
    )

    settings_updated = int(content_would_change(global_settings, global_rendered))
    if workspace_settings is not None and workspace_rendered is not None:
        settings_updated += int(
            content_would_change(workspace_settings, workspace_rendered)
        )
    if workspace_local_settings is not None and workspace_local_rendered is not None:
        settings_updated += int(
            content_would_change(workspace_local_settings, workspace_local_rendered)
        )

    planned_backups = [
        str(backup)
        for _, _, backup in link_actions
        if backup is not None
    ] + [str(backup) for _, backup in remove_actions]

    if not dry_run:
        for source, destination, backup in link_actions:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if backup is not None:
                backup.parent.mkdir(parents=True, exist_ok=True)
                destination.rename(backup)
                backups.append(str(backup))
            destination.symlink_to(source, target_is_directory=source.is_dir())

        for destination, backup in remove_actions:
            backup.parent.mkdir(parents=True, exist_ok=True)
            destination.rename(backup)
            backups.append(str(backup))

        atomic_write(global_settings, global_rendered)
        if workspace_settings is not None and workspace_rendered is not None:
            atomic_write(workspace_settings, workspace_rendered)
        if workspace_local_settings is not None and workspace_local_rendered is not None:
            atomic_write(workspace_local_settings, workspace_local_rendered)

    return {
        "dry_run": dry_run,
        "links_updated": len(link_actions),
        "managed_duplicates_removed": len(remove_actions),
        "settings_updated": settings_updated,
        "backups": backups,
        "planned_backups": planned_backups,
        "note": "Claude Code watches existing agent and skill directories; new sessions always load this version.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--global-root",
        type=Path,
        default=Path.home() / ".claude",
    )
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        result = install(
            Path(__file__).resolve().parents[1],
            args.global_root,
            args.workspace,
            args.dry_run,
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print("Install failed: {}".format(error), file=os.sys.stderr)
        return 1
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
