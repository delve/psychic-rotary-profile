#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find "$SCRIPT_DIR" -maxdepth 1 ! -name setup.sh -type f -exec cp {} ~/ \;
