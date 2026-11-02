# Contributing to bws-sync

Thanks for your interest in contributing!

## Getting Started

1. Fork the repository
2. Clone your fork
3. Create a feature branch: `git checkout -b my-feature`
4. Make your changes
5. Test with your own BWS project
6. Commit and push: `git push origin my-feature`
7. Open a Pull Request

## Guidelines

- Keep it simple. This is a single-script tool and should stay that way.
- Test your changes against all three environment flows (dev, staging, production).
- Follow the existing code style (bash, `set -euo pipefail`, the `log_*` functions).
- Don't introduce new dependencies unless absolutely necessary.

## Reporting Issues

Open an issue with:
- What you expected to happen
- What actually happened
- Your OS and Bash version (`bash --version`)
- BWS CLI version (`bws --version`)

## Ideas Welcome

If you have a feature idea but aren't sure about the approach, open an issue to discuss before writing code.
