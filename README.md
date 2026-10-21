# spnngl/linux-packaging

Signed APT and RPM repository of the spnngl packages, served from GitHub Pages at `https://spnngl.github.io/linux-packaging`. It builds nothing: it mirrors the `.deb` and `.rpm` assets that other spnngl repositories attach to their GitHub releases, and signs and indexes them.

| Package | Source | Needs |
| --- | --- | --- |
| `tokenmtr` | [spnngl/tokenmtr](https://github.com/spnngl/tokenmtr) | glibc 2.43 or newer (Ubuntu 26.04, Debian testing, Fedora 44, openSUSE Tumbleweed); `amd64`/`x86_64` and `arm64`/`aarch64` |

Each package states what it needs: older distributions refuse the install.

## Install

Add the repository once, then install the packages of the table with the package manager.

### Debian, Ubuntu

```sh install-deb
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL https://spnngl.github.io/linux-packaging/key.asc -o /etc/apt/keyrings/spnngl.asc
sudo curl -fsSL https://spnngl.github.io/linux-packaging/spnngl.sources -o /etc/apt/sources.list.d/spnngl.sources
sudo apt update
```

Then `sudo apt install tokenmtr`.

### Fedora

```sh install-rpm
sudo curl -fsSL https://spnngl.github.io/linux-packaging/spnngl.repo -o /etc/yum.repos.d/spnngl.repo
```

Then `sudo dnf install tokenmtr`. dnf asks once to import the key.

### openSUSE

```sh install-zypper
sudo zypper addrepo --refresh https://spnngl.github.io/linux-packaging/spnngl.repo
sudo zypper --gpg-auto-import-keys refresh
```

Then `sudo zypper install tokenmtr`.

## Trust

One OpenPGP key signs the `InRelease` file, every rpm and the rpm metadata. Its public half is [`keys/spnngl.asc`](keys/spnngl.asc), also served at `/key.asc`; read its fingerprint with `gpg --show-keys --with-fingerprint keys/spnngl.asc`.

The key vouches for provenance: a package is served only if `gh attestation verify` proves that the release workflow of its source repository built it at the tagged commit, and the release is immutable. Packages are rebuilt into the repository from `packages.toml` on every run, so the site holds one version of each package; older ones stay on the GitHub releases.

## Updates

Renovate opens a pull request for each release of a package in `packages.toml` (`renovate.json5`). CI builds the repository with a throwaway key, installs every package on each distribution, and Renovate merges the pull request when that passes. The merge signs and deploys the repository. A weekly run installs from the live site.

## Add a package

Add a `[[package]]` to `packages.toml` (fields are documented there) once the source repository's releases meet this contract:

- A GitHub release per `v<version>` tag, without a pre-release suffix: deb and rpm order it differently.
- Immutable releases turned on, so an asset never changes under a pinned tag.
- Four assets named per distribution convention: a `.deb` for `amd64` and `arm64`, an `.rpm` for `x86_64` and `aarch64`, with the package name of the manifest and the tag's version.
- Each asset attested by `actions/attest` in the workflow named in the manifest.

Add the package to the table above. The pull request's CI proves the contract.

## Maintainers

Set up once:

0. Create the public repository, empty: the calls below return 404 until it exists. Push `main` only after step 3, since a build on `main` needs the signing key.

   ```sh
   gh repo create spnngl/linux-packaging --public
   git remote add origin git@github.com:spnngl/linux-packaging.git
   ```

1. Create the environment `signing`, restricted to the `main` branch, and the Pages site built by GitHub Actions:

   ```sh
   gh api -X PUT repos/spnngl/linux-packaging/environments/signing --input - <<< '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
   gh api -X POST repos/spnngl/linux-packaging/environments/signing/deployment-branch-policies -f name=main -f type=branch
   gh api -X POST repos/spnngl/linux-packaging/pages -f build_type=workflow
   ```

2. Generate the signing key and its revocation certificate. The key has no expiry (apt and dnf never refresh a key file) and no passphrase (it would sit beside the key and protect nothing). Keep the revocation certificate and an offline copy of the private key.

   ```sh
   export GNUPGHOME="$(mktemp -d)"
   gpg --batch --passphrase '' --quick-generate-key 'spnngl packages <lola.2lannoy@gmail.com>' rsa4096 sign never
   gpg --armor --export 'spnngl packages' > keys/spnngl.asc
   gpg --armor --export-secret-keys 'spnngl packages' | gh secret set GPG_PRIVATE_KEY --env signing --repo spnngl/linux-packaging
   gpg --output revoke.asc --gen-revoke 'spnngl packages'
   ```

3. Commit `keys/spnngl.asc`, and enable the Renovate app on the repository.

To revoke the key, publish `revoke.asc`, generate a new key as above and replace `keys/spnngl.asc`: every client then installs the new key again, since no client refreshes a key file.
