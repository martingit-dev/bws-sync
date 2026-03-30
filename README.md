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
        <li><a href="#how-it-determines-secret-keys">How It Determines Secret Keys</a></li>
        <li><a href="#github-actions-integration">GitHub Actions Integration</a></li>
      </ul>
    </li>
    <li><a href="#roadmap">Roadmap</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
    <li><a href="#acknowledgments">Acknowledgments</a></li>
  </ol>
</details>

## About The Project

Managing secrets across multiple environments and repositories gets messy fast. You end up copy-pasting values into GitHub Secrets, losing track of what changed, and scrambling when a key needs rotating across 8 repos.

**bws-sync** is a single Bash script that syncs your project secrets into Bitwarden Secrets Manager and wires them into your GitHub Actions workflows automatically.

- **Dev** — reads your `.env` file and bulk-uploads all variables to BWS
- **Staging / Production** — prompts you for each secret value interactively (like `gh secret set`), then updates your workflow files and GitHub environment configuration

### Why Use bws-sync?

| Benefit                     | Details                                                                                                                                      |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
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
- [GitHub CLI (`gh`)](https://cli.github.com/) — authenticated via `gh auth login`
- [`jq`](https://jqlang.github.io/jq/)
- Bash 4+ (for associative arrays)

Install on macOS:

```bash
brew install bitwarden/bws/bws gh jq
```

### Installation

1. Clone the repo

   ```bash
   git clone https://github.com/martingit-dev/bws-sync.git
   ```

2. Make the script executable

   ```bash
   chmod +x sync-secrets.sh
   ```

3. Create a config file with your BWS access tokens

   ```bash
   mkdir -p ~/.config/bws-sync

   cat > ~/.config/bws-sync/secrets.conf << 'EOF'
   BWS_ACCESS_TOKEN_DEV="your-dev-token"
   BWS_ACCESS_TOKEN_STAGING="your-staging-token"
   BWS_ACCESS_TOKEN_PRODUCTION="your-production-token"
   EOF
   ```

   You can override the config directory with `BWS_SYNC_CONFIG_DIR`:

   ```bash
   export BWS_SYNC_CONFIG_DIR="/your/custom/path/.bws-sync"
   ```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Usage

Point the script at your project repository:

```bash
./sync-secrets.sh /path/to/your/project
```

The script will interactively walk you through:

1. Select an environment (dev, staging, or production)
2. Enter your BWS Project ID
3. Validate access to the project
4. Sync secrets:
   - **Dev** — reads from `.env` or `.env.local`, lists all variables, and syncs after confirmation
   - **Staging / Production** — prompts for each value, then updates your workflow file and GitHub environment

### How It Determines Secret Keys

The script looks for keys in this order:

1. `.env.example` — preferred, should list all required variables
2. `.env` — fallback for dev
3. `.env.local` — fallback for dev
4. Existing BWS secrets — fallback for staging/production

### GitHub Actions Integration

For staging and production, the script:

- Updates `deploy-{env}.yml` workflow files with the correct `UUID > KEY` mappings in the `secrets: |` block
- Creates the GitHub environment if it doesn't exist
- Sets `BWS_ACCESS_TOKEN` as an environment secret
- Offers to clean up any other secrets (since BWS handles them all)

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
