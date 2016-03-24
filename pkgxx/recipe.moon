
toml = require "toml"

ui = require "pkgxx.ui"
fs = require "pkgxx.fs"
macro = require "pkgxx.macro"
sources = require "pkgxx.sources"

macroList = =>
	l = {
		pkg: @\packagingDirectory "_"
	}

	for name, path in pairs @context.prefixes
		l[name] = path

	l

class
	new: (filename, context) =>
		file = io.open filename, "r"

		unless file
			error "could not open recipe", 0

		recipe, e = toml.parse (file\read "*all"), {strict: false}

		file\close!

		@context = context

		recipe = macro.parse recipe, macroList @

		-- FIXME: sort by name or something.
		@splits = @\parseSplits recipe

		@origin = @

		@\applyDiff recipe

		@release = @release or 1
		@dirname = @dirname or "#{@name}-#{@version}"

		@conflicts    = @conflicts or {}
		@dependencies = @dependencies or {}
		@provides     = @provides or {}
		@groups       = @groups or {}
		@options      = @options or {}

		@architecture = @context.architecture
		@sources = {}
		@sources = @\parseSources recipe

		@buildInstructions =
			configure: recipe.configure,
			build: recipe.build,
			install: recipe.install

		@recipeAttributes = lfs.attributes filename

		@\applyDistributionRules recipe

		@\setTargets!

		@\checkRecipe!

	parse: (str) =>
		(macro.parse {str}, macroList @)[1]

	-- Is meant to be usable after package manager or architecture
	-- changes, avoiding the creation of a new context.
	setTargets: =>
		module = @context.modules[@context.packageManager]

		unless module and module.target
			ui.error "Could not set targets. Wrong package manager module?"
			return nil

		@target = module.target @
		for split in *@splits
			split.target = module.target split

	getTargets: =>
		i = 0

		return ->
			i = i + 1

			if i - 1 == 0
				return @target
			elseif i - 1 <= #@splits
				return @splits[i - 1].target

	parseSources: (recipe) =>
		local sources

		sources = switch type recipe.sources
			when "string"
				{ recipe.sources }
			when "nil"
				{}
			else
				recipe.sources

		for i = 1, #sources
			source = sources[i]
			url = source\gsub " -> .*", ""

			sources[i] = {
				filename: url\gsub ".*/", "",
				url: url
			}

		sources

	parseSplits: (recipe) =>
		splits = {}

		if recipe.splits
			for split, data in pairs recipe.splits
				if not data.name
					data.name = split

				-- Splits will need much more data than this.
				splits[#splits+1] = setmetatable {
					files: data.files
				}, __index: @

				@@.applyDiff splits[#splits], data

		splits

	applyDistributionRules: (recipe) =>
		distribution = @context.configuration.distribution
		module = @context.modules[distribution]

		if module
			if module.alterRecipe
				module.alterRecipe @
		else
			ui.warning "No module found for this distribution: " ..
				"'#{distribution}'."
			ui.warning "Your package is very unlike to comply to " ..
				"your OS’ packaging guidelines."

		-- Not very elegant.
		if recipe.os and recipe.os[distribution]
			@@.applyDiff @, recipe.os[distribution]

		for split in *@splits
			os = recipe.splits[split.name].os

			if os and os[distribution]
				@@.applyDiff split, os[distribution]

	checkRecipe: =>
		module = @context.modules[@context.packageManager]
		if module and module.check
			r, e = module.check @

			if e and not r
				error e, 0

	hasOption: (option) =>
		for opt in *@options
			if opt == option
				return true

	applyDiff: (diff) =>
		if diff.name
			@name = diff.name
		if diff.version
			@version = diff.version
		if diff.release
			@release = diff.release

		if diff.dependencies
			@dependencies = diff.dependencies
		if diff.conflicts
			@conflicts = diff.conflicts
		if diff.provides
			@provides = diff.provides
		if diff.groups
			@groups = diff.groups
		if diff.options
			@options = diff.options

		if diff.summary
			@summary = diff.summary
		if diff.description
			@description = diff.description

		if diff.license
			@license = diff.license
		if diff.copyright
			@copyright = diff.copyright

		if diff.class
			@class = diff.class

	stripFiles: =>
		fs.changeDirectory (@\packagingDirectory "_"), ->
			find = io.popen "find . -type f"

			line = find\read "*line"
			while line
				p = io.popen "file -b '#{line}'"
				type = p\read "*line"
				p\close!

				if type\match ".*ELF.*executable.*not stripped"
					ui.debug "Stripping '#{line}'."
					os.execute "strip --strip-all '#{line}'"
				elseif type\match ".*ELF.*shared object.*not stripped"
					ui.debug "Stripping '#{line}'."
					os.execute "strip --strip-unneeded '#{line}'"
				elseif type\match "current ar archive"
					ui.debug "Stripping '#{line}'."
					os.execute "strip --strip-debug '#{line}'"

				line = find\read "*line"

			find\close!

	compressManpages: =>
		fs.changeDirectory (@\packagingDirectory "_"), ->
			-- FIXME: hardcoded directory spotted.
			find = io.popen "find usr/share/man -type f"

			file = find\read "*line"
			while file
				unless file\match "%.gz$" or file\match "%.xz$" or
				       file\match "%.bz2$"
					switch @context.compressionMethod
						when "gz"
							os.execute "gzip -9 '#{file}'"
						when "bz2"
							os.execute "bzip2 -9 '#{file}'"
						when "xz"
							os.execute "xz -9 '#{file}'"

				file = find\read "*line"

			find\close!

	buildingDirectory: =>
		"#{@context.buildingDirectory}/src/" ..
			"#{@name}-#{@version}-#{@release}"

	packagingDirectory: (name) =>
		"#{@context.buildingDirectory}/pkg/#{name}"

	buildNeeded: =>
		for self in *{self, table.unpack self.splits}
			attributes = lfs.attributes "" ..
				"#{@context.packagesDirectory}/#{@target}"
			unless attributes
				return true

			if attributes.modification < @recipeAttributes.modification
				ui.info "Recipe is newer than packages."
				return true

	download: =>
		ui.info "Downloading…"

		for source in *@sources
			sources.download source, @context

	prepareBuild: =>
		fs.mkdir @\buildingDirectory!
		fs.mkdir @\packagingDirectory "_"

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
					os.execute "cp " ..
						"'#{@context.sourcesDirectory}/" ..
						"#{source.filename}' ./"

	-- @param name The name of the “recipe function” to execute.
	execute: (name, critical) =>
		ui.debug "Executing '#{name}'."

		if @buildInstructions[name]
			code = table.concat @buildInstructions[name], "\n"

			code = "set -x #{'-e' if critical else ''}\n#{code}"

			if @context.configuration.verbosity < 5
				logfile =  "#{@context.packagesDirectory}/" ..
					"#{name}-#{version}-#{release}.log"

				code = "(#{code}) 2>> #{logfile} >> #{logfile}"

			fs.changeDirectory @\buildingDirectory!, ->
				return os.execute code
		else
			@\executeModule name, critical

	executeModule: (name, critical) =>
		local r

		for modname, module in pairs @context.modules
			if module[name]
				-- FIXME: Not very readable. Please fix.
				r, e = fs.changeDirectory @\buildingDirectory!, ->
					module[name] @

				if r or e
					return r, e

		return nil, "no suitable module found"

	build: =>
		@\prepareBuild!

		@\extract!

		ui.info "Building…"

		success, e = (@\execute "configure")
		if not success
			ui.error "Build failure. Could not configure."
			return nil, e

		success, e = (@\execute "build", true)
		if not success
			ui.error "Build failure. Could not build."
			return nil, e

		success, e = (@\execute "install")
		if not success
			ui.error "Build failure. Could not install."
			return nil, e

		@\stripFiles!
		@\compressManpages!

		true

	split: =>
		for split in *@splits
			if split.files
				ui.detail "Splitting '#{split.name}'."

				for file in *split.files
					source = (@\packagingDirectory "_") .. file
					destination = (@\packagingDirectory split.name) ..
						file
					ui.debug "split: #{source} -> #{destination}"

					-- XXX: We need to be more cautious about
					--      permissions here.
					fs.mkdir destination\gsub "/[^/]*$", ""
					os.execute "mv '#{source}' '#{destination}'"

	package: =>
		ui.info "Packaging…"
		@\split!

		module = @context.modules[@context.packageManager]

		if module.package
			@\packageSplit module, @

			for split in *@splits
				@\packageSplit module, split
		else
			-- Should NOT happen.
			error "No module is available for the package manager "..
				"'#{@configuration['package-manager']}'."

	packageSplit: (module, split) =>
		local splitName
		if split == @
			splitName = "_"
		else
			splitName = split.name

		fs.changeDirectory (@\packagingDirectory splitName), ->
			module.package split

	clean: =>
		ui.info "Cleaning…"
		ui.detail "Removing '#{@\buildingDirectory!}'."
		fs.remove @\buildingDirectory!, {
			force: true
		}

	__tostring: =>
		"<pkgxx:Recipe: #{@name}-#{@version}-#{@release}>"

