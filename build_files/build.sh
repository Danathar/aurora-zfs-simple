#!/bin/bash
#
# Script: build_files/build.sh
# What: Installs extra packages and enables services during the container image
#       build.  This script runs inside the container (not on your host) as part
#       of a Containerfile "RUN" step.
#

# Safety flags — stop immediately if anything goes wrong:
#   -o pipefail  = if any command in a pipeline (cmd1 | cmd2) fails, the whole
#                  pipeline is treated as failed (by default only the last
#                  command's exit code matters).
#   -u           = treat references to unset variables as errors instead of
#                  silently expanding to an empty string.
#   -e           = exit the script immediately when any command returns a
#                  non-zero (failure) exit code.
#   -x           = print every command to stderr before executing it (useful
#                  for debugging — you can see exactly what ran and in what
#                  order in the build log).
set -ouex pipefail

### Install packages

# "dnf5" is Fedora's package manager (the successor to dnf/yum).
# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/43/x86_64/repoview/index.html&protocol=https&redirect=1

# Install tmux (a terminal multiplexer) from the standard Fedora repos.
# "-y" means "answer yes to all prompts" so the install runs unattended
# during the container build.
dnf5 install -y tmux

# Use a COPR Example:
# COPRs are community-maintained package repositories (like PPAs on Ubuntu).
# You enable them temporarily to install a package, then disable them so the
# final image does not keep pulling from that repo on the user's machine.
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

#### Example for enabling a System Unit File

# "systemctl enable" tells systemd to start the podman.socket unit
# automatically at boot.  A ".socket" unit means systemd will listen on a
# Unix socket and start the actual podman service on-demand when something
# connects to it (socket activation), rather than running podman all the time.
# This is done at build time so the service is pre-enabled in the final image.
systemctl enable podman.socket
