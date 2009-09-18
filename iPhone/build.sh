#! /bin/bash
#
# iPhone packaging script
#
# ============================================================================
# Version 1.1
# July 14, 2009
#
# - support shared source repositories
# - build all targets in the project correctly
# - leave iTunes Artwork beside distribution bundles, not inside
# - better handling for targets with spaces in their names
#
# ------------
#
# Version 1.0
# May 24, 2009
# 
# ============================================================================
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
	echo "    -n : do not update build number or commit to git/svn" >&2
	if [ -n "$xcodeconfigs" ] ; then
		printf "\n    Known configs:" >&2
		printf " %s" $xcodeconfigs >&2
		printf "\n\nDefault action is to build all configs\n" >&2
	else
		echo "This does not appear to be a valid project directory!" >&2
	fi
	exit 3
}

svn_status() {
	svn status
}

svn_dirtycheck() {
	(cd "$1"; svn status) | egrep -qv '^X|Performing status|^$'
}

svn_commit() {
	svn commit -m "$1"
}

svn_tag() {
	echo "Tagging not supported for SVN"
}

svn_fullvers() {
	svn info | grep Revision | awk '{print "SVN"$2}'
}

git_status() {
	git status
}

git_dirtycheck() {
	! (cd "$1" ; git status) | grep -q 'nothing to commit (working directory clean)'
}

git_commit() {
	
	git ci -a -n -m "$1"
	
}

git_tag() {
	git tag "$1" -m "$2"
}

git_fullvers() {
	git rev-parse HEAD 2>/dev/null
}

if [ -d '.svn' ]; then
	VCPREFIX=svn
else
	VCPREFIX=git
fi

#
# Default options
#
project="$(basename $(pwd))"
nocommit=0
configs=
buildbase=build

# source repos shared across multiple projects, these must be clean and get
# tagged with everything else
sharedsources=

# all known configurations
xcodeconfigs=$(xcodebuild -list | sed '
		/Build Configurations:/,/^[[:space:]]*$/	!d
		/Build Configurations/				d
		/^[[:space:]]*$/				d
		s/[[:space:]]*\([^[:space:]].*\).*/\1/
		s/[[:space:]][(]Active[)]$//
	'| perl -e '$a="";while(<>){$a.=$_;} $a=~s/\n/:/mg; print $a;')

xcodetargets="$(xcodebuild -list | sed '
		/Targets:/,/^[[:space:]]*$/			!d
		/Targets/					d
		/^[[:space:]]*$/				d
		s/^[[:space:]]*//
		s/(.*)//
		s/[[:space:]]*$//
	')"

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
				if [ -z "$configs" ]; then
					configs="$1"
				else
					configs="${configs}:$1";
				fi
				shift 
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

echo "$configs"

# check for modified files, bail if found
isdirty=0

for d in . $sharedsources ; do
	if ${VCPREFIX}_dirtycheck ; then
		if [ "$nocommit" -eq "0" ] ; then
			# if committing the directory must be clean at first
			${VCPREFIX}_status
			die "directory \"$d\" is dirty"
		else
			# development build, just remember that it was dirty
			isdirty=1
		fi
	fi
done

if [ "$nocommit" -eq "0" ] ; then
	# read out the marketing version
	# do this separate from the cut so we can check the exit code
	mvers=$(agvtool mvers -terse | head -1)
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
	${VCPREFIX}_commit "Set build version '$fullvers'" || die 'commit failed'
	${VCPREFIX}_tag "$tag" "$fullvers"
	libtag=$(echo "$project-$tag" | tr ' ' _)
	for d in $sharedsources ; do
		(cd $d ; {VCPREFIX}_tag $libtag "$project $tag")
	done
else
	# not committing, use the SHA1 as the version
	TAGFUNCTION="${VCPREFIX}_fullvers"
	fullvers=`$TAGFUNCTION`
	
	# if it's dirty, append the date, time, and timezone
	if [ "$isdirty" -ne 0 ] ; then
		fullvers="$fullvers+ $(date +%F\ %T\ %Z)"
	fi
fi

# clean up old builds 
rm -rf Payload
logname=$(mktemp /tmp/build.temp.XXXXXX)
printf "Created:" > $logname

# build and package each requested config
SAVEIFS=$IFS
IFS=$':'
for config in $configs ; do
	config=`echo $config | sed 's/^[[:space:]]//'`
	
	echo "CONFIG=$config"

	# packaged output goes in Releases if tagged, Development otherwise
	if [ "$nocommit" -eq "0" ] ; then
		basedir=Releases
	else
		basedir=Development
	fi
	releasedir="$basedir/$config/$fullvers"
	mkdir -p "$releasedir"

	(xcodebuild -alltargets -parallelizeTargets -configuration "$config" clean build | tee "$basedir/xcodebuild.log") || die "Build failed"

	# Package each app
	echo "$xcodetargets" | while read basename ; do
		app="$buildbase/$config-iphoneos/$basename.app"

		mkdir -p Payload/Payload
		cp -Rp "$app" Payload/Payload

		# Get app-specific iTunes artwork or project-specific artwork
		# if available
		if [ -f "$basename".iTunesArtwork ] ; then
			artwork="$basename".iTunesArtwork
		elif [ -f iTunesArtwork ] ; then
			artwork=iTunesArtwork
		else
			artwork=
		fi

		# Distribution builds have a .zip extension, development
		# builds have a .ipa extension
		if [ "$config" = "Distribute" -o "$config" = "Distribution" ] ; then
			output="$releasedir/$basename.iTunesArtwork" 
			cp -f "$artwork" "$output"
			printf "\t$output\n" >> $logname
			ext=zip
		else
			[ -n "$artwork" ] && cp -f "$artwork" Payload/iTunesArtwork
			ext=ipa
		fi

		# zip the Payload directory then delete it
		output="$releasedir/$basename.$ext"
		ditto -c -k Payload "$output" || die "Failed to compress"
		rm -rf Payload

		# add to the list of output files
		printf "\t$output\n" >> $logname

		# save debug symbols (if available) with the app
		if [ -d "$app.dSYM" ] ; then
			output="$releasedir/$basename.dSYM.zip"
			ditto -c -k "$app.dSYM" "$output" || die "Failed to compress debug info"
			printf "\t$output\n" >> $logname
		fi
		# update a symlink to the latest version
		(cd "$basedir/$config" ; ln -sf "$fullvers/$basename.$ext")
		
		# Identify the provisioning profile used for this app
		provisioning_file=`cat $basedir/xcodebuild.log | grep ProcessProductPackaging | grep "Provisioning Profiles" | grep "$basename.app" | sed 's/^.*\/\([A-F0-9-]\{36\}\).*/\1/'`
		cp "$HOME/Library/MobileDevice/Provisioning Profiles/${provisioning_file}.mobileprovision" "$releasedir/${provisioning_file}.mobileprovision"
		
		#update a symlink to the latest provisioning profile
		(cd "$basedir/$config" ; ln -sf "$fullvers/${provisioning_file}.mobileprovision")
		
	done
	
	rm "$basedir/xcodebuild.log"
	
done
IFS=$SAVEIFS

# report the generated files
printf "\n" >> $logname
cat $logname
rm $logname
