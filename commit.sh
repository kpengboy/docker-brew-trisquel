#!/bin/bash
set -e

cd $(readlink -f $(dirname "$BASH_SOURCE"))

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
	versions=( "${versions[@]/docker}" )  # Ignore the "docker" dir
fi
versions=( "${versions[@]%/}" )

git checkout --orphan newbranch
for version in "${versions[@]}"; do
	git add "$version"
done
git commit -m "$(date +%Y-%m-%d) debootstraps"
git branch -M newbranch dist
git push -f origin dist
git gc --prune=all

docker push kpengboy/trisquel
