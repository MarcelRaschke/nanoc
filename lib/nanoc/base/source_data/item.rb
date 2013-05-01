# encoding: utf-8

module Nanoc

  # Represents a compileable item in a site. It has content and attributes, as
  # well as an identifier (which starts and ends with a slash). It can also
  # store the modification time to speed up compilation.
  class Item

    extend Nanoc::Memoization

    # @return [Hash] This item's attributes
    attr_accessor :attributes

    # @return [String] This item's identifier
    attr_accessor :identifier

    # @return [Array<Nanoc::ItemRep>] This item’s list of item reps
    attr_reader   :reps

    # @return [String] This item's raw, uncompiled content of this item (only
    #   available for textual items)
    attr_reader   :raw_content

    # @return [String] The filename pointing to the file containing this
    #   item’s content
    attr_accessor :raw_filename

    # @return [Nanoc::Site] The site this item belongs to
    attr_accessor :site

    # Creates a new item with the given content or filename, attributes and
    # identifier.
    #
    # @param [String] raw_content_or_raw_filename The uncompiled item content
    #   (if it is a textual item) or the path to the filename containing the
    #   content (if it is a binary item).
    #
    # @param [Hash] attributes A hash containing this item's attributes.
    #
    # @param [String] identifier This item's identifier.
    #
    # @param [Time, Hash] params Extra parameters. For backwards
    #   compatibility, this can be a Time instance indicating the time when
    #   this item was last modified (mtime).
    #
    # @option params [Symbol, nil] :binary (true) Whether or not this item is
    #   binary
    def initialize(raw_content_or_raw_filename, attributes, identifier, params=nil)
      if identifier.is_a?(String)
        identifier = Nanoc::Identifier.from_string(identifier)
      end

      # Parse params
      params ||= {}
      params[:binary] = false unless params.has_key?(:binary)

      if raw_content_or_raw_filename.nil?
        raise "attempted to create an item with no content/filename (identifier #{identifier})"
      end

      # Get type and raw content or raw filename
      @is_binary = params[:binary]
      if @is_binary
        @raw_filename = raw_content_or_raw_filename
      else
        @raw_filename = attributes[:content_filename]
        @raw_content  = raw_content_or_raw_filename
      end

      # Get rest of params
      # TODO validate identifier (must start with slash, cannot end with slash)
      @attributes   = attributes.symbolize_keys_recursively
      @identifier   = identifier.freeze

      @reps         = []
    end

    # Returns the rep with the given name.
    #
    # @param [Symbol] rep_name The name of the representation to return
    #
    # @return [Nanoc::ItemRep] The representation with the given name
    def rep_named(rep_name)
      @reps.find { |r| r.name == rep_name }
    end

    # Returns the compiled content from a given representation and a given
    # snapshot. This is a convenience method that makes fetching compiled
    # content easier.
    #
    # @option params [String] :rep (:default) The name of the representation
    #   from which the compiled content should be fetched. By default, the
    #   compiled content will be fetched from the default representation.
    #
    # @option params [String] :snapshot The name of the snapshot from which to
    #   fetch the compiled content. By default, the returned compiled content
    #   will be the content compiled right before the first layout call (if
    #   any).
    #
    # @return [String] The compiled content of the given rep (or the default
    #   rep if no rep is specified) at the given snapshot (or the default
    #   snapshot if no snapshot is specified)
    #
    # @see ItemRep#compiled_content
    def compiled_content(params={})
      # Get rep
      rep_name = params[:rep] || :default
      rep = reps.find { |r| r.name == rep_name }
      if rep.nil?
        raise Nanoc::Errors::Generic,
          "No rep named #{rep_name.inspect} was found."
      end

      # Get rep's content
      rep.compiled_content(params)
    end

    # Returns the path from a given representation. This is a convenience
    # method that makes fetching the path of a rep easier.
    #
    # @option params [String] :rep (:default) The name of the representation
    #   from which the path should be fetched. By default, the path will be
    #   fetched from the default representation.
    #
    # @return [String] The path of the given rep ( or the default rep if no
    #   rep is specified)
    def path(params={})
      rep_name = params[:rep] || :default

      # Get rep
      rep = reps.find { |r| r.name == rep_name }
      if rep.nil?
        raise Nanoc::Errors::Generic,
          "No rep named #{rep_name.inspect} was found."
      end

      # Get rep's path
      rep.path
    end

    # Requests the attribute with the given key.
    #
    # @param [Symbol] key The name of the attribute to fetch
    #
    # @return [Object] The value of the requested attribute
    def [](key)
      Nanoc::NotificationCenter.post(:visit_started, self)
      Nanoc::NotificationCenter.post(:visit_ended,   self)

      @attributes[key]
    end

    # Sets the attribute with the given key to the given value.
    #
    # @param [Symbol] key The name of the attribute to set
    #
    # @param [Object] value The value of the attribute to set
    def []=(key, value)
      @attributes[key] = value
    end

    # @return [Boolean] True if the item is binary; false if it is not
    def binary?
      !!@is_binary
    end

    # Returns the type of this object. Will always return `:item`, because
    # this is an item. For layouts, this method returns `:layout`.
    #
    # @api private
    #
    # @return [Symbol] :item
    def type
      :item
    end

    # Returns an object that can be used for uniquely identifying objects.
    #
    # @api private
    #
    # @return [Object] An unique reference to this object
    def reference
      [ type, self.identifier ]
    end

    # Prevents all further modifications to its attributes.
    #
    # @return [void]
    def freeze
      attributes.freeze_recursively
      identifier.freeze
      raw_filename.freeze if raw_filename
      raw_content.freeze  if raw_content
    end

    def inspect
      "<#{self.class} identifier=#{self.identifier.inspect} binary?=#{self.binary?}>"
    end

    # @return [String] The checksum for this object. If its contents change,
    #   the checksum will change as well.
    def checksum
      content_checksum = if binary?
        if File.exist?(raw_filename)
          Pathname.new(raw_filename).checksum
        else
          ''.checksum
        end
      else
        @raw_content.checksum
      end

      attributes = @attributes.dup
      attributes.delete(:file)
      attributes_checksum = attributes.checksum

      content_checksum + ',' + attributes_checksum
    end
    memoize :checksum

    def hash
      self.class.hash ^ self.identifier.hash
    end

    def eql?(other)
      self.class == other.class && self.identifier == other.identifier
    end

    def ==(other)
      self.eql?(other)
    end

    def marshal_dump
      [
        @is_binary,
        @raw_filename,
        @raw_content,
        @attributes,
        @identifier
      ]
    end

    def marshal_load(source)
      @is_binary,
      @raw_filename,
      @raw_content,
      @attributes,
      @identifier = *source
    end

    # @api private
    def forced_outdated=(bool)
      @forced_outdated = bool
    end

    # @api private
    def forced_outdated?
      @forced_outdated || false
    end

  end

end
