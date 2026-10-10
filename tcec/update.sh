#!/bin/bash

unset EXE
# shellcheck source-path=SCRIPTDIR
wget -nv -O install.sh https://raw.githubusercontent.com/SnowballSH/Avalanche/master/tcec/install.sh &&
    . ./install.sh
