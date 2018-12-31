#!/bin/sh

cd src
mkdocs build
rsync -av --delete site/* ../site/
rm -rf site/
cd -