<a id="readme-top"></a>

[![Contributors][contributors-shield]][contributors-url]
[![Forks][forks-shield]][forks-url]
[![Stargazers][stars-shield]][stars-url]
[![Issues][issues-shield]][issues-url]
[![MIT License][license-shield]][license-url]

<br />
<div align="center">
  <h1>bws-sync</h1>
  <p>
    CLI tool to sync environment secrets to Bitwarden Secrets Manager with GitHub Actions integration.
    <br />
    <br />
    <a href="https://github.com/martingit-dev/bws-sync/issues/new?labels=bug">Report Bug</a>
    &middot;
    <a href="https://github.com/martingit-dev/bws-sync/issues/new?labels=enhancement">Request Feature</a>
  </p>
</div>

<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#why-use-bws-sync">Why Use bws-sync?</a></li>
        <li><a href="#built-with">Built With</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#installation">Installation</a></li>
      </ul>
    </li>
    <li><a href="#usage">Usage</a>
      <ul>
        <li><a href="#status--drift-detection">Status &amp; Drift Detection</a></li>
        <li><a href="#push">Push</a></li>
        <li><a href="#pull">Pull</a></li>
        <li><a href="#prune">Prune</a></li>
        <li><a href="#github-actions-integration">GitHub Actions Integration</a></li>
        <li><a href="#what-stays-manual">What Stays Manual</a></li>
      </ul>
    </li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
    <li><a href="#acknowledgments">Acknowledgments</a></li>
  </ol>
</details>

## About The Project

Managing secrets across multiple environments and repositories gets messy fast. You end up copy-pasting values into GitHub Secrets, losing track of what changed, and scrambling when a key needs rotating across 8 repos.

**bws-sync** is a single Bash script that keeps your `.env` and Bitwarden Secrets Manager in agreement, and wires the resulting secret UUIDs into your GitHub Actions workflows.

It is **drift-first**. Run it with no arguments and it tells you, in one command and zero prompts, exactly how your local `.env` and BWS disagree:

```console
$ bws-sync
my-api · dev · .env
  12 in sync   +2 local-only   -1 bws-only   ~3 changed

  + RESEND_KEY, STRIPE_KEY   (in .env, not in BWS)
  - OLD_API_URL              (in BWS, not in .env)
  ~ DATABASE_URL, LOG_LEVEL, PORT   (values differ)

  bws-sync push [KEY…]   ·   bws-sync pull [KEY…]   ·   bws-sync prune
```

Then you act on it — all of it, or a single key:

```bash
bws-sync push                 # push every drifted key
bws-sync push STRIPE_KEY      # push just one
bws-sync pull DATABASE_URL    # pull just one, rest of .env untouched
```

The `bws` CLI has no notion of a `.env` file, no bulk operations, and no idea what your workflow expects. That gap is what this fills.

### Why Use bws-sync?

| Benefit                     | Details                                                                                                                                      |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| **Drift detection**         | One zero-prompt command shows exactly which keys are missing, orphaned, or out of date — before you push anything. `bws` alone can't tell you. |
| **Bulk + surgical**         | Push or pull your whole `.env` in one go, or a single key when that's all that changed. `bws` creates one secret per invocation.             |
| **Centralized management**  | Update a secret in one place (Bitwarden) and every service that uses it picks it up. No need to update GitHub, AWS, Vercel, etc. separately. |
| **Audit trail**             | Bitwarden logs who accessed or changed what and when. GitHub Secrets has no history — once you overwrite a value, the old one is gone.       |
| **Granular access control** | Give a teammate access to staging secrets without exposing production. With GitHub Secrets, anyone with repo admin access sees everything.   |
| **Easy rotation**           | Change a value once in BWS, all pipelines get the new value on next run. No need to touch each repo/environment individually.                |
| **Scales across repos**     | If you have multiple repos sharing secrets like a database URL or API key, you manage it in one place instead of copy-pasting across repos.  |

