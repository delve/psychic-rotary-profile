#!/bin/bash

. "$HOME/k8s_functions.sh"
. "$HOME/aws_functions.sh"

### Python venv functions
function venv {
    if [ -d ".venv" ]; then
        source .venv/bin/activate
    else
        echo "No virtual environment found in the current directory."
    fi
}

function newVenv {
    if [ -d ".venv" ]; then
        echo ".venv already exists. Activating it."
        source .venv/bin/activate
    else
        python3 -m venv .venv
        source .venv/bin/activate
    fi
}
### end Python venv functions
