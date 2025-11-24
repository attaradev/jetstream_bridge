# frozen_string_literal: true

require_relative '../..//core/logging'
require_relative '../../core/model_utils'
require_relative 'inbox_message'
require_relative 'inbox_repository'

module JetstreamBridge
  # Orchestrates AR-backed inbox processing.
  class InboxProcessor
    def initialize(message_processor)
      @processor = message_processor
    end

    # @return [true,false] processed?
    def process(msg)
      klass = ModelUtils.constantize(JetstreamBridge.config.inbox_model)
      return process_direct?(msg, klass) unless ModelUtils.ar_class?(klass)

      msg   = InboxMessage.from_nats(msg)
      repo  = InboxRepository.new(klass)
      record = repo.find_or_build(msg)

      if repo.already_processed?(record)
        msg.ack
        return true
      end

      repo.persist_pre(record, msg)
      action = @processor.handle_message(msg, auto_ack: false)

      case action&.action
      when :ack
        repo.persist_post(record)
        @processor.send(:apply_action, msg, action)
        true
      when :nak
        repo.persist_failure(record, action.error || StandardError.new('Inbox processing failed'))
        @processor.send(:apply_action, msg, action)
        false
      else
        repo.persist_failure(record, StandardError.new('Inbox processing returned no action'))
        false
      end
    rescue StandardError => e
      repo.persist_failure(record, e) if repo && record
      Logging.error("Inbox processing failed: #{e.class}: #{e.message}",
                    tag: 'JetstreamBridge::Consumer')
      # Ensure the message is retried if possible
      @processor.send(:safe_nak, msg, nil, e, delay: nil) if msg.respond_to?(:nak)
      false
    end

    private

    def process_direct?(msg, klass)
      unless ModelUtils.ar_class?(klass)
        Logging.warn("Inbox model #{klass} is not an ActiveRecord model; processing directly.",
                     tag: 'JetstreamBridge::Consumer')
      end
      @processor.handle_message(msg)
      true
    end
  end
end
