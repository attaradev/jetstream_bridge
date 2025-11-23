# frozen_string_literal: true

module JetstreamBridge
  module Models
    # Value object representing a NATS subject
    class Subject
      WILDCARD_SINGLE = '*'
      WILDCARD_MULTI = '>'
      SEPARATOR = '.'
      INVALID_CHARS = /[#{Regexp.escape(WILDCARD_SINGLE + WILDCARD_MULTI + SEPARATOR)}]/

      attr_reader :value, :tokens

      def initialize(value)
        @value = value.to_s
        @tokens = @value.split(SEPARATOR)
        validate!
        @value.freeze
        @tokens.freeze
        freeze
      end

      # Factory methods
      def self.source(env:, app_name:, dest:)
        new("#{env}.#{app_name}.sync.#{dest}")
      end

      def self.destination(env:, source:, app_name:)
        new("#{env}.#{source}.sync.#{app_name}")
      end

      def self.dlq(env:)
        new("#{env}.sync.dlq")
      end

      # Check if this subject matches a pattern
      def matches?(pattern)
        SubjectMatcher.match?(pattern.to_s, @value)
      end

      # Check if this subject overlaps with another
      def overlaps?(other)
        SubjectMatcher.overlap?(@value, other.to_s)
      end

      # Check if covered by any pattern in a list
      def covered_by?(patterns)
        SubjectMatcher.covered?(Array(patterns).map(&:to_s), @value)
      end

      def to_s
        @value
      end

      def ==(other)
        @value == (other.is_a?(Subject) ? other.value : other.to_s)
      end

      alias eql? ==

      def hash
        @value.hash
      end

      # Validate a component (env, app_name, etc.) for use in subjects
      def self.validate_component!(value, name)
        str = value.to_s
        if str.match?(INVALID_CHARS)
          wildcards = "#{SEPARATOR}, #{WILDCARD_SINGLE}, #{WILDCARD_MULTI}"
          raise ArgumentError,
                "#{name} cannot contain NATS wildcards (#{wildcards}): #{value.inspect}"
        end
        raise ArgumentError, "#{name} cannot be empty" if str.strip.empty?

        true
      end

      private

      def validate!
        raise ArgumentError, 'Subject cannot be empty' if @value.empty?
        raise ArgumentError, 'Subject cannot contain only separators' if @tokens.all?(&:empty?)
        raise ArgumentError, 'Subject has invalid format (contains spaces or special characters)' if @value.match?(/\s/)
      end

      # Lazy-load SubjectMatcher to avoid circular dependency
      def self.subject_matcher
        require_relative '../topology/subject_matcher' unless defined?(JetstreamBridge::SubjectMatcher)
        JetstreamBridge::SubjectMatcher
      end

      SubjectMatcher = subject_matcher
    end
  end
end
