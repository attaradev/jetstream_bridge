# frozen_string_literal: true

# Event Consumer Service for System B
# Subscribes to events from System A and syncs data idempotently

class EventConsumer
  def self.start!
    Rails.logger.info 'Starting EventConsumer for System B...'

    # Subscribe to events from System A and start consuming
    consumer = JetstreamBridge.subscribe do |event|
      process_event(event)
    end

    # Start consuming (blocks until shutdown)
    consumer.run!
  end

  def self.process_event(event)
    Rails.logger.info "Processing event: #{event.type} (#{event.event_id})"

    case event.resource_type
    when 'organization'
      process_organization_event(event)
    when 'user'
      process_user_event(event)
    else
      Rails.logger.warn "Unknown resource type: #{event.resource_type}"
    end
  rescue StandardError => e
    Rails.logger.error "Failed to process event #{event.event_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise # Re-raise to trigger DLQ routing
  end

  def self.process_organization_event(event)
    case event.type
    when 'created', 'updated'
      Organization.sync_from_event(event.payload.to_h.symbolize_keys)
    else
      Rails.logger.warn "Unknown organization event type: #{event.type}"
    end
  end

  def self.process_user_event(event)
    case event.type
    when 'created', 'updated'
      User.sync_from_event(event.payload.to_h.symbolize_keys)
    else
      Rails.logger.warn "Unknown user event type: #{event.type}"
    end
  end
end
