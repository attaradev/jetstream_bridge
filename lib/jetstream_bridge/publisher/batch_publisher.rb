# frozen_string_literal: true

require 'oj'
require_relative '../core/logging'
require_relative '../models/publish_result'

module JetstreamBridge
  # Batch publisher for efficient bulk event publishing
  #
  # @example Publishing multiple events
  #   results = JetstreamBridge.publish_batch do |batch|
  #     users.each do |user|
  #       batch.add(event_type: "user.created", payload: { id: user.id })
  #     end
  #   end
  #
  #   puts "Published: #{results.successful_count}, Failed: #{results.failed_count}"
  class BatchPublisher
    # Result object for batch operations
    class BatchResult
      attr_reader :results, :successful_count, :failed_count, :errors

      def initialize(results)
        @results = results
        @successful_count = results.count(&:success?)
        @failed_count = results.count(&:failure?)
        @errors = results.select(&:failure?).map { |r| { event_id: r.event_id, error: r.error } }
        freeze
      end

      def success?
        @failed_count.zero?
      end

      def failure?
        !success?
      end

      def partial_success?
        @successful_count.positive? && @failed_count.positive?
      end

      def to_h
        {
          successful_count: @successful_count,
          failed_count: @failed_count,
          total_count: @results.size,
          errors: @errors
        }
      end

      alias to_hash to_h
    end

    def initialize(publisher = nil)
      @publisher = publisher || Publisher.new
      @events = []
    end

    # Add an event to the batch
    #
    # @param event_or_hash [Hash] Event data
    # @param resource_type [String, nil] Resource type
    # @param event_type [String, nil] Event type
    # @param payload [Hash, nil] Payload data
    # @param options [Hash] Additional options
    # @return [self] Returns self for chaining
    def add(event_or_hash = nil, resource_type: nil, event_type: nil, payload: nil, **options)
      @events << {
        event_or_hash: event_or_hash,
        resource_type: resource_type,
        event_type: event_type,
        payload: payload,
        options: options
      }
      self
    end

    # Publish all events in the batch
    #
    # @return [BatchResult] Result containing success/failure counts
    def publish
      results = @events.map do |event_data|
        @publisher.publish(
          event_data[:event_or_hash],
          resource_type: event_data[:resource_type],
          event_type: event_data[:event_type],
          payload: event_data[:payload],
          **event_data[:options]
        )
      rescue StandardError => e
        Models::PublishResult.new(
          success: false,
          event_id: 'unknown',
          subject: 'unknown',
          error: e
        )
      end

      BatchResult.new(results)
    ensure
      @events.clear
    end

    # Get number of events queued
    #
    # @return [Integer] Number of events in batch
    def size
      @events.size
    end

    alias count size
    alias length size

    def empty?
      @events.empty?
    end
  end
end
