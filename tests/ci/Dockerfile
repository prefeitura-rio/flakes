# Clean-room environment for the self-test: Ubuntu (dash as /bin/sh), no global
# git identity, unprivileged user and a single-user Nix. It mirrors what a
# GitHub-hosted runner provides closely enough to catch tests that only pass on
# the machine of whoever wrote them.
FROM ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash runner \
 && mkdir -m 0755 /nix \
 && chown runner /nix

USER runner
WORKDIR /home/runner
ENV USER=runner HOME=/home/runner
# The installer is pinned to a release and checked against its published SHA-256
# before it runs. The installer in turn verifies the Nix tarball it downloads.
ARG NIX_VERSION=2.34.7
ARG NIX_INSTALL_SHA256=e9d447ce3d2ff62d7ff9cb6ef401de6fa8acb148839dd00f7271945d7b638b14
RUN curl --proto '=https' --tlsv1.2 -sSfL "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" -o /tmp/install-nix \
 && echo "${NIX_INSTALL_SHA256}  /tmp/install-nix" | sha256sum --check - \
 && sh /tmp/install-nix --no-daemon \
 && rm /tmp/install-nix \
 && mkdir -p ~/.config/nix \
 && printf '%s\n' \
      'experimental-features = nix-command flakes' \
      'extra-substituters = https://devenv.cachix.org https://prefeitura-rio.cachix.org' \
      'extra-trusted-public-keys = devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw= prefeitura-rio.cachix.org-1:Y+SotJw1tzXRsM/a6Af2mwX8HTZjnefjsuFT0DNevX8=' \
      > ~/.config/nix/nix.conf

# devenv is installed by run-clean.sh from the lock of the repository under test,
# as the workflow does, so the container never uses a different devenv than CI.
ENV PATH=/home/runner/.nix-profile/bin:$PATH
