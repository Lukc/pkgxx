
class
	new: (s) =>
		s = s\gsub "^%s*", ""
		s = s\gsub "%s*$", ""

		if s\match "@"
			@name, @origin = s\match "(%w*)@(%w*)"
		else
			@name = s
			@origin = s

	__tostring: =>
		"<Atom: #{@name}@#{@origin}>"

	__eq: (other) =>
		return @name == other.name and @origin == other.origin
