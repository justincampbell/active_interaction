# frozen_string_literal: true

module ActiveInteraction
  class Base # rubocop:disable Lint/EmptyClass
    # @!method self.hash(*attributes, options = {}, &block)
    #   Creates accessors for the attributes and ensures that values passed to
    #     the attributes are Hashes.
    #
    #   @!macro filter_method_params
    #   @param block [Proc] filter methods to apply for select keys
    #   @option options [Boolean] :strip (true) remove unknown keys
    #
    #   @example
    #     hash :order
    #   @example
    #     hash :order do
    #       object :item
    #       integer :quantity, default: 1
    #     end
  end

  # @private
  class HashFilter < Filter
    include Missable

    # Limits how deeply a Hash input may be nested. `adjust_output` wraps
    # matching hashes with `HashWithIndifferentAccess`, which recursively
    # re-wraps nested hashes and arrays. Without a cap, a crafted deeply
    # nested hash can crash the process with `SystemStackError`.
    MAX_NESTING = 32

    register :hash

    def process(value, context) # rubocop:disable Metrics/AbcSize
      input = super

      return HashInput.new(self, value: input.value, error: input.errors.first) if input.errors.first
      return HashInput.new(self, value: default(context), error: input.errors.first) if input.value.nil?

      value = strip? ? HashWithIndifferentAccess.new : input.value
      error = nil
      children = {}

      filters.each do |name, filter|
        if filter.options[:default].is_a?(Proc) && !options[:default].is_a?(Proc)
          raise InvalidDefaultError, "#{self.name}: must use a lazy default if any nested filter uses a lazy default"
        end

        filter.process(input.value[name], context).tap do |result|
          value[name] = result.value
          children[name.to_sym] = result
        end
      end

      HashInput.new(self, value: value, error: error, children: children)
    end

    private

    def matches?(value)
      value.is_a?(Hash) && !exceeds_nesting_limit?(value)
    rescue NoMethodError # BasicObject
      false
    end

    # Iterative traversal to avoid adding its own stack-depth risk.
    def exceeds_nesting_limit?(value)
      stack = [[value, 1]]
      until stack.empty?
        item, depth = stack.pop
        return true if depth > MAX_NESTING

        case item
        when Hash
          item.each_value { |v| stack.push([v, depth + 1]) if v.is_a?(Hash) || v.is_a?(Array) }
        when Array
          item.each { |v| stack.push([v, depth + 1]) if v.is_a?(Hash) || v.is_a?(Array) }
        end
      end
      false
    end

    def strip?
      options.fetch(:strip, true)
    end

    def adjust_output(value, _context)
      ActiveSupport::HashWithIndifferentAccess.new(value)
    end

    def convert(value)
      if value.respond_to?(:to_hash)
        [value.to_hash, nil]
      else
        super
      end
    rescue NoMethodError # BasicObject
      super
    end

    # rubocop:disable Style/MissingRespondToMissing
    def method_missing(*args, &block)
      super(*args) do |klass, names, options|
        raise InvalidFilterError, 'missing attribute name' if names.empty?

        names.each do |name|
          filters[name] = klass.new(name, options, &block)
        end
      end
    end
    # rubocop:enable Style/MissingRespondToMissing

    def raw_default(*)
      value = super

      raise InvalidDefaultError, "#{name}: #{value.inspect}" if value.is_a?(Hash) && !value.empty?

      value
    end
  end
end
