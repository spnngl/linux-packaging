#!/usr/bin/env nu

# Builds the signed APT and RPM repository of `packages.toml` into <out>, ready for GitHub Pages.
# Needs a current gh (authenticated: GH_TOKEN; the one of Ubuntu is too old for `attestation verify
# --signer-workflow`), reprepro, createrepo-c, rpm, gnupg.
# Run from the repository root, on ubuntu:26.04 as in CI.

const deb_arches = ["amd64" "arm64"]
const rpm_arches = ["aarch64" "x86_64"]

def fail [msg: string] {
  error make --unspanned { msg: $msg }
}

# Primary-key fingerprint of the first key in the keyring (secret) or in an armored file (public).
def secret-fingerprint [] {
  ^gpg --batch --with-colons --list-secret-keys
  | lines
  | where {|line| $line | str starts-with "fpr:" }
  | first
  | split row ":"
  | get 9
}

def file-fingerprint [file: path] {
  ^gpg --batch --with-colons --show-keys $file
  | lines
  | where {|line| $line | str starts-with "fpr:" }
  | first
  | split row ":"
  | get 9
}

# Puts the signing key in the (empty) keyring of $env.GNUPGHOME and returns its fingerprint.
def load-key [throwaway: bool] {
  if $throwaway {
    ^gpg --batch --quiet --pinentry-mode loopback --passphrase "" --quick-generate-key "spnngl packages (throwaway) <packages@invalid>" rsa4096 sign never
  } else {
    let key = ($env.GPG_PRIVATE_KEY? | default "")
    if ($key | is-empty) {
      fail "GPG_PRIVATE_KEY is empty: set it, or pass --throwaway to sign with a key generated here"
    }
    $key | ^gpg --batch --quiet --import
  }
  secret-fingerprint
}

# Downloads the release of one manifest entry, checks it and returns the paths of its packages.
def fetch-package [pkg: record, dir: path] {
  let release = $"($pkg.repo)@($pkg.tag)"
  let version = ($pkg.tag | str replace --regex '^v' "")

  # An immutable release never changes under a pinned tag.
  if (^gh api $"repos/($pkg.repo)/releases/tags/($pkg.tag)" --jq .immutable | str trim) != "true" {
    fail $"($release) is not an immutable release"
  }

  mkdir $dir
  ^gh release download $pkg.tag --repo $pkg.repo --pattern "*.deb" --pattern "*.rpm" --dir $dir
  let debs = (glob $"($dir)/*.deb" | sort)
  let rpms = (glob $"($dir)/*.rpm" | sort)

  # The release workflow of that repository must have built each asset at that tag.
  for file in ($debs ++ $rpms) {
    ^gh attestation verify $file --repo $pkg.repo --signer-workflow $"($pkg.repo)/($pkg.workflow)" --source-ref $"refs/tags/($pkg.tag)"
  }

  let deb_info = ($debs | each {|file|
    { file: $file, name: (^dpkg-deb -f $file Package | str trim), version: (^dpkg-deb -f $file Version | str trim), arch: (^dpkg-deb -f $file Architecture | str trim) }
  })
  let rpm_info = ($rpms | each {|file|
    let fields = (^rpm -qp --queryformat '%{NAME} %{VERSION} %{ARCH}' $file | split row " ")
    { file: $file, name: $fields.0, version: $fields.1, arch: $fields.2 }
  })

  for info in ($deb_info ++ $rpm_info) {
    if $info.name != $pkg.name or $info.version != $version {
      fail $"($info.file | path basename) is ($info.name) ($info.version), the manifest says ($pkg.name) ($version)"
    }
  }
  if ($deb_info | get arch | sort) != $deb_arches {
    fail $"($release) must hold one deb per architecture ($deb_arches | str join ' '), found ($deb_info | get arch | str join ' ')"
  }
  if ($rpm_info | get arch | sort) != $rpm_arches {
    fail $"($release) must hold one rpm per architecture ($rpm_arches | str join ' '), found ($rpm_info | get arch | str join ' ')"
  }

  { debs: $debs, rpms: $rpms }
}

# Checks the signatures with only the public key, as a client does.
def verify-site [out: path, work: path] {
  let home = $"($work)/verify-gnupg"
  mkdir $home
  chmod 700 $home
  with-env { GNUPGHOME: $home } {
    ^gpg --batch --quiet --import $"($out)/key.asc"
    ^gpg --batch --verify $"($out)/deb/dists/stable/InRelease"
    ^gpg --batch --verify $"($out)/rpm/repodata/repomd.xml.asc" $"($out)/rpm/repodata/repomd.xml"
  }
  let rpmdb = $"($work)/verify-rpmdb"
  ^rpmkeys --dbpath $rpmdb --import $"($out)/key.asc"
  for file in (glob $"($out)/rpm/packages/*.rpm") {
    let result = (^rpmkeys --dbpath $rpmdb --checksig $file | str trim)
    if not ($result | str contains "signatures OK") {
      fail $"rpm signature check: ($result)"
    }
  }
}

def main [
  out: path # output directory, created by the script, must not exist
  --throwaway # sign with a key generated here instead of GPG_PRIVATE_KEY (pull requests)
] {
  if ($out | path exists) {
    fail $"($out) exists"
  }
  let work = (mktemp --directory)
  let gnupg = $"($work)/gnupg"
  mkdir $gnupg
  chmod 700 $gnupg
  $env.GNUPGHOME = $gnupg

  let fingerprint = (load-key $throwaway)
  if not $throwaway {
    # keys/spnngl.asc is the single source of truth for the public key.
    let published = (file-fingerprint "keys/spnngl.asc")
    if $published != $fingerprint {
      fail $"the signing key ($fingerprint) is not keys/spnngl.asc ($published)"
    }
  }
  print $"signing with ($fingerprint)"

  let packages = (open packages.toml | get package | each {|pkg|
    print $"fetching ($pkg.repo) ($pkg.tag)"
    fetch-package $pkg $"($work)/download/($pkg.name)"
  })
  let debs = ($packages | get debs | flatten)
  let rpms = ($packages | get rpms | flatten)

  mkdir $out
  let out = ($out | path expand)

  # --outdir keeps reprepro's database out of the site.
  ^reprepro --confdir ./deb/conf --basedir $"($work)/reprepro" --outdir $"($out)/deb" includedeb stable ...$debs

  mkdir $"($out)/rpm/packages"
  for rpm in $rpms {
    cp $rpm $"($out)/rpm/packages/"
  }
  let site_rpms = (glob $"($out)/rpm/packages/*.rpm")
  ^rpmsign --define $"_gpg_name ($fingerprint)" --define $"_gpg_path ($gnupg)" --addsign ...$site_rpms
  ^createrepo_c --quiet $"($out)/rpm"
  ^gpg --batch --yes --armor --detach-sign --output $"($out)/rpm/repodata/repomd.xml.asc" $"($out)/rpm/repodata/repomd.xml"

  for file in (glob site/*) {
    cp $file $"($out)/"
  }
  if $throwaway {
    ^gpg --batch --armor --export $fingerprint | save $"($out)/key.asc"
  } else {
    cp keys/spnngl.asc $"($out)/key.asc"
  }

  verify-site $out $work
  rm --recursive --force $work
  print $"built ($out): ($debs | length) debs, ($rpms | length) rpms"
}
