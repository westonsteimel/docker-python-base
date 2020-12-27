#!/usr/bin/env bash
# This script is based on the official version at https://github.com/docker-library/python/
#
# Copyright (c) 2014 Docker, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
# 
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

set -Eeuo pipefail
shopt -s nullglob

# https://www.python.org/downloads/23Introduction (under "OpenPGP Public Keys")
declare -A gpgKeys=(
	# gpg: key AA65421D: public key "Ned Deily (Python release signing key) <nad@acm.org>" imported
	[3.6]='0D96DF4D4110E5C43FBFB17F2D347EA6AA65421D'
	# https://www.python.org/dev/peps/pep-0494/#release-manager-and-crew

	# gpg: key AA65421D: public key "Ned Deily (Python release signing key) <nad@acm.org>" imported
	[3.7]='0D96DF4D4110E5C43FBFB17F2D347EA6AA65421D'
	# https://www.python.org/dev/peps/pep-0537/#release-manager-and-crew

	# gpg: key B26995E310250568: public key "\xc5\x81ukasz Langa (GPG langa.pl) <lukasz@langa.pl>" imported
	[3.8]='E3FF2839C048B25C084DEBE9B26995E310250568'
	# https://www.python.org/dev/peps/pep-0569/#release-manager-and-crew

	# gpg: key B26995E310250568: public key "\xc5\x81ukasz Langa (GPG langa.pl) <lukasz@langa.pl>" imported
	[3.9]='E3FF2839C048B25C084DEBE9B26995E310250568'
	# https://www.python.org/dev/peps/pep-0596/#release-manager-and-crew

	# gpg: key 64E628F8D684696D: public key "Pablo Galindo Salgado <pablogsal@gmail.com>" imported
	[3.10]='A035C8C19219BA821ECEA86B64E628F8D684696D'
	# https://www.python.org/dev/peps/pep-0619/#release-manager-and-crew
)

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

