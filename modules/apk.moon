
ui = require "pkgxx.ui"
fs = require "pkgxx.fs"

getSize = ->
	-- -sb would have been preferable on Arch, but that ain’t
	-- supported on all distributions using pacman derivatives!
	p = io.popen "du -sk ."
	size = (p\read "*line")\gsub " .*", ""
	size = size\gsub "%s.*", ""
	size = (tonumber size) * 1024
	p\close!

	size

makeRepository = =>
	@context\info "Building 'apk' repository."

	index = "#{@context.packagesDirectory}/#{@context.architecture}/APKINDEX.tar.gz"

	local oldIndex
	if lfs.attributes index
		oldIndex = " --index #{index}"
	else
		oldIndex = ""

	output = " --output '#{index}.unsigned'"

	r, e = os.execute "apk index --quiet #{oldIndex} #{output}" ..
		" --description '#{@context.repositoryDescription or "pkgxx-generated repository"}'" ..
		" --rewrite-arch '#{@context.architecture}'" ..
		" #{@context.packagesDirectory}/#{@context.architecture}/*.apk"

	unless r
		return nil, e

	r, e = os.execute "abuild-sign -q '#{index}.unsigned'"

	unless r
		return nil, e

	os.execute "mv '#{index}.unsigned' '#{index}'"

{
	check: =>
		unless os.execute "abuild-sign --installed"
			@context\error "You need to generate a key with " ..
				"'abuild-keygen -a'."
			@context\error "No APK package can be built without " ..
				"being signed."

			return nil, "no abuild key"

	package:
		target: =>
			-- We need to store the packages in a sub-directory to be able
			-- to build valid apk repositories.
			"#{@context.architecture}/" ..
				"#{@name}-#{@version}-r#{@release - 1}.apk"
		build: =>
			unless @context.builder
				@context\warning "No 'builder' was defined in your configuration!"

			unless fs.attributes "#{@context.packagesDirectory}/#{@context.architecture}"
				fs.mkdir "#{@context.packagesDirectory}/#{@context.architecture}"

			size = getSize!

			@context.modules.pacman._genPkginfo @, size

			@context\detail "Building '#{@target}'."
			fs.mkdir @context.packagesDirectory .. "/" ..
				@context.architecture
			fs.execute @, [[
				tar --xattrs -c * | abuild-tar --hash | \
					gzip -9 > ../data.tar.gz

				mv .PKGINFO ../

				# append the hash for data.tar.gz
				sha256=$(sha256sum ../data.tar.gz | cut -f1 -d' ')
				echo "datahash = $sha256" >> ../.PKGINFO

				# control.tar.gz
				cd ..
				tar -c .PKGINFO | abuild-tar --cut \
					| gzip -9 > control.tar.gz
				abuild-sign -q control.tar.gz || exit 1

				# create the final apk
				cat control.tar.gz data.tar.gz > ]] ..
					"'#{@context.packagesDirectory}/#{@target}'"
		install: (name) =>
			fs.execute context: self, "apk add --allow-untrusted '#{name}'"

	addToRepository: (target, opt) =>
		makeRepository target, opt
	makeRepository: => (target, opt) =>
		makeRepository target, opt

	installDependency: (name) =>
		fs.execute context: self, "apk add '#{name}'"

	isInstalled: (name) =>
		fs.execute context: self, "apk info | grep -q '#{name}'"
}


