#!/bin/bash
# THE install command (v1.50), in the ChromeOS VT2 shell:  sudo bash install.sh
# Run it again after any interruption: it resumes where it stopped. Options: sudo bash install.sh --help
exec bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/install/go.sh" "$@"
