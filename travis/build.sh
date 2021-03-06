#!/bin/bash -ex

echo $PATH
export LC_ALL=C.UTF-8

if [[ -d .cabal && -d .ghc ]]; then
    cp -a .cabal .ghc /root
fi

cabal update

# Detect if the cache is warmed up.  If so build both versions.
if ghc-pkg --package-db /root/.cabal/store/ghc-`ghc --numeric-version`/package.db list | grep gi-gtk; then
    cabal new-build
    all_done=true
else
    # Just build ltk and leksah-server
    cabal new-build ltk leksah-server
    all_done=false
fi

# update the cache
rm -rf .cabal
cp -a /root/.cabal ./
rm -rf .ghc
cp -a /root/.ghc ./

if [ "$all_done" = false ]; then
    echo "Still warming up the Cache.  Please rerun this build."
    exit 1
fi