
toml = require "toml"

ui = require "pkgxx.ui"
fs = require "pkgxx.fs"
macro = require "pkgxx.macro"
sources = require "pkgxx.sources"

Atom = require "pkgxx.atom"
Split = require "pkgxx.split"

macroList = =>
	l = {
		pkg: @\packagingDirectory!
	}

	for name in *@context.__class.prefixes
		l[name] = @context\getPrefix name

	-- We should remove those. They may generate clashes with the collections’
	-- prefixes generated by Context\getPrefix.
	for name, value in pairs @context.configuration
		l[name] = value

	l

swapKeys = (tree, oldKey, newKey) ->
	tree[oldKey], tree[newKey] = tree[newKey], tree[oldKey]

	for key, value in pairs tree
		if (type value) == "table"
			tree[key] = swapKeys value, oldKey, newKey

	tree

has = (e, t) ->
	for i in *t
		if e == i
			return true

class
	new: (filename, context) =>
		@context = context
		@filename = filename

		file, reason = io.open filename, "r"

		unless file
			error reason, 0

		recipe, e = toml.parse (file\read "*all"), {strict: false}

		swapKeys recipe, "build-dependencies", "buildDependencies"

		file\close!

		recipe = macro.parse recipe, macroList @

		@name = recipe.name
		@version = recipe.version
		@release = recipe.release

		@packager = recipe.packager
		@maintainer = recipe.maintainer or @packager
		@url = recipe.url

		@release = @release or 1

		@watch = recipe.watch
		if @watch
			@watch.url = @watch.url or @url

			unless @watch.selector or @watch.lasttar or @watch.execute
				ui.warning "No selector in [watch]. Removing watch."
				@watch = nil

		@dirname = recipe.dirname
		unless @dirname
			if @version
				@dirname = "#{@name}-#{@version}"
			else
				@dirname = recipe.name

		@architecture = @context.architecture
		@sources = sources.parseAll recipe

		bs = recipe["build-system"]
		@buildInstructions =
			configure: recipe.configure or bs,
			build: recipe.build or bs,
			install: recipe.install or bs
		@buildDependencies = {}
		for string in *(recipe.buildDependencies or {})
			table.insert @buildDependencies, Atom string

		if not @watch
			for name, module in pairs context.modules
				if module.watch
					with watch = module.watch @
						if watch
							-- FIXME: Maybe we could do some additionnal checks.
							@watch = watch

		@recipe = recipe -- Can be required for module-defined fields.
		@recipeAttributes = lfs.attributes filename

		-- FIXME: sort by name or something.
		@splits = @\parseSplits recipe

		@\applyDistributionRules recipe

		-- Importing splits’ dependencies in the build-deps.
		for split in *@splits
			for atom in *split.dependencies
				if not has atom, @buildDependencies
					@buildDependencies[#@buildDependencies+1] = atom

		-- FIXME: Broken since Atom exist.
		for package in *@splits
			if @context.collection
				package.name = @context.collection ..
					"-" .. package.name

				for list in *{
					"conflicts",
					"dependencies",
					"buildDependencies",
					"provides",
					"groups",
					"options",
				}
					for index, name in pairs package[list]
						package[list][index] = @context.collection ..
							"-" .. name

		@\setTargets!

		@\checkRecipe!

	parse: (string) =>
		parsed = true
		while parsed
			string, parsed = macro.parseString string, (macroList @), @

		string

	-- Is meant to be usable after package manager or architecture
	-- changes, avoiding the creation of a new context.
	setTargets: =>
		module = @context.modules[@context.packageManager]

		unless module and module.package
			ui.error "Could not set targets. Wrong package manager module?"
			return nil

		for split in *@splits
			split.target = module.package.target split

		@target = @splits[1].target

	getTargets: =>
		i = 1

		return ->
			i = i + 1

			if i - 1 <= #@splits
				return @splits[i - 1].target

	getLogFile: =>
		"#{@context.packagesDirectory}/#{@name}-#{@version}-#{@release}.log"

	parseSplits: (recipe) =>
		splits = {}

		splits[1] = Split
			origin: @

		splits[1]\applyDiff recipe

		if recipe.splits
			for splitName, data in pairs recipe.splits
				-- Splits will need much more data than this.
				-- FIXME: Split!? Target!?
				split = Split
					name: splitName
					origin: @
					os: data.os
					files: data.files

				split\applyDiff data

				split.class = split.class or @@.guessClass split

				splits[#splits+1] = split

		splits

	applyDistributionRules: (recipe) =>
		distribution = @context.configuration.distribution
		module = @context.modules[distribution]

		if recipe.os and recipe.os[distribution]
			@splits[1]\applyDiff recipe.os[distribution]

		for split in *@splits
			os = split.os

			if os and os[distribution]
				split\applyDiff os[distribution]

		if module
			ui.debug "Distribution: #{module.name}"

			if module.autosplits
				oldIndex = #@splits

				ui.debug "Trying module '#{module.name}'."
				newSplits = module.autosplits @
				newSplits = macro.parse newSplits, macroList @

				for split in *@\parseSplits splits: newSplits
					ui.debug "Registering automatic split: #{split.name}."

					if not @\hasSplit split.name
						split.automatic = true
						@splits[#@splits+1] = split
					else
						ui.debug " ... split already exists."
		else
			ui.warning "No module found for this distribution: " ..
				"'#{distribution}'."
			ui.warning "Your package is unlikely to comply to " ..
				"your OS’ packaging guidelines."

	guessClass: (split) ->
		if split.name\match "-doc$"
			"documentation"
		elseif split.name\match "-dev$" or split.name\match "-devel$"
			"headers"
		elseif split.name\match "^lib"
			"library"
		else
			"binary"

	checkRecipe: =>
		module = @context.modules[@context.packageManager]
		if module and module.check
			r, e = module.check @

			if e and not r
				error e, 0

	hasSplit: (name) =>
		for split in *@splits
			if split.name == name
				return true

	postBuildHooks: =>
		for module in *@context.modules
			if module.postBuild
				fs.directory @\packagingDirectory!, ->
					module.postBuild @

	buildingDirectory: =>
		"#{@context.buildingDirectory}/src/" ..
			"#{@name}-#{@version}-#{@release}"

	packagingDirectory: (name) =>
		unless name
			name = "_"

		"#{@context.buildingDirectory}/pkg/#{name}"

	buildNeeded: =>
		for self in *self.splits
			if self.automatic
				continue

			attributes = lfs.attributes "" ..
				"#{@context.packagesDirectory}/#{@target}"
			unless attributes
				return true

			if attributes.modification < @recipeAttributes.modification
				ui.info "Recipe is newer than packages."
				return true

	checkDependencies: =>
		module = @context.modules[@context.packageManager]

		unless module and module.isInstalled
			-- FIXME: Make this a real warning once it’s implemented.
			return nil, "unable to check dependencies"

		ui.info "Checking dependencies…"

		deps = {}
		for atom in *@buildDependencies
			table.insert deps, atom

		for atom in *deps
			if not module.isInstalled atom.name
				-- FIXME: Check the configuration to make sure it’s tolerated.
				--        If it isn’t, at least ask interactively.
				ui.detail "Installing missing dependency: #{atom.name}"
				@\installDependency atom.name

	installDependency: (name) =>
		module = @context.modules[@context.dependenciesManager]
		if not (module and module.installDependency)
			module = @context.modules[@context.packageManager]

		if not (module and module.installDependency)
			return nil, "no way to install packages"

		module.installDependency name

	download: =>
		ui.info "Downloading…"

		for source in *@sources
			if (sources.download source, @context) ~= true
				return

		true

	updateVersion: =>
		local v

		for source in *@sources
			module = @context.modules[source.protocol]

			unless module
				continue

			if module.getVersion
				fs.changeDirectory @context.sourcesDirectory, ->
					success, version = pcall ->
						module.getVersion source

					if success and not @version
						@version = version

		@\setTargets!

	prepareBuild: =>
		fs.mkdir @\buildingDirectory!
		fs.mkdir @\packagingDirectory!

		for split in *@splits
			fs.mkdir @\packagingDirectory split.name

	extract: =>
		ui.info "Extracting…"

		fs.changeDirectory @\buildingDirectory!, ->
			for source in *@sources
				if source.filename\match "%.tar%.[a-z]*$"
					ui.detail "Extracting '#{source.filename}'."
					os.execute "tar xf " ..
						"'#{@context.sourcesDirectory}/" ..
						"#{source.filename}'"
				else
					ui.detail "Copying '#{source.filename}'."
					-- FIXME: -r was needed for repositories and stuff.
					--        We need to modularize “extractions”.
					os.execute "cp -r " ..
						"'#{@context.sourcesDirectory}/" ..
						"#{source.filename}' ./"

	-- @param name The name of the “recipe function” to execute.
	execute: (name, critical) =>
		ui.debug "Executing '#{name}'."

		if (type @buildInstructions[name]) == "table"
			code = table.concat @buildInstructions[name], "\n"

			code = "set -x -e\n#{code}"

			if @context.configuration.verbosity < 5
				logfile = @\getLogFile!

				lf = io.open logfile, "w"
				if lf
					lf\close!

				code = "(#{code}) 2>> #{logfile} >> #{logfile}"

			fs.changeDirectory @\buildingDirectory!, ->
				return os.execute code
		else
			@\executeModule name, critical

	executeModule: (name, critical) =>
		if (type @buildInstructions[name]) == "string"
			module = @context.modules[@buildInstructions[name]]

			return fs.changeDirectory @\buildingDirectory!, ->
				module[name] @
		else
			testName = "can#{(name\sub 1, 1)\upper!}#{name\sub 2, #name}"

			for _, module in pairs @context.modules
				if module[name]
					local finished

					r, e = fs.changeDirectory @\buildingDirectory!, ->
						if module[testName] @
							finished = true

							return module[name] @

					if finished
						return r, e

		return nil, "no suitable module found"

	build: =>
		@\prepareBuild!

		@\extract!

		ui.info "Building…"

		success, e = @\execute "configure"
		if not success
			ui.error "Build failure. Could not configure."
			return nil, e

		success, e = @\execute "build", true
		if not success
			ui.error "Build failure. Could not build."
			return nil, e

		success, e = @\execute "install"
		if not success
			ui.error "Build failure. Could not install."
			return nil, e

		ui.info "Doing post-build verifications."
		@\postBuildHooks!

		true

	split: =>
		mainPkgDir = @\packagingDirectory!

		for split in *@splits
			if split.files
				if split.automatic and not split\hasFiles!
					ui.debug "No file detected for #{split.name}. Ignoring."
					continue

				split\moveFiles!

		-- FIXME: A bit hacky. We need packaging directories and fake roots
		--        to be different.
		fs.remove @\packagingDirectory @splits[1].name
		os.execute "mv '#{@\packagingDirectory!}' " ..
			"'#{@\packagingDirectory @splits[1].name}'"

	package: =>
		ui.info "Packaging…"
		@\split!

		module = @context.modules[@context.packageManager]

		if module.package
			for split in *@splits
				split\package module
		else
			-- Should NOT happen.
			error "No module is available for the package manager "..
				"'#{@configuration['package-manager']}'."

	clean: =>
		ui.info "Cleaning…"
		ui.detail "Removing '#{@\buildingDirectory!}'."

		-- Sort of necessary, considering the directories and files are
		-- root-owned. And they have to if we want our packages to be valid.
		os.execute "sudo rm -rf '#{@\buildingDirectory!}'"

	lint: =>
		e = 0

		unless @name
			ui.error "no 'name' field"
			e = e + 1
		unless @sources
			ui.error "no 'sources' field"
			e = e + 1

		unless @version
			isVersionable = false

			for source in *@sources
				m = @context.modules[source.protocol]

				if m and m.getVersion
					isVersionable = true

					break

			unless isVersionable
				ui.error "no 'version' field"
				e = e + 1

		unless @url
			ui.warning "no 'url' field"
			e = e + 1

		unless @packager
			ui.warning "no 'packager' field"
			e = e + 1

		unless @watch
			ui.warning "no 'watch' section"
		else
			with @watch
				unless .selector or .lasttar or .execute
					ui.warning "unusable 'watch', needs a selector, " ..
						"lasttar or execute field"

		for split in *@splits
			with self = split
				ui.detail @name
				unless @summary
					ui.warning "no 'summary' field"
					e = e + 1
				unless @description
					ui.warning "no 'description' field"
					e = e + 1

				unless @options
					ui.warning "no 'options' field"
					e = e + 1

				unless @dependencies
					ui.warning "no 'dependencies' field"
					e = e + 1

		e

	isUpToDate: =>
		if @watch
			local p
			-- FIXME: We need to abstract those curl calls.
			-- FIXME: sort -n is a GNU extension.
			-- FIXME: hx* come from the html-xml-utils from the w3c. That’s
			--        an unusual external dependency we’d better get rid of.
			--        We could switch to https://github.com/msva/lua-htmlparser,
			--        but there could be issues with Lua 5.1. More testing needed.
			if @watch.selector
				ui.debug "Using the “selector” method."
				p = io.popen "curl -sL '#{@watch.url}' | hxnormalize -x " ..
					"| hxselect '#{@watch.selector}' -c"
			elseif @watch.lasttar
				ui.debug "Using the “lasttar” method."
				p = io.popen "curl -sL '#{@watch.url}' | hxnormalize -x " ..
					"| hxselect -c 'a' -s '\n' " ..
					"| grep '#{@watch.lasttar}' " ..
					"| sed 's&#{@watch.lasttar}&&;s&\\.tar\\..*$&&' | sort -rn"
			elseif @watch.execute
				ui.debug "Executing custom script."
				p = io.popen @watch.execute

			version = p\read "*line"
			success, _, r = p\close!

			-- 5.1 compatibility sucks.
			unless (r and r == 0 or success) and version
				return nil, nil, "could not check", "child process failed"

			if version
				version = version\gsub "^%s*", ""
				version = version\gsub "%s*$", ""

			if @watch.subs
				for pair in *@watch.subs
					unless (type pair) == "table" and #pair == 2
						ui.warning "Invalid substitution. Substitution is not a pair."
						continue

					unless (type pair[1] == "string") and (type pair[2] == "string")
						ui.warning "Invalid substitution. Substitution is not a pair of strings."

						continue

					version = version\gsub pair[1], pair[2]

			return version == @version, version

	depTree: =>
		isInstalled = -> false
		with module = @context.modules[@context.packageManager]
			if module and module.isInstalled
				isInstalled = module.isInstalled
			else
				ui.warning "Unable to determine installed dependencies."

		deps = {@}

		depInTree = (name) ->
			for element in *deps
				if element.name == name
					return true

		depFinder = =>
			dependencies = {}

			for atom in *@buildDependencies
				dependencies[#dependencies+1] = atom

			for atom in *dependencies
				foundOne = false

				-- FIXME: Check if it’s in the distribution’s package manager
				--        if stuff fails.
				for repository in *@context.repositories
					success, r = pcall ->
						@context\openRecipe "#{repository}/#{atom.origin}/package.toml"

					if success
						unless depInTree atom
							ui.debug "Dependency: #{repository}, #{atom}"
							foundOne = true
							deps[#deps+1] = r

							depFinder r

							break

				unless foundOne
					foundOne = isInstalled atom.name

					if foundOne
						ui.debug "Dependency: <installed>, #{atom}"

				unless foundOne
					ui.warning "Dependency not found: '#{atom.name}'."

		depFinder @

		return deps

	__tostring: =>
		if @version
			"<pkgxx:Recipe: #{@name}-#{@version}-#{@release}>"
		else
			"<pkgxx:Recipe: #{@name}-[devel]-#{@release}>"

