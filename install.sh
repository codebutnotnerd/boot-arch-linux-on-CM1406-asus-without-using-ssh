#!/bin/bash
exec bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/install/go.sh" "$@"
