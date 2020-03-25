#!/bin/bash
set -eo pipefail

cd "$(readlink -f "$(dirname "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	for dir in */; do
		if [ "$dir" != "docker/" ]; then
			versions+=( "$dir" );
		fi
	done
fi
versions=( "${versions[@]%/}" )

get_part() {
	dir="$1"
	shift
	part="$1"
	shift
	if [ -f "$dir/$part" ]; then
		cat "$dir/$part"
		return 0
	fi
	if [ -f "$part" ]; then
		cat "$part"
		return 0
	fi
	if [ $# -gt 0 ]; then
		echo "$1"
		return 0
	fi
	return 1
}

repo="$(get_part . repo '')"
if [ "$repo" ]; then
	if [[ "$repo" != */* ]]; then
		user="$(docker info | awk '/^Username:/ { print $2 }')"
		if [ "$user" ]; then
			repo="$user/$repo"
		fi
	fi
fi

latest="$(get_part . latest '')"
for version in "${versions[@]}"; do
	dir="$(readlink -f "$version")"
	variant="$(get_part "$dir" variant 'minbase')"
	components="$(get_part "$dir" components 'main')"
	include="$(get_part "$dir" include '')"
	suite="$(get_part "$dir" suite "$version")"
	debootstrap_mirror="$(get_part "$dir" debootstrap-mirror '')"
	mirror="$(get_part "$dir" mirror "$debootstrap_mirror")"
	script="$(get_part "$dir" script '')"
	
	args=( --dir "$dir" --compression 'xz' debootstrap )
	[ -z "$variant" ] || args+=( --variant="$variant" )
	[ -z "$components" ] || args+=( --components="$components" )
	[ -z "$include" ] || args+=( --include="$include" )
	
	debootstrapVersion="$(debootstrap --version)"
	debootstrapVersion="${debootstrapVersion##* }"
	if dpkg --compare-versions "$debootstrapVersion" '>=' '1.0.69'; then
		args+=( --force-check-gpg )
	fi
	
	args+=( "$suite" )
	if [ "$debootstrap_mirror" ]; then
		args+=( "$debootstrap_mirror" )
		if [ "$mirror" ]; then
			args+=( "$mirror" )
			if [ "$script" ]; then
				args+=( "$script" )
			fi
		fi
	fi
	
	mkimage="$(readlink -f "${MKIMAGE:-"mkimage.sh"}")"
	{
		echo "$(basename "$mkimage") ${args[*]/"$dir"/.}"
		echo
		echo 'https://github.com/kpengboy/docker/blob/master/contrib/mkimage.sh'
	} > "$dir/build-command.txt"
	
	sudo rm -rf "$dir/rootfs"
	sudo nice ionice -c 3 "$mkimage" "${args[@]}" 2>&1 | tee "$dir/build.log"
	
	sudo chown -R "$(id -u):$(id -g)" "$dir"
	
	if [ "$repo" ]; then
		( set -x && docker build -t "${repo}:${suite}" "$dir" )
		if [ "$suite" != "$version" ]; then
			( set -x && docker tag "${repo}:${suite}" "${repo}:${version}" )
		fi
		if [ "$suite" = "$latest" ]; then
			( set -x && docker tag "$repo:$suite" "$repo:latest" )
		fi
		docker run --rm "${repo}:${suite}" bash -xc '
			cat /etc/apt/sources.list
			echo
			cat /etc/os-release 2>/dev/null
			echo
			cat /etc/lsb-release 2>/dev/null
			echo
			cat /etc/debian_version 2>/dev/null
			true
		'
		docker run --rm "${repo}:${suite}" dpkg-query -f '${Package}\t${Version}\n' -W > "$dir/build.manifest"
	fi
	
	if [ "${backports[$suite]}" ]; then
		mkdir -p "$dir/backports"
		echo "FROM $origRepo:$suite" > "$dir/backports/Dockerfile"
		cat >> "$dir/backports/Dockerfile" <<-'EOF'
			RUN awk '$1 ~ "^deb" { $3 = $3 "-backports"; print; exit }' /etc/apt/sources.list > /etc/apt/sources.list.d/backports.list
		EOF
		
		if [ "$repo" ]; then
			( set -x && docker build -t "${repo}:${suite}-backports" "$dir/backports" )
		fi
	fi
	
	IFS=$'\n'
	set -o noglob
	slimExcludes=( $(get_part "$dir" slim-excludes '' | grep -vE '^#|^$') )
	set +o noglob
	unset IFS
	if [ "${#slimExcludes[@]}" -gt 0 ]; then
		sudo rm -rf "$dir/slim/rootfs"
		mkdir -p "$dir/slim/rootfs"
		sudo tar --extract --file "$dir/rootfs.tar.xz" --directory "$dir/slim/rootfs"
		
		dpkgCfgFile="$dir/slim/rootfs/etc/dpkg/dpkg.cfg.d/docker"
		sudo mkdir -p "$(dirname "$dpkgCfgFile")"
		{
			echo '# This is the "slim" variant of the Debian base image.'
			echo '# Many files which are normally unnecessary in containers are excluded,'
			echo '# and this configuration file keeps them that way.'
		} | sudo tee -a "$dpkgCfgFile"
		
		neverExclude='/usr/share/doc/*/copyright'
		for slimExclude in "${slimExcludes[@]}"; do
			{
				echo
				echo "# dpkg -S '$slimExclude'"
				if dpkgOutput="$(sudo chroot "$dir/slim/rootfs" dpkg -S "$slimExclude" 2>&1)"; then
					echo "$dpkgOutput" | sed 's/: .*//g; s/, /\n/g' | sort -u | xargs
				else
					echo "$dpkgOutput"
				fi | fold -w 76 -s | sed 's/^/#  /'
				echo "path-exclude $slimExclude"
			} | sudo tee -a "$dpkgCfgFile"
			if [[ "$slimExclude" == *'/*' ]]; then
				if [ -d "$dir/slim/rootfs/$(dirname "$slimExclude")" ]; then
					# use two passes so that we don't fail trying to remove directories from $neverExclude
					sudo chroot "$dir/slim/rootfs" \
						find "$(dirname "$slimExclude")" \
							-mindepth 1 \
							-not -path "$neverExclude" \
							-not -type d \
							-delete
					sudo chroot "$dir/slim/rootfs" \
						find "$(dirname "$slimExclude")" \
							-mindepth 1 \
							-empty \
							-delete
				fi
			else
				sudo chroot "$dir/slim/rootfs" rm -f "$slimExclude"
			fi
		done
		{
			echo
			echo '# always include these files, especially for license compliance'
			echo "path-include $neverExclude"
		} | sudo tee -a "$dpkgCfgFile"
		
		sudo tar --numeric-owner --create --auto-compress --file "$dir/slim/rootfs.tar.xz" --directory "$dir/slim/rootfs" --transform='s,^./,,' .
		sudo rm -rf "$dir/slim/rootfs"
		cp "$dir/Dockerfile" "$dir/slim/"
		
		sudo chown -R "$(id -u):$(id -g)" "$dir/slim"
		
		ls -lh "$dir/rootfs.tar.xz" "$dir/slim/rootfs.tar.xz"
		
		if [ "$repo" ]; then
			( set -x && docker build -t "${repo}:${suite}-slim" "$dir/slim" )
			docker images "${repo}:${suite}" | tail -1
			docker images "${repo}:${suite}-slim" | tail -1
		fi
	fi
	
	find "$dir" \
		\( \
			-name '*.txt' \
			-or -name '*.log' \
		\) \
		-exec sed -i \
			-e 's!'"$PWD"'!/«BREWDIR»!g' \
			-e 's!'"$(dirname "$mkimage")"'!/«MKIMAGEDIR»!g' \
			'{}' +
done