python_versions=( "$@" )
if [ ${#python_versions[@]} -eq 0 ]; then
	python_versions=( "3.6" "3.7" "3.8" "3.9" "3.10-rc" )
fi
python_versions=( "${python_versions[@]%/}" )

debian_versions=( "buster" "bullseye" "sid" )

pipVersion="$(curl -fsSL 'https://pypi.org/pypi/pip/json' | jq -r .info.version)"
getPipCommit="$(curl -fsSL 'https://github.com/pypa/get-pip/commits/master/get-pip.py.atom' | tac|tac | awk -F '[[:space:]]*[<>/]+' '$2 == "id" && $3 ~ /Commit/ { print $4; exit }')"
getPipUrl="https://github.com/pypa/get-pip/raw/$getPipCommit/get-pip.py"
getPipSha256="$(curl -fsSL "$getPipUrl" | sha256sum | cut -d' ' -f1)"

generated_warning() {
	cat <<-EOH
		#
		# NOTE: THIS DOCKERFILE IS GENERATED VIA "update.sh"
		#
		# PLEASE DO NOT EDIT IT DIRECTLY.
		#
	EOH
}

is_good_version() {
	local dir="$1"; shift
	local dirVersion="$1"; shift
	local fullVersion="$1"; shift

	if ! wget -q -O /dev/null -o /dev/null --spider "https://www.python.org/ftp/python/$dirVersion/Python-$fullVersion.tar.xz"; then
		return 1
	fi

	if [ -d "$dir/windows" ] && ! wget -q -O /dev/null -o /dev/null --spider "https://www.python.org/ftp/python/$dirVersion/python-$fullVersion-amd64.exe"; then
		return 1
	fi

	return 0
}

for version in "${python_versions[@]}"; do
	rcVersion="${version%-rc}"
	rcGrepV='-v'
	if [ "$rcVersion" != "$version" ]; then
		rcGrepV=
	fi
	possibles=( $(
		{
			git ls-remote --tags https://github.com/python/cpython.git "refs/tags/v${rcVersion}.*" \
				| sed -r 's!^.*refs/tags/v([0-9a-z.]+).*$!\1!' \
				| grep $rcGrepV -E -- '[a-zA-Z]+' \
				|| :
			# this page has a very aggressive varnish cache in front of it, which is why we also scrape tags from GitHub
			curl -fsSL 'https://www.python.org/ftp/python/' \
				| grep '<a href="'"$rcVersion." \
				| sed -r 's!.*<a href="([^"/]+)/?".*!\1!' \
				| grep $rcGrepV -E -- '[a-zA-Z]+' \
				|| :
		} | sort -ruV
	) )
	fullVersion=
	declare -A impossible=()
	for possible in "${possibles[@]}"; do
		rcPossible="${possible%%[a-z]*}"
		# varnish is great until it isn't (usually the directory listing we scrape below is updated/uncached significantly later than the release being available)
		if is_good_version "$version" "$rcPossible" "$possible"; then
			fullVersion="$possible"
			break
		fi

		if [ -n "${impossible[$rcPossible]:-}" ]; then
			continue
		fi
		impossible[$rcPossible]=1
		possibleVersions=( $(
			wget -qO- -o /dev/null "https://www.python.org/ftp/python/$rcPossible/" \
				| grep '<a href="Python-'"$rcVersion"'.*\.tar\.xz"' \
				| sed -r 's!.*<a href="Python-([^"/]+)\.tar\.xz".*!\1!' \
				| grep $rcGrepV -E -- '[a-zA-Z]+' \
				| sort -rV \
				|| true
		) )
		for possibleVersion in "${possibleVersions[@]}"; do
			if is_good_version "$version" "$rcPossible" "$possibleVersion"; then
				fullVersion="$possibleVersion"
				break
			fi
		done
	done

	if [ -z "$fullVersion" ]; then
		{
			echo
			echo
			echo "  error: cannot find $version (alpha/beta/rc?)"
			echo
			echo
		} >&2
		exit 1
	fi

	echo "$version: $fullVersion"

	for v in \
		{slim,distroless} \
	; do
        echo "  ${v}"
        for debian_version in "${debian_versions[@]}"; do
		    dir="${v}/${version}/${debian_version}"
		    variant="$(basename "$v")"

            mkdir -p "${dir}"
            echo "    ${debian_version}"

            case "${variant}" in
			    slim) tag="${debian_version}-slim" ;;
                distroless) tag="${version}-slim-${debian_version}";;
		    esac

            readarray -d '' templates < <(find ${v}/Dockerfile*.template -print0)

            for template in "${templates[@]}"; do
                echo "      template: ${template}"

                dockerfile="${dir}/Dockerfile"

                if [[ $template =~ Dockerfile\-(.*)\.template ]]; then   
                    dockerfile="${dir}/Dockerfile-${BASH_REMATCH[1]}";
                fi

                echo "      dockerfile: ${dockerfile}"

		        { generated_warning; cat "$template"; } > "${dockerfile}"

		        sed -ri \
                    -e 's/^(ARG GPG_KEY=")%%PLACEHOLDER%%/\1'"${gpgKeys[$version]:-${gpgKeys[$rcVersion]}}"'/' \
			        -e 's/^(ENV PYTHON_VERSION=")%%PLACEHOLDER%%/\1'"$fullVersion"'/' \
			        -e 's/^(ENV PYTHON_RELEASE=")%%PLACEHOLDER%%/\1'"${fullVersion%%[a-z]*}"'/' \
			        -e 's/^(ENV PYTHON_PIP_VERSION=")%%PLACEHOLDER%%/\1'"$pipVersion"'/' \
			        -e 's!^(ARG PYTHON_GET_PIP_URL=")%%PLACEHOLDER%%!\1'"$getPipUrl"'!' \
			        -e 's!^(ARG PYTHON_GET_PIP_SHA256=")%%PLACEHOLDER%%!\1'"$getPipSha256"'!' \
			        -e 's/^(FROM python):%%PLACEHOLDER%%/\1:'"$version-$tag"'/' \
			        -e 's!^(FROM (docker.io/library/debian|docker.io/westonsteimel/python)):%%PLACEHOLDER%%!\1:'"$tag"'!' \
			        "${dockerfile}"

                major="${rcVersion%%.*}"
		        minor="${rcVersion#$major.}"
		        minor="${minor%%.*}"

		        if [ "$minor" -ge 8 ]; then
			        # PROFILE_TASK has a reasonable default starting in 3.8+; see:
			        #   https://bugs.python.org/issue36044
			        #   https://github.com/python/cpython/pull/14702
			        #   https://github.com/python/cpython/pull/14910
			        perl -0 -i -p -e "s![^\n]+PROFILE_TASK(='[^']+?')?[^\n]+\n!!gs" "${dockerfile}"
		        fi
		        if [ "$minor" -ge 9 ]; then
			        # "wininst-*.exe" is not installed for Unix platforms on Python 3.9+: https://github.com/python/cpython/pull/14511
			        sed -ri -e '/wininst/d' "${dockerfile}"
		        fi

		        # https://www.python.org/dev/peps/pep-0615/
		        # https://mail.python.org/archives/list/python-dev@python.org/thread/PYXET7BHSETUJHSLFREM5TDZZXDTDTLY/
		        if [ "$minor" -lt 9 ]; then
			        sed -ri -e '/tzdata/d' "${dockerfile}"
		        fi

                if test -f "${v}/prepare-rootfs-${debian_version}.sh"; then
                    cp "${v}/prepare-rootfs-${debian_version}.sh" "${dir}/prepare-rootfs.sh"
                fi
            done
        done
	done
done
