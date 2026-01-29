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

  # Sync from System A events (idempotent upsert)
  def self.sync_from_event(event_payload)
    user = find_or_initialize_by(id: event_payload[:id])
    user.skip_publish = true # Prevent cyclic sync
    was_new_record = user.new_record?
    user.assign_attributes(extract_user_attributes(event_payload))

    if stale_event?(user, event_payload)
      Rails.logger.info "Skipping stale user update for ID #{event_payload[:id]}"
      return user
    end

    apply_event_timestamps(user, event_payload)
    user.save!
    reset_pk_sequence_if_supported if was_new_record
    Rails.logger.info "Synced user ID #{user.id}"
    user
  end

  def self.extract_user_attributes(payload)
    {
      organization_id: payload[:organization_id],
      name: payload[:name],
      email: payload[:email],
      role: payload[:role],
      active: payload[:active]
    }
  end

  def self.stale_event?(user, event_payload)
    return false if user.new_record? || user.updated_at.nil?

    event_payload[:updated_at] <= user.updated_at
  end

  def self.apply_event_timestamps(user, event_payload)
    user.created_at = event_payload[:created_at] if user.new_record?
    user.updated_at = event_payload[:updated_at]
  end

  def self.reset_pk_sequence_if_supported
    connection.reset_pk_sequence!(table_name) if connection.respond_to?(:reset_pk_sequence!)
  end
  private_class_method :extract_user_attributes, :stale_event?, :apply_event_timestamps, :reset_pk_sequence_if_supported

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
end
