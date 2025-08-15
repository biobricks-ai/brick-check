#!/usr/bin/env bash

# Script to verify that the downloaded bricks have assets and that they load

find info/1/ -type f -name stderr -print0 | xargs -0 -I{} sh -c 'cat "{}"; echo'