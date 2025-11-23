# frozen_string_literal: true

require 'oj'
require_relative '../core/logging'
require_relative '../models/publish_result'

module JetstreamBridge
  # Batch publisher for efficient bulk event publishing.
  #
  # BatchPublisher allows you to queue multiple events and publish them together,
  # providing detailed results about successes and failures. Each event is published
  # independently, so partial failures are possible.
  #
  # @example Publishing multiple events
  #   results = JetstreamBridge.publish_batch do |batch|
  #     users.each do |user|
  #       batch.add(event_type: "user.created", payload: { id: user.id })
  #     end
  #   end
  #
  #   puts "Published: #{results.successful_count}, Failed: #{results.failed_count}"
  #   results.errors.each { |e| logger.error("Failed: #{e[:event_id]}") }
  #
  # @example Checking for failures
  #   results = JetstreamBridge.publish_batch do |batch|
  #     batch.add(event_type: "order.created", payload: { id: 1 })
  #     batch.add(event_type: "order.updated", payload: { id: 2 })
  #   end
  #
  #   if results.failure?
  #     logger.warn "Some events failed to publish"
  #   end
  #
  class BatchPublisher
    # Result object for batch operations.
    #
    # Contains aggregated results from a batch publish operation, including
    # success/failure counts and detailed error information.
    #
    # @example Checking results
    #   results = JetstreamBridge.publish_batch { |b| ... }
    #   puts "Success: #{results.successful_count}"
    #   puts "Failed: #{results.failed_count}"
    #   puts "Partial: #{results.partial_success?}"
    #
    class BatchResult
      # @return [Array<Models::PublishResult>] All individual publish results
      attr_reader :results
      # @return [Integer] Number of successfully published events
      attr_reader :successful_count
      # @return [Integer] Number of failed events
      attr_reader :failed_count
      # @return [Array<Hash>] Array of error details with event_id and error
      attr_reader :errors

      # @param results [Array<Models::PublishResult>] Individual publish results
      # @api private
      def initialize(results)
        @results = results
        @successful_count = results.count(&:success?)
        @failed_count = results.count(&:failure?)
        @errors = results.select(&:failure?).map { |r| { event_id: r.event_id, error: r.error } }
        freeze
      end

      # Check if all events published successfully.
      #
      # @return [Boolean] True if no failures
      def success?
        @failed_count.zero?
      end

      # Check if any events failed to publish.
      #
      # @return [Boolean] True if any failures
      def failure?
        !success?
      end

      # Check if some (but not all) events published successfully.
      #
      # @return [Boolean] True if both successes and failures exist
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
