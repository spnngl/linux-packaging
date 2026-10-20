#!/usr/bin/env nu

# Installs every package of packages.toml from the repository <site> in a fresh <image> container,
# with the commands of README.md (the fences tagged `install-<family>`), and checks each installed
# version against the manifest (PLAN.md, decisions 9 and 13).
#
# <site> is a directory, served here by a container on a private network, or a base URL, used
# as-is. A directory is built for the public URL, so its two repository files and the README
# commands are rewritten to the test server's URL: nothing else differs from a user's install.
# Needs docker and, from a directory, nothing else. Run from the repository root.

const public_url = "https://spnngl.github.io/linux-packaging"

def fail [msg: string] {
  error make --unspanned { msg: $msg }
}

# The package manager family of an image, which picks the README fence and the install command.
def family [image: string] {
  if ($image | str starts-with "debian") or ($image | str starts-with "ubuntu") {
    "deb"
  } else if ($image | str starts-with "fedora") {
    "rpm"
  } else if ($image | str starts-with "opensuse") {
    "zypper"
  } else {
    fail $"no package manager family for the image ($image)"
  }
}

# The commands of a README fence tagged `install-<family>`.
def readme-commands [family: string] {
  let blocks = (open --raw README.md | parse --regex '(?s)```sh install-(?<family>\w+)\n(?<commands>.*?)```' | where family == $family)
  if ($blocks | length) != 1 {
    fail $"README.md needs exactly one fence tagged `sh install-($family)`"
  }
  $blocks.0.commands
}

# What a fresh image lacks for the README commands, and the command installing a package.
def setup [family: string] {
  match $family {
    "deb" => { prepare: "apt-get update -qq && apt-get install -y -qq curl ca-certificates", install: "apt install", version: "dpkg-query -W -f '${Version}'" }
    "rpm" => { prepare: "true", install: "dnf install", version: "rpm -q --queryformat '%{VERSION}'" }
    "zypper" => { prepare: "true", install: "zypper --non-interactive install", version: "rpm -q --queryformat '%{VERSION}'" }
  }
}

# Runs the commands in the image; `yes` answers the confirmations of apt and dnf that a user answers by hand (zypper reads a terminal, so it gets --non-interactive).
def run-in-image [image: string, script: string, network?: string] {
  let network_args = if $network == null { [] } else { [--network $network] }
  $env.SCRIPT = $script
  ^docker run --rm ...$network_args --env SCRIPT --env DEBIAN_FRONTEND=noninteractive $image sh -c 'printf "%s\n" "$SCRIPT" > /tmp/install.sh; yes | sh -ex /tmp/install.sh'
}

def main [
  site: string # directory of the built site, or base URL of a deployed one
  image: string # docker image to install in, such as ubuntu:26.04
  --key-file: path # public key the site must serve, byte for byte (keys/spnngl.asc)
] {
  let family = (family $image)
  let setup = (setup $family)
  let packages = (open packages.toml | get package)

  let served = ($site | str starts-with "http")
  let name = $"spnngl-site-(random uuid | str substring 0..<8)"
  let base = if $served { $site | str trim --right --char "/" } else { $"http://($name)" }

  if not $served {
    let tmp = (mktemp --directory)
    for file in ["spnngl.repo" "spnngl.sources"] {
      open --raw $"($site)/($file)" | str replace --all $public_url $base | save $"($tmp)/($file)"
    }
    ^docker network create $name | ignore
    ^docker run --detach --rm --name $name --network $name -v $"($site | path expand):/www:ro" -v $"($tmp)/spnngl.repo:/www/spnngl.repo:ro" -v $"($tmp)/spnngl.sources:/www/spnngl.sources:ro" busybox httpd -f -p 80 -h /www | ignore
  }

  let result = (try {
    if $key_file != null {
      let published = if $served { http get --raw $"($base)/key.asc" } else { open --raw $"($site)/key.asc" }
      if $published != (open --raw $key_file) {
        fail $"($base)/key.asc is not ($key_file)"
      }
    }

    let commands = (readme-commands $family | str replace --all $public_url $base)
    let install = ($packages | each {|pkg| [$setup.install $pkg.name] | str join " " })
    let checks = ($packages | each {|pkg|
      ["test \"$(" $setup.version " " $pkg.name ")\" = " ($pkg.tag | str replace --regex '^v' "")] | str join ""
    })
    # A container runs as root: no sudo.
    let script = ([$setup.prepare $commands] ++ $install ++ $checks | str join "\n" | str replace --all --regex '(?m)^sudo ' "")
    run-in-image $image $script (if $served { null } else { $name })
    { ok: true }
  } catch {|err|
    { ok: false, msg: $err.msg }
  })

  if not $served {
    ^docker rm --force $name | ignore
    ^docker network rm $name | ignore
  }
  if not $result.ok {
    fail $"($image): ($result.msg)"
  }
  print $"($image): installed ($packages | get name | str join ' ') from ($base)"
}
