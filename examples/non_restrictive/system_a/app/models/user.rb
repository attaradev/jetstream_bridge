# frozen_string_literal: true

class User < ApplicationRecord
  belongs_to :organization

  validates :email, presence: true, uniqueness: true
  validates :name, presence: true

  # Track whether this record is being synced from another system
  attr_accessor :skip_publish

  # Publish events after transaction commits (only for locally created/updated records)
  after_commit :publish_created_event, on: :create, unless: :skip_publish
  after_commit :publish_updated_event, on: :update, unless: :skip_publish

  # Sync from System B events (idempotent upsert)
  def self.sync_from_event(event_payload)
    user = find_or_initialize_by(id: event_payload[:id])
    user.skip_publish = true # Prevent cyclic sync
    was_new_record = user.new_record?

    user.assign_attributes(
      organization_id: event_payload[:organization_id],
      name: event_payload[:name],
      email: event_payload[:email],
      role: event_payload[:role],
      active: event_payload[:active]
    )

    # Only update timestamps if they're newer (to handle out-of-order delivery)
    if user.new_record? || user.updated_at.nil? ||
       event_payload[:updated_at] > user.updated_at
      user.created_at = event_payload[:created_at] if user.new_record?
      user.updated_at = event_payload[:updated_at]
    else
      # Skip update if this is an older event
      Rails.logger.info "Skipping stale user update for ID #{event_payload[:id]}"
      return user
    end

    user.save!
    reset_pk_sequence_if_supported if was_new_record
    Rails.logger.info "Synced user ID #{user.id}"
    user
  end

  private

  def publish_created_event
    publish_event('created')
  end

  def publish_updated_event
    publish_event('updated')
  end

  def publish_event(event_type)
    result = JetstreamBridge.publish(
      resource_type: 'user',
      event_type: event_type,
      resource_id: id.to_s,
      payload: {
        id: id,
        organization_id: organization_id,
        name: name,
        email: email,
        role: role,
        active: active,
        created_at: created_at,
        updated_at: updated_at
      }
    )

    if result.success?
      Rails.logger.info "Published user.#{event_type} event: #{result.event_id}"
    else
      Rails.logger.error "Failed to publish user.#{event_type}: #{result.error}"
    end
  end

  def self.reset_pk_sequence_if_supported
    connection.reset_pk_sequence!(table_name) if connection.respond_to?(:reset_pk_sequence!)
  end
end
