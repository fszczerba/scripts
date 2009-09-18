#! /bin/bash
#
# iPhone packaging script
#
# Version 1.0
# May 24, 2009
#
# Copyright 2009, Frank Szczerba <frank@szczerba.net>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#    * Redistributions of source code must retain the above copyright notice,
#      this list of conditions and the following disclaimer.
#    * Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in the
#      documentation and/or other materials provided with the distribution.
#    * Neither the name of the copyright holder nor the names of any
#      contributors may be used to endorse or promote products derived from
#      this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#

#
# Helper functions
#
die() {
	echo "$*" >&2
	exit 1
}

usage() {
	if [ -n "$1" ] ; then
		echo "$@" >&2
		printf "\n"
	fi
	echo "usage: build [-n] [config...]" >&2
	echo "    -n : do not update build number or commit to git" >&2
	if [ -n "$xcodeconfigs" ] ; then
		printf "\n    Known configs:" >&2
		printf " %s" $xcodeconfigs >&2
		printf "\n\nDefault action is to build all configs\n" >&2
	else
		echo "This does not appear to be a valid project directory!" >&2
	fi
	exit 3
}

#
# Default options
#
nocommit=0
configs=

# all known configurations
xcodeconfigs=$(xcodebuild -list | sed '
		/Build Configurations:/,/^[[:space:]]*$/	!d
		/Build Configurations/				d
		/^[[:space:]]*$/				d
		s/[[:space:]]*\([^[:space:]]*\).*/\1/
	')

if [ -z "$xcodeconfigs" ] ; then
	# no project bundle?
	usage;
fi

#
# Parse command line options
#
while [ -n "$*" ]; do
	case "$1" in
		-n) nocommit=1 ; shift ;;
		-*) usage ;;
		*)	if echo $xcodeconfigs | grep -wq "$1" ; then
				configs="$configs $1"; shift 
			else
				usage "Invalid config '$1'"
			fi
			;;
	esac
done

# default to building all configs
if [ -z "$configs" ] ; then
	configs=$xcodeconfigs
fi

# check for modified files, bail if found
if ! git status | grep -q 'nothing to commit (working directory clean)' ; then
	if [ "$nocommit" -eq "0" ] ; then
		# if committing the directory must be clean at first
		git status
		die "directory is dirty"
	else
		# development build, just remember that it was dirty
		isdirty=1
	fi
else
	isdirty=0
fi


if [ "$nocommit" -eq "0" ] ; then
	# read out the marketing version
	# do this separate from the cut so we can check the exit code
	mvers=$(agvtool mvers -terse)
	if [ $? -ne 0 -o -z "$mvers" ] ; then
		die "No marketing version found"
	fi

	if echo "$mvers" | grep -q = ; then
		mvers=$(echo "$mvers" | cut -f 2 -d =)
	fi

	# going to commit, bump the version number
	agvtool bump -all

	bvers=$(agvtool vers -terse)
	if [ $? -ne 0 -o -z "$bvers" ] ; then
		die "No build version found"
	fi

	# read out the build version, must exist if the marketing version does
	fullvers="$mvers build $bvers"
	tag=$(echo "$fullvers" | tr ' ' _)

	# commit the changed version and tag it
	echo "Committing "$fullvers" with tag $tag"
	git ci -a -m "Set build version '$fullvers'" -n || die 'commit failed'
	git tag "$tag" -m "$fullvers"
else
	# not committing, use the SHA1 as the version
	fullvers=$(git rev-parse HEAD 2>/dev/null)

	# if it's dirty, append the date, time, and timezone
	if [ "$isdirty" -ne 0 ] ; then
		fullvers="$fullvers+ $(date +%F\ %T\ %Z)"
	fi
fi

# clean up old builds so that everything is built from scratch
rm -rf build
rm -rf Payload
all=

# build and package each requested config
for config in $configs ; do
	xcodebuild -alltargets -parallelizeTargets -configuration $config build || die "Build failed"

	# packaged output goes in Releases if tagged, Development otherwise
	if [ "$nocommit" -eq "0" ] ; then
		basedir=Releases
	else
		basedir=Development
	fi
	releasedir=$basedir/$config/"$fullvers"
	mkdir -p "$releasedir"

	# Package each app
	for app in build/$config-iphoneos/*.app ; do
		basename="$(basename "$app" .app)"

		mkdir -p Payload/Payload
		cp -Rp "$app" Payload/Payload

		# Get app-specific iTunes artwork or project-specific artwork
		# if available
		if [ -f "$basename".iTunesArtwork ] ; then
			cp -f "$basename".iTunesArtwork Payload/iTunesArtwork
		elif [ -f iTunesArtwork ] ; then
			cp -f iTunesArtwork Payload/iTunesArtwork
		fi

		# Distribution builds have a .zip extension, development
		# builds have a .ipa extension
		if [ "$config" -eq "Distribute" ] ; then
			ext=zip
		else
			ext=ipa
		fi

		# zip the Payload directory then delete it
		output="$releasedir/$basename.$ext"
		ditto -c -k Payload "$output" || die "Failed to compress"
		rm -rf Payload

		# add to the list of output files
		all="${all:+$(printf "%s\n" "$all")}$(printf "\t%s" "$output")"

		# save debug symbols (if available) with the app
		if [ -d "$app.dSYM" ] ; then
			output="$releasedir/$basename.dSYM.zip"
			ditto -c -k "$app.dSYM" "$output" || die "Failed to compress debug info"
			all="$(printf "%s\n" "$all")$(printf "\t%s" "$output")"
		fi
		# update a symlink to the latest version
		(cd $basedir/$config ; ln -sf "$fullvers/$basename.$ext")
	done
done

# report the generated files
printf "Created: $all\n"
