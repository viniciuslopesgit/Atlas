# Contributing

Thank you for your interest. Atlas holds AWS credentials and can change real infrastructure, so the priority is that it never leaks a key or changes anything the user did not ask for. That comes before speed or new features.

## Branches

- **`dev`**: where the work happens. Pull Requests go here.
- **`main`**: only the stable version, with what is needed to build it. Updated automatically; does not accept direct Pull Requests.

## Setup

Requires macOS 14 or later to build (Atlas itself runs from macOS 12) and the Xcode Command Line Tools (`xcode-select --install`), or Xcode.

```bash
git clone -b dev https://github.com/viniciuslopesgit/Atlas.git
cd Atlas
Atlas/scripts/install-hooks.sh     # check before each commit and each push
Atlas/scripts/test.sh              # unit tests
Atlas/scripts/check.sh             # quick check (the same as the pre-commit hook)
```

More in [docs/development.md](docs/development.md).

## Rules for changes

1. **Tests in the same Pull Request.** A new or changed feature comes with tests in `Atlas/Tests/AtlasTests`. A fix comes with a test that failed before it. A new file in `Sources/` without tests blocks the commit.
2. **Tests never touch the network, the Keychain or your folders.** Use `MockURLProtocol.client`, `InMemorySecretStore` and temporary folders; the tests run in a sandbox that blocks the rest.
3. **Credentials only sign requests.** Never put an access key on a command line, in a file or in a log. Terraform gets them through the child process's environment only.
4. **Sensitive code stays where it is reviewed.** Network, Keychain, processes, opening files or links, and moving or deleting files only live in the files listed in `Atlas/scripts/check.sh` (`REVIEWED`); a new place needs its own attack test in `SecurityTests.swift`.
5. **Changes to AWS ask for confirmation** and show what is going to happen.
6. **No dependencies.** The AWS client (SigV4 and the protocols) lives in `Atlas/Sources/Atlas/AWS/`. A new dependency needs an issue first (MIT-compatible license, maintenance, real need).
7. **Conventional Commits** (`feat:`, `fix:`, …), checked by the `commit-msg` hook. Code, comments, commits and CHANGELOG in English.

CI runs `Atlas/scripts/check.sh --full` on macOS 14 and 15, and the built app on macOS 12, on every Pull Request to `dev`, and it must pass.

## Reporting bugs

Open an issue with the Atlas and macOS versions, Apple silicon or Intel, the steps to reproduce and what you expected. Bugs get the `bug` label and block the version from being promoted to stable.

Vulnerabilities: do **not** use public issues, see [SECURITY.md](SECURITY.md).

## License

By contributing you agree that your contribution is released under the [MIT License](LICENSE).