### Built With

- [![Bash][Bash-badge]][Bash-url]
- [![Bitwarden][Bitwarden-badge]][Bitwarden-url]

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Getting Started

### Prerequisites

- [Bitwarden Secrets Manager CLI (`bws`)](https://bitwarden.com/help/secrets-manager-cli/)
- [`jq`](https://jqlang.github.io/jq/)
- Bash 4+ (for associative arrays)
- [GitHub CLI (`gh`)](https://cli.github.com/) — only for `bws-sync wire`; authenticate via `gh auth login`

Install on macOS:

```bash
brew install bitwarden/bws/bws gh jq
```

### Installation

1. Clone the repo and put the script on your `PATH`:

   ```bash
   git clone https://github.com/martingit-dev/bws-sync.git
   chmod +x bws-sync/sync-secrets.sh
   ln -s "$PWD/bws-sync/sync-secrets.sh" ~/.local/bin/bws-sync
   ```

   You now run `bws-sync` from inside any project — the current directory is the target.

2. Store your BWS access tokens, one per environment. **This file is the only secret on disk** — keep it out of any repo.

   ```bash
   mkdir -p ~/.config/bws-sync

   cat > ~/.config/bws-sync/secrets.conf << 'EOF'
   BWS_ACCESS_TOKEN_DEV="your-dev-token"
   BWS_ACCESS_TOKEN_STAGING="your-staging-token"
   BWS_ACCESS_TOKEN_PRODUCTION="your-production-token"
   EOF
   ```

   Override the location with `BWS_SYNC_CONFIG_DIR` if you keep it elsewhere.

3. In each project, record its BWS project IDs once:

   ```console
   $ cd ~/code/my-api
   $ bws-sync init
   i Project IDs for my-api (blank to skip an environment)
     dev:        4f2c...
     staging:    9a71...
     production:
     env file [.env]:
   ✓ Wrote .bws-sync.toml — safe to commit
   ```

   This writes `.bws-sync.toml`, so you never type a project ID again:

   ```toml
   env_file = ".env"

   [projects]
   dev = "4f2c…"
   staging = "9a71…"
   ```

   **Commit it.** A BWS project ID is a UUID, not a credential — it is useless without an access token, and tokens live only in `~/.config/bws-sync/`.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Usage

```
bws-sync [command] [KEY...] [flags]

Commands:
  (none)     status — show drift between .env and BWS. Read-only, no prompts.
  init       write .bws-sync.toml with this repo's project IDs
  push       push .env values to BWS (all drifted keys, or just KEY...)
  pull       pull BWS values into .env (dev only; all keys, or just KEY...)
  prune      delete BWS secrets that no longer exist in .env
  wire       rewrite deploy-<env>.yml with current secret UUIDs

Flags:
  -e, --env <dev|staging|production>   default: dev
  -d, --dir <path>                     default: current directory
  -y, --yes                            skip confirmations
```

### Status & Drift Detection

Running `bws-sync` with no arguments is the fast path. It reads your `.env`, lists the BWS project, and prints the difference — without prompting, and without writing anything:

| Marker | Meaning                                        |
| ------ | ---------------------------------------------- |
| `+`    | key is in `.env` but not in BWS                |
| `-`    | key is in BWS but not in `.env` (orphan)       |
| `~`    | key exists in both, values differ (**dev only**) |

It exits `1` when there is drift, so you can drop it into a pre-deploy check or a `Makefile`.

For **staging and production, only keys are compared** — those values are never read into `.env` or printed to your terminal.

### Push

```bash
bws-sync push                        # dev: push every key that is new or changed
bws-sync push STRIPE_KEY             # dev: push one key
bws-sync push -e staging             # staging: prompt for each value
bws-sync push -e production API_KEY  # production: prompt for one value
```

For **dev**, values come straight from `.env`. For **staging and production**, the script prompts you for each value — press Enter to keep whatever BWS already has. Nothing is ever copied from your dev `.env` into a higher environment.

### Pull

```bash
bws-sync pull                # rewrite .env from BWS (backs up to .env.bak first)
bws-sync pull DATABASE_URL   # replace one line in .env, leave everything else alone
```

Pull is **dev-only**, by design — production values have no business landing in a local file. The named-key form is the one you'll use day to day: a teammate rotates one credential, you pull just that key.

A full `pull` shows you exactly what it's about to do — which values get replaced, and which local-only keys will be lost — before it touches the file.

### Prune

```bash
bws-sync prune               # delete every BWS key missing from .env
bws-sync prune OLD_API_URL   # delete one
```

Deletion in BWS is permanent, so this always confirms.

### GitHub Actions Integration

```bash
bws-sync wire -e production
```

This rewrites the `secrets: |` block in `.github/workflows/deploy-<env>.yml` with the current `UUID > KEY` mappings, then makes sure the GitHub environment exists and has `BWS_ACCESS_TOKEN` set. Commit the workflow diff afterwards.

Keeping this behind its own command means a routine `push` no longer rewrites files in your repo as a side effect.

### What Stays Manual

Honest limits. The `bws` CLI exposes only `project`, `secret`, `run`, and `config`. **Machine accounts, access tokens, and granting a machine account access to a project exist only in the Bitwarden web vault** — there is no API or CLI for them.

So when you onboard a *new* project, you still do this by hand, once:

1. Create the BWS project (or use `bws project create`).
2. Create a machine account, and grant it access to that project.
3. Issue an access token, and paste it into `~/.config/bws-sync/secrets.conf`.
4. Copy the project ID into `bws-sync init`.

Everything after that — every key, every environment, every rotation — is `bws-sync`.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Contributing

Contributions are welcome. If you have a suggestion, please fork the repo and create a pull request, or open an issue with the "enhancement" tag.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/your-feature`)
3. Commit your Changes (`git commit -m 'Add some feature'`)
4. Push to the Branch (`git push origin feature/your-feature`)
5. Open a Pull Request

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## License

Distributed under the MIT License. See `LICENSE` for more information.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Contact

Project Link: [https://github.com/martingit-dev/bws-sync](https://github.com/martingit-dev/bws-sync)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Acknowledgments

- [Bitwarden Secrets Manager](https://bitwarden.com/products/secrets-manager/)
- [GitHub CLI](https://cli.github.com/)
- [Best-README-Template](https://github.com/othneildrew/Best-README-Template)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- MARKDOWN LINKS & IMAGES -->

[contributors-shield]: https://img.shields.io/github/contributors/martingit-dev/bws-sync.svg?style=for-the-badge
[contributors-url]: https://github.com/martingit-dev/bws-sync/graphs/contributors
[forks-shield]: https://img.shields.io/github/forks/martingit-dev/bws-sync.svg?style=for-the-badge
[forks-url]: https://github.com/martingit-dev/bws-sync/network/members
[stars-shield]: https://img.shields.io/github/stars/martingit-dev/bws-sync.svg?style=for-the-badge
[stars-url]: https://github.com/martingit-dev/bws-sync/stargazers
[issues-shield]: https://img.shields.io/github/issues/martingit-dev/bws-sync.svg?style=for-the-badge
[issues-url]: https://github.com/martingit-dev/bws-sync/issues
[license-shield]: https://img.shields.io/github/license/martingit-dev/bws-sync.svg?style=for-the-badge
[license-url]: https://github.com/martingit-dev/bws-sync/blob/main/LICENSE
[Bash-badge]: https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white
[Bash-url]: https://www.gnu.org/software/bash/
[Bitwarden-badge]: https://img.shields.io/badge/Bitwarden-175DDC?style=for-the-badge&logo=bitwarden&logoColor=white
[Bitwarden-url]: https://bitwarden.com/products/secrets-manager/
