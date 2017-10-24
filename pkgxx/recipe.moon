
toml = require "toml"

ui = require "pkgxx.ui"
fs = require "pkgxx.fs"
macro = require "pkgxx.macro"

Source = require "pkgxx.source"
Atom = require "pkgxx.atom"
Package = require "pkgxx.package"
Builder = require "pkgxx.builder"

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

---
-- Operations and data on single recipes.
--
-- It is useful to know that a Recipe can generate multiple packages.
--
-- Recipes are created with one default package, that will inherit most of its properties, including its name, version, and so on.
--
-- @see Package
-- @see Context
-- @see Atom
---
class
	---
	-- Recipe constructor, that’s meant to be used privately only.
	--
	-- To create new Recipe objects, use Context\newRecipe.
	--
	-- @param context (Context) pkgxx Context in which to import the recipe.
	-- @see Context.newRecipe
	new: (context) =>
		--- Context in which the Recipe has been created.
		-- @attribute context
		@context = context
		@packages = {
			Package {
				origin: self
			}
		}

		@buildInstructions = {
			Builder {
				name: "configure"
				critical: false
				context: @context
				recipe: self
			}
			Builder {
				name: "build"
				critical: true
				context: @context
				recipe: self
			}
			Builder {
				name: "install"
				critical: true
				context: @context
				recipe: self
			}
		}

	---
	-- Name of the recipe.
	--
	-- @type (string | nil)
	name: nil

	---
	-- Version of the software or content to be packaged.
	--
	-- @type (string | nil)
	version: nil

	---
	-- Version of the recipe itself.
	--
	-- The `release` attribute *should* always be incremented when the recipe is updated.
	--
	-- This attribute *must* have a minimum value of 1 and *must* be an integer.
	--
	-- @type (number)
	release: 1

	---
	-- The person who wrote the recipe.
	--
	-- Should have the following format: `packager name <mail@example>`.
	--
	-- @type (string | nil)
	packager: nil

	---
	-- The person who updates and maintains the recipe.
	--
	-- Recipes imported from `package.toml` files have their maintainer default to `@packager`.
	--
	-- The format of this field is the same as that of `@packager`.
	--
	-- @see packager
	-- @type (string | nil)
	maintainer: nil

	---
	-- Homepage of the packaged project.
	--
	-- @type (string | nil)
	url: nil

	---
	-- List of sources needed to build the recipe and its packages.
	--
	-- Each member of this field *must* be an instance of `Source`.
	--
	-- @see Source
	-- @see addSource
	-- @type (table)
	sources: nil

	---
	-- Instructions to build the software.
	-- 
	-- Contains three fields: `configure`, `build` and `install`, which must all be instances of `Builder`.
	--
	-- @issue Not enough documentation over here~
	--
	-- @type ({configure: Builder, build: Builder, install: Builder})
	-- @see Builder
	buildInstructions: nil

	---
	-- A list of Atoms describing the recipe’s build-time dependencies.
	--
	-- Build-dependencies are shared between all packages described by a recipe.
	--
	-- @see Atom
	-- @type (table)
	buildDependencies: nil

	---
	-- Metadata to check automagically if the recipe is out of date.
	--
	-- @type (table | nil)
	-- @issue There should be a Watch class instead of arbitrary, unchecked tables.
	-- @issue @watch is relatively easy to test… and yet has no test.
	-- @issue A part of it also depends on html-xml-utils or something like that…
	watch: nil

	---
	-- Describes the name of the directory in which the main sources are stored.
	--
	-- This value might be used by modules to configure their build process.
	--
	-- Several default values can be applied during `Recipe\finalize`:
	--
	--   - set to `"#{@name}-#{@version}"` if `@version` exists,
	--   - set to `@name` otherwise.
	--
	-- @type (string | nil)
	dirname: nil

	---
	-- Options with which to build the package.
	--
	-- `.options` is a field of arbitrary strings from which modules can take instructions.
	--
	-- See the various postBuild modules for specific entries to add to the `.options` field.
	--
	-- @type table
	options: nil

	---
	-- Imports a recipe’s data from a package.toml file.
	--
	-- @param filename (string) Filename of the recipe to parse.
	importTOML: (filename) =>
		--- Name of the file from which the recipe has been generated.
		-- @attribute filename
		@filename = filename

		file, reason = io.open filename, "r"

		unless file
			error reason, 0

		recipe, reason = toml.parse (file\read "*all"), {strict: false}

		unless recipe
			error reason, 0

		swapKeys recipe, "build-dependencies", "buildDependencies"

		file\close!

		recipe = macro.parse recipe, macroList @

		@name = recipe.name
		@version = recipe.version
		@release = recipe.release or 1

		@packager = recipe.packager
		@maintainer = recipe.maintainer or @packager
		@url = recipe.url

		@options = recipe.options

		@watch = recipe.watch
		if @watch
			@watch.url = @watch.url or @url

			unless @watch.selector or @watch.lasttar or @watch.execute
				ui.warning "No selector in [watch]. Removing watch."
				@watch = nil

		@dirname = recipe.dirname

		@sources = Source.fromVariable recipe.sources

		do
			bs = recipe["build-system"]
			modules = @context.modules

			instructions = (name) ->
				if modules[recipe[name]]
					modules[recipe[name]]
				elseif modules[bs]
					modules[bs]
				elseif recipe[name]
					recipe[name]

			@buildInstructions[1]\setInstructions instructions "configure"
			@buildInstructions[2]\setInstructions instructions "build"
			@buildInstructions[3]\setInstructions instructions "install"

		@buildDependencies = {}
		for string in *(recipe.buildDependencies or {})
			table.insert @buildDependencies, Atom string

		--- FIXME That field should be removed.
		@recipe = recipe

		-- FIXME: Thas field should be removed.
		@recipeAttributes = fs.attributes filename

		--- Packages described by the recipe.
		-- @attribute packages
		@packages = @\parsePackages recipe or self

		os = package.os
		if os and os[distribution]
			buildDeps = os[distribution].buildDependencies
			if buildDeps
				@buildDependencies = [Atom(str) for str in *buildDeps]

			for package in *@packages
				package\import os[distribution]

		@\finalize!

	---
	-- Adds sources to the Recipe.
	--
	-- If the sources are provided as a URL, they will automatically be converted to a Source.
	-- The arrow notation (url -> filename) is supported if you want or need to name the downloaded file.
	--
	-- @param source (string | Source) URL or Source that describes the sources to add.
	--
	-- @return (true) All clear.
	-- @return (nil, string) Source parsing error or filename collision.
	addSource: (source) =>
		if type(source) == "string"
			source = Source.fromString source

		@sources or= {}

		for s in *@sources
			if s.filename == source.filename
				return nil, "filename already used by another source"

		table.insert @sources, source

		true

	---
	-- Defines a new Package in the recipe.
	--
	-- @param name (string) The `name` attribute of the Package to create.
	-- @return (Package) The newly created Package.
	addPackage: (name) =>
		package = Package {
			origin: self
			:name
		}

		table.insert @packages, package

		package

	---
	-- Finalizes a recipe and makes it ready for use.
	--
	-- All missing or uninitialized attributes will be set to safe values for further operations.
	--
	-- Recipes *must* be finalized before calling @{Recipe\build} or @{Recipe\package}.
	--
	-- @return nil
	finalize: =>
		unless @name
			return nil, "cannot finalize a recipe without @name"

		@release or= 1
		@sources or= {}
		@buildDependencies or= {}

		@dirname or= if @version
			"#{@name}-#{@version}"
		else
			@name

		-- @watch guess.
		-- Is done very long after the possible static definition of watch because modules may need to have access to other values.
		unless @watch
			for _, module in pairs @context.modules
				if module.watch
					with watch = module.watch self
						if watch
							-- FIXME: Maybe we could do some additionnal checks.
							@watch = watch

		@\applyDistributionRules @recipe or self

		-- Importing packages’ dependencies in the build-deps.
		for package in *@packages
			for atom in *package.dependencies
				if not has atom, @buildDependencies
					@buildDependencies[#@buildDependencies+1] = atom

		-- FIXME: Broken since Atom exist.
		for package in *@packages
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

		true

	--- @hidden
	-- FIXME: This should probably be moved to macro, or at least somewhat overhauled.
	parse: (string) =>
		parsed = true
		while parsed
			string, parsed = macro.parseString string, (macroList @), @

		string

	--- @hidden
	-- Used internally.
	--
	-- Is meant to be usable after package manager or architecture
	-- changes, avoiding the creation of a new context.
	setTargets: =>
		--- @fixme Will be removed.
		module = @context.modules[@context.packageManager]

		unless module and module.package
			ui.error "Could not set targets. Wrong package manager module?"
			return nil

		for package in *@packages
			package.target = module.package.target package

		@target = @packages[1].target

	---
	-- Lists the filenames and packages this recipe defines.
	--
	-- @return (function) Iterator over the pairs of filename and Package defined by the Recipe.
	-- @see Package
	getTargets: =>
		--- @fixme Will be removed. Use `ipairs recipe.packages`.
		i = 1

		return ->
			i = i + 1

			if i - 1 <= #@packages
				package = @packages[i - 1]

				return package.target, package

	---
	-- @return (string) Location of the recipe’s log file.
	-- @deprecated
	getLogFile: => @context.logFilePath

	--- @hidden
	-- FIXME: The package.toml specific code should just move somewhere else.
	parsePackages: (recipe) =>
		packages = {}

		packages[1] = Package
			origin: @

		packages[1]\import recipe

		if recipe.splits
			for packageName, data in pairs recipe.splits
				-- Packages will need much more data than this.
				-- FIXME: Package!? Target!?
				package = Package
					name: packageName
					origin: @
					os: data.os
					files: data.files

				package\import data

				package.class = package.class or package\guessClass!

				packages[#packages+1] = package

		packages

	--- @hidden
	-- Hidden until semantics clarification and lots of grooming.
	applyDistributionDiffs: (recipe, distribution) =>
		if recipe.os and recipe.os[distribution]
			@packages[1]\import recipe.os[distribution]

	--- @hidden
	-- Hidden until semantics clarification and lots of grooming.
	applyDistributionRules: (recipe) =>
		distribution = @context.distribution
		module = @context.modules[distribution] or {}

		@\applyDistributionDiffs recipe, distribution

		for package in *@packages
			if module.alterRecipe
				module.alterRecipe package, recipe

		if module
			ui.debug "Distribution: #{module.name}"

			if module.autosplits
				ui.debug "Trying module '#{module.name}'."
				newPackages = module.autosplits @
				newPackages = macro.parse newPackages, macroList @

				for package in *@\parsePackages splits: newPackages
					ui.debug "Registering automatic package: #{package.name}."

					if not @\hasPackage package.name
						package.automatic = true
						@packages[#@packages+1] = package
					else
						ui.debug " ... package already exists."
		else
			ui.warning "No module found for this distribution: " ..
				"'#{distribution}'."
			ui.warning "Your package is unlikely to comply to " ..
				"your OS’ packaging guidelines."

	--- @hidden
	-- FIXME: remove
	guessClass: (package) ->
		if package.name\match "-doc$"
			"documentation"
		elseif package.name\match "-dev$" or package.name\match "-devel$"
			"headers"
		elseif package.name\match "^lib"
			"library"
		else
			"binary"

	checkRecipe: =>
		module = @context.modules[@context.packageManager]
		if module and module.check
			r, e = module.check @

			if e and not r
				error e, 0

	---
	-- Checks that a Recipe defines a Package.
	--
	-- @param name (string) Name of the package.
	-- @return (boolean) Whether the Recipe contains a Package with the given name or not.
	--
	-- @info Will probably get patched to identify Packages based on an Atom and not just a name string.
	hasPackage: (name) =>
		for package in *@packages
			if package.name == name
				return true

		false

	--- @hidden
	-- Used during build.
	-- Hidden until semantics clarification and lots of grooming.
	postBuildHooks: =>
		for module in *@context.modules
			if module.postBuild
				fs.directory @\packagingDirectory!, ->
					module.postBuild @

	---
	-- @return (string) The directory in which the software will be built.
	buildingDirectory: =>
		"#{@context.buildingDirectory}/src/" ..
			"#{@name}-#{@version}-#{@release}"

	---
	-- @return (string) The “fake installation root” of the package, as used during build.
	packagingDirectory: (name) =>
		unless name
			name = "_"

		"#{@context.buildingDirectory}/pkg/#{name}"

	---
	-- Checks whether the recipe’s packages need updating or rebuilding.
	--
	-- @return (true)  Recipe needs rebuild.
	-- @return (false) Everything is up to date.
	buildNeeded: =>
		for self in *self.packages
			if self.automatic
				continue

			attributes = fs.attributes "" ..
				"#{@context.packagesDirectory}/#{@target}"
			unless attributes
				return true

			if attributes.modification < @recipeAttributes.modification
				ui.info "Recipe is newer than packages."
				return true

		false

	---
	-- Checks whether the recipe’s dependencies and build-dependencies are installed, and tries to install them if they are not.
	--
	-- @return nil
	checkDependencies: =>
		ui.info "Checking dependencies…"

		deps = {}
		for atom in *@buildDependencies
			table.insert deps, atom

		for atom in *deps
			unless @context\isAtomInstalled atom
				-- FIXME: Check the configuration to make sure it’s tolerated.
				--        If it isn’t, at least ask interactively.
				ui.detail "Installing missing dependency: #{atom.name}"
				@\installDependency atom.name

	---
	-- Installs a package by name.
	--
	-- @param name (string) Name of the package to install.
	-- @issue Will be moved to Context at some point.
	installDependency: (name) =>
		-- @fixme Should probably be in Context. =/
		module = @context.modules[@context.dependenciesManager]
		if not (module and module.installDependency)
			module = @context.modules[@context.packageManager]

		if not (module and module.installDependency)
			return nil, "no way to install packages"

		module.installDependency name

	---
	-- Downloads the recipe’s sources.
	--
	-- @return (boolean) Boolean indicating whether or not the downloads succeeded.
	download: =>
		ui.info "Downloading…"

		for source in *@sources
			if (source\download @context) ~= true
				return false

		true

	---
	-- Generates the recipe’s version from its sources.
	--
	-- Is useless for recipes with static versions, but is useful if a recipe is of a development version from a git repository or any similar situation.
	updateVersion: =>
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

	--- @hidden
	-- Hidden until clarified semantics and some grooming.
	prepareBuild: =>
		fs.mkdir @\buildingDirectory!
		fs.mkdir @\packagingDirectory!

		for package in *@packages
			fs.mkdir @\packagingDirectory package.name

	--- @hidden
	-- Hidden until clarified semantics and some grooming.
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

	---
	-- Builds the recipe.
	--
	-- This method does not build the packages themselves.
	-- The `package` method does that.
	--
	-- @see Package
	-- @see Recipe\package
	-- @see Recipe\finalize
	build: =>
		--- @warning \finalize! must have been called first.
		@\prepareBuild!

		@\extract!

		ui.info "Building…"

		for step, builder in ipairs @buildInstructions
			success, e = builder\execute!

			unless success
				if builder.critical
					return nil, e
				elseif e
					ui.warning e

		ui.info "Doing post-build verifications."
		@\postBuildHooks!

		true

	--- @hidden
	-- Hidden until clarified semantics and moderate amounts of grooming.
	split: =>
		for package in *@packages
			if package.files
				if package.automatic and not package\hasFiles!
					ui.debug "No file detected for #{package.name}. Ignoring."
					continue

				package\moveFiles!

		-- FIXME: A bit hacky. We need packaging directories and fake roots
		--        to be different.
		fs.remove @\packagingDirectory @packages[1].name
		fs.execute @, "mv '#{@\packagingDirectory!}' " ..
			"'#{@\packagingDirectory @packages[1].name}'"

	---
	-- Creates packages from the built software.
	-- @see Recipe\build
	-- @see Recipe\finalize
	package: =>
		--- @warning \finalize! must have been called first.
		ui.info "Packaging…"
		@\split!

		module = @context.modules[@context.packageManager]

		if module.package
			for package in *@packages
				if package.automatic and not package\hasFiles!
					ui.debug "Not building (empty) automatic package: #{package.name}"
					continue

				unless package\package module
					return nil

			return true
		else
			-- Should NOT happen.
			error "No module is available for the package manager "..
				"'#{@configuration['package-manager']}'."

	---
	-- Removes the recipe’s temporary building directories.
	--
	-- @return (boolean) Whether removing the files succeeded or not.
	clean: =>
		ui.info "Cleaning…"
		ui.detail "Removing '#{@\buildingDirectory!}'."

		-- Sort of necessary, considering the directories and files are
		-- root-owned. And they have to if we want our packages to be valid.
		os.execute "sudo rm -rf '#{@\buildingDirectory!}'"

	---
	-- Prints potential defects or missing data in the recipe.
	--
	-- It prints the defects themselves on stderr, and returns the number of defects found.
	--
	-- @return (number) Number of defects found in the recipe’s current configuration.
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

		for package in *@packages
			with self = package
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

	---
	-- Checks whether or not the recipe is up to date.
	--
	-- It may need access to recent sources to do so.
	--
	-- @see Recipe\download
	--
	-- @return (true, string) Version is up to date. Also returns the version.
	-- @return (false, string) Recipe is outdated. Returns the latest version available.
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
					"| hxselect -c '#{@watch.selector}' -s '\n'"
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

	---
	-- Generates a dependency tree for the recipe.
	--
	-- May need access to other recipes.
	depTree: =>
		isInstalled = do
			module = @context.modules[@context.packageManager]
			f = if module
				module.isInstalled
			else
				ui.warning "Unable to determine installed dependencies."

			f or -> false

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

	---
	-- Recipe can be safely converted to a debug string.
	__tostring: =>
		if @version
			"<pkgxx:Recipe: #{@name}-#{@version}-#{@release}>"
		else
			"<pkgxx:Recipe: #{@name}-[devel]-#{@release}>"

