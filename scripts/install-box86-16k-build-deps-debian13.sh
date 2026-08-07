#!/bin/sh
set -eu
sudo dpkg --add-architecture armhf
sudo apt-get update
sudo apt-get install -y \
    git cmake make python3 dpkg-dev debhelper gcc-arm-linux-gnueabihf \
    libc6-dev-armhf-cross libc6:armhf binutils
