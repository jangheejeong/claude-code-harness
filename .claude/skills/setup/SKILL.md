---
name: setup
description: Create the minimum requirement and planning scaffold for a new harness-managed repository. Use for `/setup` or first-time harness onboarding; do not use for dependency installation, service startup, or general environment setup.
---

# Setup

1. Identify the target repository and infer its stack, run command, test command, conventions, and non-goals.
2. Create `REQUIREMENTS.md` from `docs/harness/REQUIREMENTS.template.md` only when missing.
3. Create a minimal `Plans.md` only when missing; never overwrite existing project instructions.
4. Summarize what the user must review before `/plan` or `/work`.
