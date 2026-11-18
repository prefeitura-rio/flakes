# Clean-room environment for the self-test: Ubuntu (dash as /bin/sh), no global
# git identity, unprivileged user and a single-user Nix. It mirrors what a
# GitHub-hosted runner provides closely enough to catch tests that only pass on
# the machine of whoever wrote them.
FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash runner \
 && mkdir -m 0755 /nix \
 && chown runner /nix

USER runner
WORKDIR /home/runner
ENV USER=runner HOME=/home/runner
RUN curl --proto '=https' --tlsv1.2 -sSfL https://nixos.org/nix/install | sh -s -- --no-daemon \
 && mkdir -p ~/.config/nix \
 && printf '%s\n' \
      'experimental-features = nix-command flakes' \
      'extra-substituters = https://devenv.cachix.org https://prefeitura-rio.cachix.org' \
      'extra-trusted-public-keys = devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw= prefeitura-rio.cachix.org-1:Y+SotJw1tzXRsM/a6Af2mwX8HTZjnefjsuFT0DNevX8=' \
      > ~/.config/nix/nix.conf

ENV PATH=/home/runner/.nix-profile/bin:$PATH
RUN nix profile install nixpkgs#devenv
