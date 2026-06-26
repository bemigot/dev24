#!/bin/sh

docker run --rm -it \
  -v "$HOME/e/p24core/scripts:/opt/scripts:ro" \
  -v "$HOME/e/p24core:/opt/project:ro" \
  -w /opt \
ubuntu:20.04
